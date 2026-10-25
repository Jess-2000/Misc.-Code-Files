#requires -Version 5.1
<#
.SYNOPSIS
    Multi-Folder Creator - a lightweight WPF utility for creating multiple folders.
.DESCRIPTION
    Select a destination directory, enter one relative folder path per line, preview
    the resulting plan, and create all valid directories in a single operation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

# -----------------------------
# User settings
# -----------------------------
$script:DefaultSettings = [ordered]@{
    AutomaticPreview       = $false
    OpenDestinationOnFinish = $false
    ClearNamesOnSuccess    = $false
    RememberLastDestination = $true
    LastDestination        = ''
}

$script:SettingsDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MultiFolderCreator'
$script:SettingsPath = Join-Path $script:SettingsDirectory 'settings.json'

function Get-AppSettings {
    $settings = [ordered]@{}
    foreach ($key in $script:DefaultSettings.Keys) { $settings[$key] = $script:DefaultSettings[$key] }

    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $saved = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            foreach ($key in $script:DefaultSettings.Keys) {
                if ($null -ne $saved.PSObject.Properties[$key]) { $settings[$key] = $saved.$key }
            }
        }
        catch { }
    }
    return [pscustomobject]$settings
}

function Save-AppSettings {
    param([Parameter(Mandatory)] [object] $Settings)
    if (-not (Test-Path -LiteralPath $script:SettingsDirectory)) {
        New-Item -ItemType Directory -Path $script:SettingsDirectory -Force | Out-Null
    }
    $Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

$script:Settings = Get-AppSettings
$script:PreviewConfirmed = $false

# -----------------------------
# Folder planning / validation
# -----------------------------
function Get-ReservedDeviceNames {
    $names = @('CON','PRN','AUX','NUL')
    $names += 1..9 | ForEach-Object { "COM$_" }
    $names += 1..9 | ForEach-Object { "LPT$_" }
    return $names
}

function Test-RelativeFolderPath {
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    $candidate = $RelativePath.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return [pscustomobject]@{ Valid = $false; Reason = 'Folder name is empty.' }
    }

    if ([System.IO.Path]::IsPathRooted($candidate)) {
        return [pscustomobject]@{ Valid = $false; Reason = 'Use a relative folder path, not an absolute path.' }
    }

    if ($candidate -match '(^|[\\/])\.\.([\\/]|$)') {
        return [pscustomobject]@{ Valid = $false; Reason = 'Parent-directory traversal (..) is not allowed.' }
    }

    $segments = $candidate -split '[\\/]'
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $reserved = Get-ReservedDeviceNames

    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            return [pscustomobject]@{ Valid = $false; Reason = 'Folder path contains an empty path segment.' }
        }

        if ($segment -eq '.') {
            return [pscustomobject]@{ Valid = $false; Reason = 'Current-directory segments (.) are not allowed.' }
        }

        if ($segment.IndexOfAny($invalidChars) -ge 0) {
            return [pscustomobject]@{ Valid = $false; Reason = "Folder name contains an invalid Windows character: $segment" }
        }

        if ($segment.EndsWith(' ') -or $segment.EndsWith('.')) {
            return [pscustomobject]@{ Valid = $false; Reason = "Folder names cannot end with a space or period: $segment" }
        }

        $deviceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($segment).ToUpperInvariant()
        if ($reserved -contains $deviceBaseName) {
            return [pscustomobject]@{ Valid = $false; Reason = "Reserved Windows device name: $segment" }
        }
    }

    return [pscustomobject]@{ Valid = $true; Reason = $null }
}

