#requires -Version 5.1

param(
    [switch]$GuiMode
)

<#
.SYNOPSIS
    Creates a clean ZIP snapshot of a local project folder using a GUI only.
#>

# When launched as a normal .ps1, relaunch in a hidden STA PowerShell host so the
# GUI does not leave a console window open. PS2EXE embeds the script and does not
# expose a physical script path; its -NoConsole/-STA build already provides the
# correct host, so the EXE must continue directly into WPF instead of relaunching.
if (-not $GuiMode) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $runningFromDisk = -not [string]::IsNullOrWhiteSpace($scriptPath) -and
                       [System.IO.Path]::GetExtension($scriptPath) -ieq '.ps1' -and
                       (Test-Path -LiteralPath $scriptPath -PathType Leaf)

    if ($runningFromDisk) {
        $hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $argumentList = @(
            '-NoLogo'
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-STA'
            '-WindowStyle', 'Hidden'
            '-File', ('"{0}"' -f $scriptPath)
            '-GuiMode'
        )

        Start-Process -FilePath $hostExe -ArgumentList $argumentList -WindowStyle Hidden
        exit
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:SettingsDirectory = Join-Path $env:LOCALAPPDATA 'RepositorySnapshotTool'
$script:SettingsFile = Join-Path $script:SettingsDirectory 'projects.json'
$script:ProjectSettings = $null

function New-EmptyProjectSettings {
    return [PSCustomObject]@{
        LastProject = ''
        Projects = @()
    }
}

function Load-ProjectSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile -PathType Leaf)) {
        return New-EmptyProjectSettings
    }

    try {
        $settings = Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

        if ($null -eq $settings.Projects) {
            $settings | Add-Member -MemberType NoteProperty -Name Projects -Value @()
        }

        if ($null -eq $settings.LastProject) {
            $settings | Add-Member -MemberType NoteProperty -Name LastProject -Value ''
        }

        return $settings
    }
    catch {
        return New-EmptyProjectSettings
    }
}

function Save-ProjectSettings {
    param([Parameter(Mandatory)]$Settings)

    if (-not (Test-Path -LiteralPath $script:SettingsDirectory -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($script:SettingsDirectory) | Out-Null
    }

    $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
}

function Get-ProjectProfile {
    param([AllowEmptyString()][string]$ProjectName = '')

    $trimmedName = $ProjectName.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedName)) {
        return $null
    }

    return @($script:ProjectSettings.Projects) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) -and $_.Name -eq $trimmedName } |
        Select-Object -First 1
}

function Set-ProjectProfile {
    param(
        [AllowEmptyString()][string]$ProjectName = '',
        [AllowEmptyString()][string]$Source = '',
        [AllowEmptyString()][string]$OutputFile = ''
    )

    $trimmedName = $ProjectName.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedName)) {
        throw 'Enter a project name before saving defaults.'
    }

    $existing = Get-ProjectProfile -ProjectName $trimmedName
    if ($null -ne $existing) {
        $existing.Source = $Source.Trim()
        $existing.OutputFile = $OutputFile.Trim()
    }
    else {
        $script:ProjectSettings.Projects = @($script:ProjectSettings.Projects) + [PSCustomObject]@{
            Name = $trimmedName
            Source = $Source.Trim()
            OutputFile = $OutputFile.Trim()
        }
    }

    $script:ProjectSettings.LastProject = $trimmedName
    Save-ProjectSettings -Settings $script:ProjectSettings
}

$script:ProjectSettings = Load-ProjectSettings

function Show-Error {
    param([AllowEmptyString()][string]$Message = '')

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'An unexpected error occurred.'
    }

    [System.Windows.MessageBox]::Show(
        $Message,
        'Snapshot Tool 1.1',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}