function Get-FolderPlan {
    param(
        [Parameter(Mandatory)]
        [string] $Destination,

        [Parameter(Mandatory)]
        [string] $InputText
    )

    $destinationTrimmed = $Destination.Trim()
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $lines = $InputText -split "`r?`n"
    foreach ($rawLine in $lines) {
        $relative = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }

        if (-not $seen.Add($relative)) {
            $items.Add([pscustomobject]@{
                RelativePath = $relative
                FullPath     = $null
                Status       = 'Duplicate'
                Detail       = 'Duplicate entry; it will be ignored.'
            })
            continue
        }

        $validation = Test-RelativeFolderPath -RelativePath $relative
        if (-not $validation.Valid) {
            $items.Add([pscustomobject]@{
                RelativePath = $relative
                FullPath     = $null
                Status       = 'Invalid'
                Detail       = $validation.Reason
            })
            continue
        }

        $fullPath = $null
        try {
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path -Path $destinationTrimmed -ChildPath $relative))
            $rootPath = [System.IO.Path]::GetFullPath($destinationTrimmed).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            $rootPrefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar

            if (-not ($fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                      $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
                throw 'Resolved path is outside the selected destination.'
            }
        }
        catch {
            $items.Add([pscustomobject]@{
                RelativePath = $relative
                FullPath     = $null
                Status       = 'Invalid'
                Detail       = $_.Exception.Message
            })
            continue
        }

        $status = if ([System.IO.Directory]::Exists($fullPath)) { 'Exists' } else { 'Ready' }
        $detail = if ($status -eq 'Exists') { 'Folder already exists and will be skipped.' } else { 'Ready to create.' }

        $items.Add([pscustomobject]@{
            RelativePath = $relative
            FullPath     = $fullPath
            Status       = $status
            Detail       = $detail
        })
    }

    return $items
}

function Get-PlanCounts {
    param([object[]] $Plan)

    $counts = [ordered]@{ Ready = 0; Exists = 0; Invalid = 0; Duplicate = 0 }
    foreach ($item in @($Plan)) {
        if ($counts.Contains($item.Status)) { $counts[$item.Status]++ }
    }
    return [pscustomobject]$counts
}

# -----------------------------
# WPF UI
# -----------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Multi-Folder Creator 1.1"
        Width="900" Height="680"
        MinWidth="680" MinHeight="520"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResize"
        Background="#F3F3F3"
        FontFamily="Segoe UI"
        FontSize="14">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="12"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="3*" MinHeight="120"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="16"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="2*" MinHeight="100"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="Destination folder" Margin="2,0,0,8"/>

        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition Width="118"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="DestinationTextBox"
                     Grid.Column="0"
                     Height="36"
                     VerticalContentAlignment="Center"
                     Padding="8,0"/>
            <Button x:Name="BrowseButton"
                    Grid.Column="2"
                    Height="36"
                    Content="Browse..."/>
        </Grid>

        <TextBlock Grid.Row="3" Text="Folder names" Margin="2,0,0,8"/>

        <TextBox x:Name="FolderNamesTextBox"
                 Grid.Row="4"
                 AcceptsReturn="True"
                 AcceptsTab="False"
                 VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap"
                 Padding="8"
                 FontFamily="Consolas"
                 SpellCheck.IsEnabled="False"/>

        <Grid Grid.Row="5" Margin="2,8,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="FolderCountTextBlock"
                       Grid.Column="0"
                       VerticalAlignment="Center"
                       Text="0 folders specified"/>
            <Button x:Name="ClearButton"
                    Grid.Column="1"
                    Width="92"
                    Height="32"
                    Content="Clear"/>
        </Grid>

        <TextBlock Grid.Row="7" Text="Preview and activity" Margin="2,0,0,8"/>

        <TextBox x:Name="ActivityTextBox"
                 Grid.Row="8"
                 IsReadOnly="True"
                 AcceptsReturn="True"
                 VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap"
                 Padding="8"
                 FontFamily="Consolas"
                 Text="Ready."/>

        <Grid Grid.Row="10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <Button x:Name="OptionsButton"
                    Grid.Column="0"
                    Width="104"
                    Height="38"
                    Content="Options..."/>

            <Button x:Name="PreviewButton"
                    Grid.Column="2"
                    Width="104"
                    Height="38"
                    Content="Preview"/>

            <Button x:Name="CreateButton"
                    Grid.Column="4"
                    Width="138"
                    Height="38"
                    Content="Create Folders"
                    FontWeight="SemiBold"/>
        </Grid>
    </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$DestinationTextBox = $window.FindName('DestinationTextBox')
$BrowseButton = $window.FindName('BrowseButton')
$FolderNamesTextBox = $window.FindName('FolderNamesTextBox')
$FolderCountTextBlock = $window.FindName('FolderCountTextBlock')
$ClearButton = $window.FindName('ClearButton')
$ActivityTextBox = $window.FindName('ActivityTextBox')
$PreviewButton = $window.FindName('PreviewButton')
$CreateButton = $window.FindName('CreateButton')
$OptionsButton = $window.FindName('OptionsButton')

function Set-ActivityText {
    param([string] $Text)
    $ActivityTextBox.Text = $Text
    $ActivityTextBox.ScrollToEnd()
}

function Update-FolderCount {
    $nonBlank = @($FolderNamesTextBox.Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $unique = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $nonBlank) { [void]$unique.Add($line.Trim()) }

    $noun = if ($unique.Count -eq 1) { 'folder' } else { 'folders' }
    $duplicateCount = $nonBlank.Count - $unique.Count
    $suffix = if ($duplicateCount -gt 0) { " ($duplicateCount duplicate$(if ($duplicateCount -ne 1) {'s'}) ignored)" } else { '' }
    $FolderCountTextBlock.Text = "$($unique.Count) $noun specified$suffix"
}

function Test-Inputs {
    $destination = $DestinationTextBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($destination)) {
        [System.Windows.MessageBox]::Show(
            $window,
            'Choose a destination folder first.',
            'Destination Required',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return $false
    }

    if (-not [System.IO.Directory]::Exists($destination)) {
        [System.Windows.MessageBox]::Show(
            $window,
            'The selected destination folder does not exist.',
            'Invalid Destination',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($FolderNamesTextBox.Text)) {
        [System.Windows.MessageBox]::Show(
            $window,
            'Enter at least one folder name.',
            'Folder Names Required',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return $false
    }

    return $true
}

function Show-Preview {
    if (-not (Test-Inputs)) { return }

    $plan = @(Get-FolderPlan -Destination $DestinationTextBox.Text -InputText $FolderNamesTextBox.Text)
    $counts = Get-PlanCounts -Plan $plan
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add("Destination: $($DestinationTextBox.Text.Trim())")
    $lines.Add('')
    $lines.Add("Ready: $($counts.Ready)    Existing: $($counts.Exists)    Invalid: $($counts.Invalid)    Duplicates: $($counts.Duplicate)")
    $lines.Add('')

    foreach ($item in $plan) {
        switch ($item.Status) {
            'Ready'     { $lines.Add("[READY]     $($item.FullPath)") }
            'Exists'    { $lines.Add("[EXISTS]    $($item.FullPath)") }
            'Duplicate' { $lines.Add("[DUPLICATE] $($item.RelativePath)") }
            'Invalid'   { $lines.Add("[INVALID]   $($item.RelativePath) -- $($item.Detail)") }
        }
    }

    Set-ActivityText -Text ($lines -join [Environment]::NewLine)
}

function Show-OptionsDialog {
    [xml]$optionsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Options"
        Width="510" Height="360"
        MinWidth="470" MinHeight="330"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize"
        Background="#F3F3F3"
        FontFamily="Segoe UI"
        FontSize="14">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
            <TextBlock Text="Preferences" FontSize="18" FontWeight="SemiBold"/>
            <TextBlock Margin="0,5,0,0" Text="Choose how Multi-Folder Creator behaves between operations." Foreground="#555555" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Grid.Row="2">
            <CheckBox x:Name="AutomaticPreviewCheckBox" Margin="0,0,0,16" Content="Automatically preview before creating folders"/>
            <CheckBox x:Name="OpenDestinationCheckBox" Margin="0,0,0,16" Content="Open destination folder after successful creation"/>
            <CheckBox x:Name="ClearNamesCheckBox" Margin="0,0,0,16" Content="Clear folder-name list after successful creation"/>
            <CheckBox x:Name="RememberDestinationCheckBox" Content="Remember last selected destination"/>
        </StackPanel>
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="DefaultsButton" Grid.Column="0" Width="126" Height="36" Content="Restore Defaults"/>
            <Button x:Name="CancelButton" Grid.Column="2" Width="88" Height="36" Content="Cancel" IsCancel="True"/>
            <Button x:Name="SaveButton" Grid.Column="4" Width="88" Height="36" Content="Save" IsDefault="True" FontWeight="SemiBold"/>
        </Grid>
    </Grid>
</Window>
'@

    $optionsReader = [System.Xml.XmlNodeReader]::new($optionsXaml)
    $optionsWindow = [Windows.Markup.XamlReader]::Load($optionsReader)
    $optionsWindow.Owner = $window

    $autoPreview = $optionsWindow.FindName('AutomaticPreviewCheckBox')
    $openDestination = $optionsWindow.FindName('OpenDestinationCheckBox')
    $clearNames = $optionsWindow.FindName('ClearNamesCheckBox')
    $rememberDestination = $optionsWindow.FindName('RememberDestinationCheckBox')
    $defaultsButton = $optionsWindow.FindName('DefaultsButton')
    $cancelButton = $optionsWindow.FindName('CancelButton')
    $saveButton = $optionsWindow.FindName('SaveButton')

    $autoPreview.IsChecked = [bool]$script:Settings.AutomaticPreview
    $openDestination.IsChecked = [bool]$script:Settings.OpenDestinationOnFinish
    $clearNames.IsChecked = [bool]$script:Settings.ClearNamesOnSuccess
    $rememberDestination.IsChecked = [bool]$script:Settings.RememberLastDestination

    $defaultsButton.Add_Click({
        $autoPreview.IsChecked = [bool]$script:DefaultSettings.AutomaticPreview
        $openDestination.IsChecked = [bool]$script:DefaultSettings.OpenDestinationOnFinish
        $clearNames.IsChecked = [bool]$script:DefaultSettings.ClearNamesOnSuccess
        $rememberDestination.IsChecked = [bool]$script:DefaultSettings.RememberLastDestination
    })

    $saveButton.Add_Click({
        $script:Settings.AutomaticPreview = [bool]$autoPreview.IsChecked
        $script:Settings.OpenDestinationOnFinish = [bool]$openDestination.IsChecked
        $script:Settings.ClearNamesOnSuccess = [bool]$clearNames.IsChecked
        $script:Settings.RememberLastDestination = [bool]$rememberDestination.IsChecked

        if ($script:Settings.RememberLastDestination) {
            $script:Settings.LastDestination = $DestinationTextBox.Text.Trim()
        }
        else {
            $script:Settings.LastDestination = ''
        }

        try { Save-AppSettings -Settings $script:Settings }
        catch {
            [System.Windows.MessageBox]::Show($optionsWindow, "The settings could not be saved.`r`n`r`n$($_.Exception.Message)", 'Settings Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        $script:PreviewConfirmed = $false
        $CreateButton.Content = 'Create Folders'
        $optionsWindow.DialogResult = $true
        $optionsWindow.Close()
    })

    $cancelButton.Add_Click({ $optionsWindow.Close() })
    [void]$optionsWindow.ShowDialog()
}

$OptionsButton.Add_Click({ Show-OptionsDialog })

$BrowseButton.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Select the directory in which the folders will be created.'
    $dialog.ShowNewFolderButton = $true

    if ([System.IO.Directory]::Exists($DestinationTextBox.Text.Trim())) {
        $dialog.SelectedPath = $DestinationTextBox.Text.Trim()
    }

    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $DestinationTextBox.Text = $dialog.SelectedPath
            $script:PreviewConfirmed = $false
            $CreateButton.Content = 'Create Folders'
            if ($script:Settings.RememberLastDestination) {
                $script:Settings.LastDestination = $dialog.SelectedPath
                try { Save-AppSettings -Settings $script:Settings } catch { }
            }
            Set-ActivityText -Text "Destination selected:`r`n$($dialog.SelectedPath)`r`n`r`nEnter folder names, then choose Preview or Create Folders."
        }
    }
    finally {
        $dialog.Dispose()
    }
})