function Write-Status {
    param(
        [Parameter(Mandatory)]$TextBox,
        [AllowEmptyString()][string]$Message = ''
    )

    $TextBox.AppendText($Message + "`r`n")
    $TextBox.ScrollToEnd()
    $TextBox.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Get-NormalizedArchivePath {
    param([AllowEmptyString()][string]$OutputFile = '')

    $trimmedOutputFile = $OutputFile.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmedOutputFile)) {
        throw 'Choose a name and location for the output ZIP file.'
    }

    if (-not $trimmedOutputFile.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimmedOutputFile += '.zip'
    }

    $fullPath = [System.IO.Path]::GetFullPath($trimmedOutputFile)
    $fileName = [System.IO.Path]::GetFileName($fullPath)

    if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -eq '.zip') {
        throw 'Enter a valid output ZIP filename.'
    }

    return $fullPath
}

function Get-ZipEngine {
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'),
        '7zz.exe', '7z.exe'
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $cmd = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
        if ($cmd) { return @{ Path = $cmd.Source; Name = '7-Zip' } }
    }
    $cmd = Get-Command tar.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Path = $cmd.Source; Name = 'Windows tar' } }
    throw 'Neither 7-Zip nor Windows tar.exe was found.'
}

function New-ProjectSnapshot {
    param(
        [AllowEmptyString()][string]$Source = '',
        [AllowEmptyString()][string]$OutputFile = '',
        [ValidateSet('Fast','Balanced','Maximum')][string]$Compression = 'Fast',
        [Parameter(Mandatory)]$LogTextBox
    )
    if ([string]::IsNullOrWhiteSpace($Source)) { throw 'Choose a source folder.' }
    $sourcePath = [System.IO.Path]::GetFullPath($Source.Trim()).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Source folder does not exist: $sourcePath" }
    $archive = Get-NormalizedArchivePath -OutputFile $OutputFile
    $outputDir = [System.IO.Path]::GetDirectoryName($archive)
    [System.IO.Directory]::CreateDirectory($outputDir) | Out-Null

    # Build in the destination directory, but exclude that temporary ZIP when the
    # destination lives inside the source. Never delete the existing snapshot on failure.
    $tempName = 'snapshot-' + [guid]::NewGuid().ToString('N') + '.zip'
    $tempArchive = Join-Path $outputDir $tempName
    $engine = Get-ZipEngine
    $LogTextBox.Clear()
    Write-Status -TextBox $LogTextBox -Message "Source: $sourcePath"
    Write-Status -TextBox $LogTextBox -Message "Archive: $archive"
    Write-Status -TextBox $LogTextBox -Message "Compression: $Compression ($($engine.Name))"
    Write-Status -TextBox $LogTextBox -Message 'Streaming repository directly to ZIP (no staging copy)...'

    try {
        # Existing snapshot is excluded if the output is inside the repository.
        $archiveName = [System.IO.Path]::GetFileName($archive)
        $tempRelative = $null
        $existingRelative = $null
        $prefix = $sourcePath.TrimEnd('\') + '\'
        if ($tempArchive.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $tempRelative = $tempArchive.Substring($prefix.Length).Replace('\','/')
        }
        if ($archive.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $existingRelative = $archive.Substring($prefix.Length).Replace('\','/')
        }

        switch ($engine.Name) {
            '7-Zip' {
                $level = switch ($Compression) { 'Fast' { '1' } 'Balanced' { '5' } 'Maximum' { '9' } }
                $args = @('a','-tzip',('-mx=' + $level),'-y','-bd','-bb0', $tempArchive, '.', '-xr!.git', '-xr!bin', '-xr!obj', '-xr!*.user', '-xr!*.suo')
                if ($tempRelative) { $args += ('-x!' + $tempRelative) }
                if ($existingRelative) { $args += ('-x!' + $existingRelative) }
            }
            default {
                # Windows bsdtar supports --exclude patterns, but has no stable
                # cross-version ZIP compression-level switch. The mode selection
                # is honored by 7-Zip; tar retains its native default.
                $args = @('-a','-c','-f',$tempArchive,
                    '--exclude=.git','--exclude=bin','--exclude=obj',
                    '--exclude=*.user','--exclude=*.suo')
                if ($tempRelative) { $args += ('--exclude=' + $tempRelative) }
                if ($existingRelative) { $args += ('--exclude=' + $existingRelative) }
                $args += @('-C',$sourcePath,'.')
                if ($Compression -ne 'Balanced') {
                    Write-Status -TextBox $LogTextBox -Message 'Note: Windows tar uses its default ZIP compression level.'
                }
            }
        }
        if ($engine.Name -eq '7-Zip') {
            Push-Location -LiteralPath $sourcePath
            try { & $engine.Path @args 2>&1 | ForEach-Object { if ($_ -ne '') { $LogTextBox.AppendText("$_`r`n") } } ; $exitCode = $LASTEXITCODE }
            finally { Pop-Location }
        }
        else {
            & $engine.Path @args 2>&1 | ForEach-Object { if ($_ -ne '') { $LogTextBox.AppendText("$_`r`n") } }
            $exitCode = $LASTEXITCODE
        }
        if ($exitCode -ne 0) { throw "$($engine.Name) exited with code $exitCode." }
        if (-not (Test-Path -LiteralPath $tempArchive -PathType Leaf)) { throw 'ZIP was not created.' }
        if ((Get-Item -LiteralPath $tempArchive).Length -eq 0) { throw 'ZIP is empty.' }
        # Validate the central directory before replacing an existing snapshot.
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempArchive)
        try { $entryCount = $zip.Entries.Count }
        finally { $zip.Dispose() }
        if ($entryCount -eq 0) { throw 'ZIP contains no entries.' }

        if (Test-Path -LiteralPath $archive) {
            # Same-directory rename is fast; retain old archive if the build failed.
            Remove-Item -LiteralPath $archive -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $tempArchive -Destination $archive -ErrorAction Stop
        $item = Get-Item -LiteralPath $archive
        Write-Status -TextBox $LogTextBox -Message "Completed: $entryCount ZIP entries; $([math]::Round($item.Length/1MB,2)) MB"
        return $item
    }
    finally {
        if (Test-Path -LiteralPath $tempArchive) {
            Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue
        }
    }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Project Snapshot Tool 1.3.0" Width="760" Height="620"
        MinWidth="680" MinHeight="520" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Project defaults" Margin="0,0,0,6"/>
    <Grid Grid.Row="1" Margin="0,0,0,16">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <ComboBox x:Name="ProjectComboBox" Grid.Column="0" IsEditable="True" MinHeight="28" Margin="0,0,10,0"/>
      <Button x:Name="SaveDefaultsButton" Grid.Column="1" Content="Save Defaults" Padding="14,6" Margin="0,0,8,0"/>
      <Button x:Name="DeleteDefaultsButton" Grid.Column="2" Content="Delete Defaults" Padding="14,6" Margin="0,0,8,0"/>
      <Button x:Name="NewDefaultsButton" Grid.Column="3" Content="New" Padding="14,6"/>
    </Grid>
    <TextBlock Grid.Row="2" Text="Source folder" Margin="0,0,0,6"/>
    <Grid Grid.Row="3" Margin="0,0,0,16"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBox x:Name="SourceTextBox" Grid.Column="0" MinHeight="28" VerticalContentAlignment="Center" Margin="0,0,10,0"/>
      <Button x:Name="SourceBrowseButton" Grid.Column="1" Content="Browse..." MinWidth="90" Padding="14,6"/>
    </Grid>
    <TextBlock Grid.Row="4" Text="Output ZIP file" Margin="0,0,0,6"/>
    <Grid Grid.Row="5" Margin="0,0,0,16"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBox x:Name="OutputTextBox" Grid.Column="0" MinHeight="28" VerticalContentAlignment="Center" Margin="0,0,10,0"/>
      <Button x:Name="OutputBrowseButton" Grid.Column="1" Content="Save As..." MinWidth="90" Padding="14,6"/>
    </Grid>
    <StackPanel Grid.Row="6" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBlock Text="Compression" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <ComboBox x:Name="CompressionComboBox" Width="150" SelectedIndex="0">
        <ComboBoxItem Content="Fast"/><ComboBoxItem Content="Balanced"/><ComboBoxItem Content="Maximum"/>
      </ComboBox>
      <TextBlock Text="  (7-Zip uses selected level; Windows tar uses default)" VerticalAlignment="Center" FontSize="11"/>
    </StackPanel>
    <TextBox x:Name="LogTextBox" Grid.Row="7" IsReadOnly="True" AcceptsReturn="True" AcceptsTab="True" TextWrapping="NoWrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" Margin="0,0,0,16"/>
    <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="CreateButton" Content="Create Snapshot" MinWidth="130" Padding="14,8" Margin="0,0,10,0" IsDefault="True"/>
      <Button x:Name="CloseButton" Content="Close" MinWidth="100" Padding="14,8" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$form = [Windows.Markup.XamlReader]::Load($reader)
$projectComboBox = $form.FindName('ProjectComboBox')
$saveDefaultsButton = $form.FindName('SaveDefaultsButton')
$deleteDefaultsButton = $form.FindName('DeleteDefaultsButton')
$newDefaultsButton = $form.FindName('NewDefaultsButton')
$sourceTextBox = $form.FindName('SourceTextBox')
$sourceBrowseButton = $form.FindName('SourceBrowseButton')
$outputTextBox = $form.FindName('OutputTextBox')
$outputBrowseButton = $form.FindName('OutputBrowseButton')
$logTextBox = $form.FindName('LogTextBox')
$compressionComboBox = $form.FindName('CompressionComboBox')
$createButton = $form.FindName('CreateButton')
$closeButton = $form.FindName('CloseButton')

function Refresh-ProjectList {
    param([string]$SelectedProject = '')

    $projectComboBox.Items.Clear()
    foreach ($project in @($script:ProjectSettings.Projects) | Sort-Object Name) {
        $savedName = [string]$project.Name
        if (-not [string]::IsNullOrWhiteSpace($savedName)) {
            [void]$projectComboBox.Items.Add($savedName)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectedProject)) {
        $projectComboBox.Text = $SelectedProject
    }
}

function Load-SelectedProject {
    $name = $projectComboBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return
    }

    $profile = Get-ProjectProfile -ProjectName $name
    if ($null -eq $profile) {
        return
    }

    $sourceTextBox.Text = [string]$profile.Source
    $outputTextBox.Text = [string]$profile.OutputFile
    $script:ProjectSettings.LastProject = $name
    Save-ProjectSettings -Settings $script:ProjectSettings
}

Refresh-ProjectList -SelectedProject $script:ProjectSettings.LastProject
if (-not [string]::IsNullOrWhiteSpace($script:ProjectSettings.LastProject)) {
    Load-SelectedProject
}

$projectComboBox.Add_SelectionChanged({
    Load-SelectedProject
})

$saveDefaultsButton.Add_Click({
    try {
        Set-ProjectProfile `
            -ProjectName $projectComboBox.Text `
            -Source $sourceTextBox.Text `
            -OutputFile $outputTextBox.Text

        Refresh-ProjectList -SelectedProject $projectComboBox.Text.Trim()
        Write-Status -TextBox $logTextBox -Message "Saved defaults for project '$($projectComboBox.Text.Trim())'."
    }
    catch {
        Show-Error -Message $_.Exception.Message
    }
})

$deleteDefaultsButton.Add_Click({
    $name = $projectComboBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        Show-Error -Message 'Select a saved project before deleting defaults.'
        return
    }

    $profile = Get-ProjectProfile -ProjectName $name

    if ($null -eq $profile) {
        Show-Error -Message 'Select a saved project before deleting defaults.'
        return
    }

    $answer = [System.Windows.MessageBox]::Show(
        "Delete the saved defaults for '$name'?",
        'Snapshot Tool 1.1',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:ProjectSettings.Projects = @($script:ProjectSettings.Projects) | Where-Object { $_.Name -ne $name }
        if ($script:ProjectSettings.LastProject -eq $name) {
            $script:ProjectSettings.LastProject = ''
        }
        Save-ProjectSettings -Settings $script:ProjectSettings
        $projectComboBox.Text = ''
        $sourceTextBox.Text = ''
        $outputTextBox.Text = ''
        Refresh-ProjectList
        Write-Status -TextBox $logTextBox -Message "Deleted defaults for project '$name'."
    }
})

$newDefaultsButton.Add_Click({
    $projectComboBox.SelectedIndex = -1
    $projectComboBox.Text = ''
    $sourceTextBox.Text = ''
    $outputTextBox.Text = ''
    $projectComboBox.Focus()
})

$sourceBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the project source folder.'
    $dialog.ShowNewFolderButton = $false

    if (Test-Path -LiteralPath $sourceTextBox.Text -PathType Container) {
        $dialog.SelectedPath = $sourceTextBox.Text
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sourceTextBox.Text = $dialog.SelectedPath
    }

    $dialog.Dispose()
})

$outputBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Name the snapshot ZIP'
    $dialog.Filter = 'ZIP archives (*.zip)|*.zip|All files (*.*)|*.*'
    $dialog.DefaultExt = 'zip'
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true

    try {
        $currentPath = Get-NormalizedArchivePath -OutputFile $outputTextBox.Text
        $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($currentPath)
        $dialog.FileName = [System.IO.Path]::GetFileName($currentPath)
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($sourceTextBox.Text) -and (Test-Path -LiteralPath $sourceTextBox.Text -PathType Container)) {
            $dialog.InitialDirectory = $sourceTextBox.Text
        }
        else {
            $dialog.InitialDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        }

        $projectName = $projectComboBox.Text.Trim()
        $dialog.FileName = if ([string]::IsNullOrWhiteSpace($projectName)) { 'Project-Snapshot.zip' } else { "$projectName-Snapshot.zip" }
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $outputTextBox.Text = $dialog.FileName
    }

    $dialog.Dispose()
})

$createButton.Add_Click({
    $createButton.IsEnabled = $false
    $closeButton.IsEnabled = $false
    $sourceBrowseButton.IsEnabled = $false
    $outputBrowseButton.IsEnabled = $false
    $saveDefaultsButton.IsEnabled = $false
    $deleteDefaultsButton.IsEnabled = $false
    $newDefaultsButton.IsEnabled = $false
    $projectComboBox.IsEnabled = $false
    $compressionComboBox.IsEnabled = $false
    $form.Cursor = [System.Windows.Input.Cursors]::Wait

    try {
        $archiveItem = New-ProjectSnapshot `
            -Source $sourceTextBox.Text `
            -OutputFile $outputTextBox.Text `
            -Compression ([string]$compressionComboBox.SelectedItem.Content) `
            -LogTextBox $logTextBox

        $result = [System.Windows.MessageBox]::Show(
            "Snapshot created successfully.`r`n`r`n$($archiveItem.FullName)`r`n`r`nOpen the containing folder?",
            'Snapshot Tool 1.1',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )

        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            Start-Process explorer.exe -ArgumentList "/select,`"$($archiveItem.FullName)`""
        }
    }
    catch {
        Write-Status -TextBox $logTextBox
        Write-Status -TextBox $logTextBox -Message "ERROR: $($_.Exception.Message)"
        Show-Error -Message $_.Exception.Message
    }
    finally {
        $form.Cursor = $null
        $createButton.IsEnabled = $true
        $closeButton.IsEnabled = $true
        $sourceBrowseButton.IsEnabled = $true
        $outputBrowseButton.IsEnabled = $true
        $saveDefaultsButton.IsEnabled = $true
        $deleteDefaultsButton.IsEnabled = $true
        $newDefaultsButton.IsEnabled = $true
        $projectComboBox.IsEnabled = $true
        $compressionComboBox.IsEnabled = $true
    }
})

$closeButton.Add_Click({
    $form.Close()
})

[void]$form.ShowDialog()