$FolderNamesTextBox.Add_TextChanged({
    Update-FolderCount
    $script:PreviewConfirmed = $false
    $CreateButton.Content = 'Create Folders'
})

$DestinationTextBox.Add_TextChanged({
    $script:PreviewConfirmed = $false
    $CreateButton.Content = 'Create Folders'
})

$ClearButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($FolderNamesTextBox.Text)) { return }

    $result = [System.Windows.MessageBox]::Show(
        $window,
        'Clear all entered folder names?',
        'Clear Folder Names',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        $FolderNamesTextBox.Clear()
        Set-ActivityText -Text 'Ready.'
        $FolderNamesTextBox.Focus() | Out-Null
    }
})

$PreviewButton.Add_Click({ Show-Preview })

$CreateButton.Add_Click({
    if (-not (Test-Inputs)) { return }

    $plan = @(Get-FolderPlan -Destination $DestinationTextBox.Text -InputText $FolderNamesTextBox.Text)
    $counts = Get-PlanCounts -Plan $plan

    if ($counts.Invalid -gt 0) {
        Show-Preview
        [System.Windows.MessageBox]::Show(
            $window,
            'One or more entries are invalid. Review the Preview and activity pane before creating folders.',
            'Invalid Folder Names',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return
    }

    if ($counts.Ready -eq 0) {
        Show-Preview
        [System.Windows.MessageBox]::Show(
            $window,
            'There are no new folders to create. Existing folders and duplicate entries are skipped.',
            'Nothing to Create',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
    }

    if ([bool]$script:Settings.AutomaticPreview -and -not $script:PreviewConfirmed) {
        Show-Preview
        $script:PreviewConfirmed = $true
        $CreateButton.Content = 'Confirm Creation'
        $ActivityTextBox.AppendText("`r`n`r`nReview the plan above, then click Confirm Creation to continue.")
        $ActivityTextBox.ScrollToEnd()
        return
    }

    $script:PreviewConfirmed = $false
    $CreateButton.Content = 'Create Folders'
    $CreateButton.IsEnabled = $false
    $PreviewButton.IsEnabled = $false
    $BrowseButton.IsEnabled = $false
    $ClearButton.IsEnabled = $false
    $window.Cursor = [System.Windows.Input.Cursors]::Wait

    $created = 0
    $skipped = 0
    $failed = 0
    $log = [System.Collections.Generic.List[string]]::new()
    $log.Add("Creating folders in $($DestinationTextBox.Text.Trim())...")
    $log.Add('')

    try {
        foreach ($item in $plan) {
            switch ($item.Status) {
                'Ready' {
                    try {
                        [System.IO.Directory]::CreateDirectory($item.FullPath) | Out-Null
                        $created++
                        $log.Add("[CREATED] $($item.RelativePath)")
                    }
                    catch {
                        $failed++
                        $log.Add("[FAILED]  $($item.RelativePath) -- $($_.Exception.Message)")
                    }
                }
                'Exists' {
                    $skipped++
                    $log.Add("[SKIPPED] $($item.RelativePath) -- already exists")
                }
                'Duplicate' {
                    $skipped++
                    $log.Add("[SKIPPED] $($item.RelativePath) -- duplicate entry")
                }
            }
        }

        $log.Add('')
        $log.Add('Completed.')
        $log.Add("Created: $created    Skipped: $skipped    Failed: $failed")
        Set-ActivityText -Text ($log -join [Environment]::NewLine)

        if ($failed -eq 0 -and $created -gt 0) {
            if ([bool]$script:Settings.ClearNamesOnSuccess) {
                $FolderNamesTextBox.Clear()
            }
            if ([bool]$script:Settings.OpenDestinationOnFinish) {
                try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $DestinationTextBox.Text.Trim() + '"') }
                catch { $ActivityTextBox.AppendText("`r`n[WARNING] Could not open destination: $($_.Exception.Message)") }
            }
        }

        $icon = if ($failed -eq 0) { [System.Windows.MessageBoxImage]::Information } else { [System.Windows.MessageBoxImage]::Warning }
        [System.Windows.MessageBox]::Show(
            $window,
            "Folder creation complete.`r`n`r`nCreated: $created`r`nSkipped: $skipped`r`nFailed: $failed",
            'Multi-Folder Creator',
            [System.Windows.MessageBoxButton]::OK,
            $icon
        ) | Out-Null
    }
    finally {
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow
        $CreateButton.IsEnabled = $true
        $PreviewButton.IsEnabled = $true
        $BrowseButton.IsEnabled = $true
        $ClearButton.IsEnabled = $true
    }
})

$window.Add_ContentRendered({
    Update-FolderCount
    if ([bool]$script:Settings.RememberLastDestination -and -not [string]::IsNullOrWhiteSpace([string]$script:Settings.LastDestination) -and [System.IO.Directory]::Exists([string]$script:Settings.LastDestination)) {
        $DestinationTextBox.Text = [string]$script:Settings.LastDestination
        $FolderNamesTextBox.Focus() | Out-Null
    }
    else {
        $DestinationTextBox.Focus() | Out-Null
    }
})

[void]$window.ShowDialog()
