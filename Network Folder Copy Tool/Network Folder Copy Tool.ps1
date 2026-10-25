#requires -Version 5.1
<#
.SYNOPSIS
    Fast Network Folder Copy GUI

.DESCRIPTION
    Windows PowerShell GUI for copying a selected folder between local, same-server,
    and network locations. Uses ROBOCOPY for resilient, multithreaded transfers and
    is tuned for folders containing many large files.

    Features:
      - Browse for source root, target root, and folder to copy
      - UNC path support
      - Multithreaded Robocopy
      - Restartable transfers
      - Unbuffered I/O for large files
      - Live transfer log
      - Cancel button
      - Configurable parallel threads, retries, and Robocopy switches
      - Confirmation before destructive Robocopy operations
      - No target-side deletion with the default options

.NOTES
    Recommended: Windows PowerShell 5.1 or PowerShell 7+ on Windows.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
if (-not ('FolderCopy.NativeEncoding' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace FolderCopy {
    public static class NativeEncoding {
        [DllImport("kernel32.dll")] public static extern uint GetOEMCP();
        [DllImport("kernel32.dll")] public static extern uint GetConsoleOutputCP();
    }
}
'@
}

# -----------------------------
# Helper functions
# -----------------------------

function Show-Info {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [string] $Title = 'Fast Network Folder Copy'
    )

    [void][System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )
}

function Show-ErrorMessage {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [string] $Title = 'Fast Network Folder Copy'
    )

    [void][System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
}

function Select-Folder {
    param(
        [Parameter(Mandatory)]
        [string] $Description,
        [string] $InitialPath = ''
    )

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true

    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        try {
            if (Test-Path -LiteralPath $InitialPath) {
                $dialog.SelectedPath = $InitialPath
            }
        }
        catch {
            # Ignore an unavailable initial path.
        }
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }

    return $null
}

function Normalize-PathText {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $trimmed = $Path.Trim()

    # Preserve a drive root such as C:\ while removing redundant trailing
    # separators elsewhere.
    if ($trimmed -match '^[A-Za-z]:\\$') {
        return $trimmed
    }

    return $trimmed.TrimEnd('\')
}

function Get-CopyPaths {
    $source = Normalize-PathText $txtFolder.Text
    $target = Normalize-PathText $txtTargetRoot.Text
    if (-not $source -or -not $target) { throw 'Select a folder to copy and a target folder.' }
    if (-not [System.IO.Path]::IsPathRooted($source)) {
        $root = Normalize-PathText $txtSourceRoot.Text
        if (-not $root) { throw 'Enter a full source path, or specify the source root.' }
        $source = Join-Path $root $source
    }
    $source = [System.IO.Path]::GetFullPath($source).TrimEnd('\')
    $target = [System.IO.Path]::GetFullPath($target)
    if ($source -match '^[A-Za-z]:$') { throw 'Select a named folder, not an entire drive.' }
    $folderName = Split-Path -Leaf $source
    if (-not $folderName) { throw 'Select a named folder to copy.' }
    return [pscustomobject]@{ Source = $source; Destination = (Join-Path $target $folderName); Target = $target }
}

function Set-RunningState {
    param([bool] $Running)

    $btnStart.IsEnabled = -not $Running
    $btnCancel.IsEnabled = $Running

    $btnBrowseSourceRoot.IsEnabled = -not $Running
    $btnBrowseTargetRoot.IsEnabled = -not $Running
    $btnBrowseFolder.IsEnabled = -not $Running

    $txtSourceRoot.IsReadOnly = $Running
    $txtTargetRoot.IsReadOnly = $Running
    $txtFolder.IsReadOnly = $Running

    $btnOptions.IsEnabled = -not $Running
}

function Add-LogLine {
    param([string] $Line)

    if ($null -eq $form -or -not $form.IsLoaded) { return }

    # Queue UI text and render it in batches on the dispatcher timer.
    [void]$script:UiLogBuffer.AppendLine($Line)
}

function ConvertTo-QuotedArgument {
    param([Parameter(Mandatory)][string] $Value)

    # Robocopy accepts ordinary Windows quoting. Escape embedded quotes if one
    # ever appears, although they are invalid in normal Windows path names.
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Get-PathHostName {
    param([Parameter(Mandatory)][string] $Path)

    if ($Path -match '^\\\\([^\\]+)\\') {
        return $Matches[1].ToUpperInvariant()
    }

    return [Environment]::MachineName.ToUpperInvariant()
}

function Get-TransferProfile {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    $sourceHost = Get-PathHostName $Source
    $destinationHost = Get-PathHostName $Destination

    if ($sourceHost -eq $destinationHost) {
        return 'Same server/computer'
    }

    return 'Between servers/computers'
}

$script:RobocopyOptions = @{
    Threads = 32
    Retries = 3
    WaitSeconds = 3
    AutoProfile = $true
    Switches = @('/E', '/COPY:DAT', '/DCOPY:DAT', '/J', '/XJ', '/BYTES', '/ETA', '/FP', '/TEE')
    CustomSwitches = ''
    SaveLog = $false
    LogFolder = [Environment]::GetFolderPath('MyDocuments')
}

function New-LayoutColumn {
    $panel = New-Object System.Windows.Forms.TableLayoutPanel
    $panel.ColumnCount = 1
    $panel.AutoSize = $true
    $panel.AutoSizeMode = 'GrowAndShrink'
    $panel.Dock = 'Top'
    $panel.Margin = New-Object System.Windows.Forms.Padding(0)
    return $panel
}

function Add-LayoutRow {
    param($Panel, $Control, [bool] $Fill = $false)
    $row = $Panel.RowCount
    $Panel.RowCount++
    $style = New-Object System.Windows.Forms.RowStyle
    if ($Fill) { $style.SizeType = 'Percent'; $style.Height = 100 }
    else { $style.SizeType = 'AutoSize' }
    [void]$Panel.RowStyles.Add($style)
    $Control.Dock = 'Fill'
    $Control.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $Panel.Controls.Add($Control, 0, $row)
}

function New-LayoutRow {
    param([object[]] $Items, [int] $Stretch = -1)
    $row = New-Object System.Windows.Forms.TableLayoutPanel
    $row.AutoSize = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.ColumnCount = $Items.Count
    $row.RowCount = 1
    [void]$row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $style = New-Object System.Windows.Forms.ColumnStyle
        if ($i -eq $Stretch) { $style.SizeType = 'Percent'; $style.Width = 100 }
        else { $style.SizeType = 'AutoSize' }
        [void]$row.ColumnStyles.Add($style)
        $item = $Items[$i]
        $item.Dock = 'Fill'
        $item.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
        if ($item -is [System.Windows.Forms.Label] -or $item -is [System.Windows.Forms.Button]) {
            $item.AutoSize = $true
        }
        if ($i -eq $Stretch -and $item -is [System.Windows.Forms.Label]) {
            $item.AutoSize = $false
            $item.AutoEllipsis = $true
            $item.MinimumSize = New-Object System.Drawing.Size(0, 26)
        }
        if ($item -is [System.Windows.Forms.Button]) {
            $item.AutoSizeMode = 'GrowAndShrink'
            $item.Padding = New-Object System.Windows.Forms.Padding(12, 7, 12, 7)
        }
        $row.Controls.Add($item, $i, 0)
    }
    return $row
}

function Show-RobocopyOptions {
    [xml]$optionsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Robocopy Options" Width="820" Height="760" MinWidth="680" MinHeight="620" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13">
 <Grid Margin="18">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Grid.Row="0" Text="Select the Robocopy behavior for this copy job." Margin="0,0,0,14"/>
  <Grid Grid.Row="1" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="90"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="90"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
   <TextBlock Text="Parallel threads (/MT)" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBox x:Name="Threads" Grid.Column="1" Text="32" Margin="0,0,18,0"/>
   <TextBlock Grid.Column="2" Text="Retries (/R)" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBox x:Name="Retries" Grid.Column="3" Text="3" Margin="0,0,18,0"/>
   <TextBlock Grid.Column="4" Text="Wait seconds (/W)" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBox x:Name="Wait" Grid.Column="5" Text="3"/>
  </Grid>
  <CheckBox x:Name="AutoProfile" Grid.Row="2" Content="Automatically add /Z and /FFT for transfers between different servers/computers" Margin="0,0,0,12"/>
  <GroupBox Grid.Row="3" Header="Standard switches" Margin="0,0,0,12"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="SwitchPanel" Margin="10"/></ScrollViewer></GroupBox>
  <StackPanel Grid.Row="4" Margin="0,0,0,12"><TextBlock Text="Additional switches (space-separated, for example /MAXAGE:30 /XO)" Margin="0,0,0,5"/><TextBox x:Name="CustomSwitches"/></StackPanel>
  <CheckBox x:Name="SaveLog" Grid.Row="5" Content="Save log to file (Copy Log YYYYMMDD.log)" Margin="0,0,0,8"/>
  <Grid Grid.Row="6" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="LogFolder" Margin="0,0,10,0"/><Button x:Name="LogBrowse" Grid.Column="1" Content="Log folder..." Padding="12,5"/></Grid>
  <Grid Grid.Row="7"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
   <TextBlock Text="Warning: /MIR, /PURGE, /MOV and /MOVE can delete files." Foreground="DarkRed" VerticalAlignment="Center"/>
   <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="SaveOptions" Content="Save Options" MinWidth="115" Padding="12,7" Margin="0,0,8,0" IsDefault="True"/><Button x:Name="CancelOptions" Content="Cancel" MinWidth="95" Padding="12,7" IsCancel="True"/></StackPanel>
  </Grid>
 </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $optionsXaml
    $optionsForm = [Windows.Markup.XamlReader]::Load($reader)
    $optionsForm.Owner = $form
    $optionThreads = $optionsForm.FindName('Threads'); $optionThreads.Text = [string]$script:RobocopyOptions.Threads
    $optionRetries = $optionsForm.FindName('Retries'); $optionRetries.Text = [string]$script:RobocopyOptions.Retries
    $optionWait = $optionsForm.FindName('Wait'); $optionWait.Text = [string]$script:RobocopyOptions.WaitSeconds
    $autoProfile = $optionsForm.FindName('AutoProfile'); $autoProfile.IsChecked = $script:RobocopyOptions.AutoProfile
    $customSwitches = $optionsForm.FindName('CustomSwitches'); $customSwitches.Text = $script:RobocopyOptions.CustomSwitches
    $saveLog = $optionsForm.FindName('SaveLog'); $saveLog.IsChecked = $script:RobocopyOptions.SaveLog
    $logFolder = $optionsForm.FindName('LogFolder'); $logFolder.Text = $script:RobocopyOptions.LogFolder
    $logBrowse = $optionsForm.FindName('LogBrowse')
    $saveOptions = $optionsForm.FindName('SaveOptions'); $cancelOptions = $optionsForm.FindName('CancelOptions')
    $switchPanel = $optionsForm.FindName('SwitchPanel')
    $switchDescriptions = [ordered]@{
        '/E'='Copy all subfolders, including empty ones'; '/COPY:DAT'='Copy file data, attributes, and timestamps'; '/DCOPY:DAT'='Copy folder data, attributes, and timestamps'; '/J'='Use unbuffered I/O for large files'; '/Z'='Use restartable mode'; '/ZB'='Use restartable mode, then backup mode if access is denied'; '/XJ'='Exclude junction points'; '/FFT'='Use two-second timestamp tolerance'; '/SEC'='Copy NTFS permissions and ACLs'; '/SECFIX'='Apply security to skipped files too (use with /SEC)'; '/MIR'='Mirror the source and delete extra destination items'; '/PURGE'='Delete destination items that no longer exist in the source'; '/MOV'='Move files and delete them from the source after copying'; '/MOVE'='Move files and folders and delete them from the source'; '/BYTES'='Show file sizes as bytes'; '/ETA'='Show estimated completion time'; '/FP'='Show full file paths'; '/TEE'='Show output in the application log'
    }
    $switchBoxes = @{}
    foreach ($entry in $switchDescriptions.GetEnumerator()) {
        $box = New-Object System.Windows.Controls.CheckBox
        $box.Content = "$($entry.Key) — $($entry.Value)"; $box.Margin = '0,3,0,3'; $box.IsChecked = $script:RobocopyOptions.Switches -contains $entry.Key
        [void]$switchPanel.Children.Add($box); $switchBoxes[$entry.Key] = $box
    }
    function Update-LogControls { $enabled = [bool]$saveLog.IsChecked; $logFolder.IsEnabled = $enabled; $logBrowse.IsEnabled = $enabled }
    Update-LogControls
    $saveLog.Add_Checked({ Update-LogControls }); $saveLog.Add_Unchecked({ Update-LogControls })
    $logBrowse.Add_Click({ $chosen = Select-Folder -Description 'Choose where copy logs are saved.' -InitialPath $logFolder.Text; if ($chosen) { $logFolder.Text = $chosen } })
    $cancelOptions.Add_Click({ $optionsForm.DialogResult = $false; $optionsForm.Close() })
    $saveOptions.Add_Click({
        $threads=0; $retries=0; $wait=0
        if (-not [int]::TryParse($optionThreads.Text,[ref]$threads) -or $threads -lt 1 -or $threads -gt 128) { Show-ErrorMessage 'Parallel threads must be from 1 to 128.' 'Invalid Robocopy Options'; return }
        if (-not [int]::TryParse($optionRetries.Text,[ref]$retries) -or $retries -lt 0 -or $retries -gt 100) { Show-ErrorMessage 'Retries must be from 0 to 100.' 'Invalid Robocopy Options'; return }
        if (-not [int]::TryParse($optionWait.Text,[ref]$wait) -or $wait -lt 0 -or $wait -gt 60) { Show-ErrorMessage 'Wait seconds must be from 0 to 60.' 'Invalid Robocopy Options'; return }
        if ($saveLog.IsChecked -and -not (Test-Path -LiteralPath $logFolder.Text -PathType Container)) { Show-ErrorMessage 'Select an existing folder for saved logs.'; return }
        $custom=$customSwitches.Text.Trim(); if ($custom -match '["\r\n]' -or ($custom -and ($custom.Split(' ') | Where-Object { $_ -and -not $_.StartsWith('/') }))) { Show-ErrorMessage 'Additional entries must be space-separated Robocopy switches beginning with /. Quotes and line breaks are not allowed.' 'Invalid Robocopy Options'; return }
        $selected = New-Object System.Collections.Generic.List[string]; foreach($key in $switchBoxes.Keys){ if($switchBoxes[$key].IsChecked){$selected.Add($key)} }
        $script:RobocopyOptions.Threads=$threads; $script:RobocopyOptions.Retries=$retries; $script:RobocopyOptions.WaitSeconds=$wait; $script:RobocopyOptions.AutoProfile=[bool]$autoProfile.IsChecked; $script:RobocopyOptions.Switches=$selected.ToArray(); $script:RobocopyOptions.CustomSwitches=$custom; $script:RobocopyOptions.SaveLog=[bool]$saveLog.IsChecked; $script:RobocopyOptions.LogFolder=$logFolder.Text
        $optionsForm.DialogResult=$true; $optionsForm.Close()
    })
    [void]$optionsForm.ShowDialog()
}

function Get-RobocopyArgumentString {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][int] $Threads,
        [Parameter(Mandatory)][bool] $CopySecurity,
        [Parameter(Mandatory)][string] $TransferProfile
    )

    $args = New-Object System.Collections.Generic.List[string]

    $args.Add((ConvertTo-QuotedArgument $Source))
    $args.Add((ConvertTo-QuotedArgument $Destination))

    foreach ($robocopySwitch in $script:RobocopyOptions.Switches) {
        $args.Add($robocopySwitch)
    }

    $args.Add("/MT:$Threads")

    $args.Add("/R:$($script:RobocopyOptions.Retries)")
    $args.Add("/W:$($script:RobocopyOptions.WaitSeconds)")

    switch ($true) {
        ($script:RobocopyOptions.AutoProfile -and $TransferProfile -eq 'Between servers/computers') {
            if (-not ($script:RobocopyOptions.Switches -contains '/Z' -or $script:RobocopyOptions.Switches -contains '/ZB' -or $script:RobocopyOptions.Switches -contains '/B')) { $args.Add('/Z') }
            if (-not $script:RobocopyOptions.Switches.Contains('/FFT')) { $args.Add('/FFT') }
            break
        }
        default { break }
    }

    if ($CopySecurity -and -not $script:RobocopyOptions.Switches.Contains('/SEC')) {
        $args.Add('/SEC')
    }

    if (-not [string]::IsNullOrWhiteSpace($script:RobocopyOptions.CustomSwitches)) {
        foreach ($customSwitch in $script:RobocopyOptions.CustomSwitches.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $args.Add($customSwitch)
        }
    }

    return ($args -join ' ')
}

# -----------------------------
# GUI (WPF)
# -----------------------------
[xml]$mainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Fast Network Folder Copy 1.5" Width="1040" Height="820" MinWidth="760" MinHeight="620" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Grid Grid.Row="0" Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Source root path" Margin="0,0,0,5"/><TextBox x:Name="SourcePath" MinHeight="28" VerticalContentAlignment="Center"/></StackPanel><Button x:Name="SourceBrowse" Grid.Column="1" Content="Browse..." MinWidth="105" Margin="12,23,0,0" Padding="14,6"/></Grid>
  <Grid Grid.Row="1" Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Target folder path" Margin="0,0,0,5"/><TextBox x:Name="TargetPath" MinHeight="28" VerticalContentAlignment="Center"/></StackPanel><Button x:Name="TargetBrowse" Grid.Column="1" Content="Browse..." MinWidth="105" Margin="12,23,0,0" Padding="14,6"/></Grid>
  <Grid Grid.Row="2" Margin="0,0,0,16"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Folder to copy" Margin="0,0,0,5"/><TextBox x:Name="FolderPath" MinHeight="28" VerticalContentAlignment="Center"/></StackPanel><Button x:Name="FolderBrowse" Grid.Column="1" Content="Browse..." MinWidth="105" Margin="12,23,0,0" Padding="14,6"/></Grid>
  <GroupBox Grid.Row="3" Header="Copy progress and activity" Margin="0,0,0,16"><Grid Margin="12"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
   <Grid Grid.Row="0" Margin="0,0,0,7"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="StatusText" Text="Ready"/><TextBlock x:Name="ProgressText" Grid.Column="1" Text="Ready"/></Grid>
   <ProgressBar x:Name="ActivityBar" Grid.Row="1" Height="20" Minimum="0" Maximum="1000" Margin="0,0,0,9"/>
   <Grid Grid.Row="2" Margin="0,0,0,9"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Current item:" Margin="0,0,8,0"/><TextBlock x:Name="CurrentItem" Grid.Column="1" Text="Waiting to start" TextTrimming="CharacterEllipsis"/></Grid>
   <UniformGrid Grid.Row="3" Columns="4" Margin="0,0,0,9"><TextBlock x:Name="FileCount" Text="Files: 0 / 0" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="ByteCount" Text="Data: 0 B / 0 B" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="Speed" Text="Speed: pending" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="Elapsed" Text="Elapsed: 00:00:00" TextTrimming="CharacterEllipsis"/></UniformGrid>
   <TextBox x:Name="ActivityLog" Grid.Row="4" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas"/>
  </Grid></GroupBox>
  <Grid Grid.Row="4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Button x:Name="OptionsButton" Content="Options..." MinWidth="115" Padding="14,8" HorizontalAlignment="Left"/><StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="StartButton" Content="Start Copy" MinWidth="125" Padding="14,8" Margin="0,0,10,0" IsDefault="True"/><Button x:Name="CancelButton" Content="Cancel" MinWidth="105" Padding="14,8" IsEnabled="False"/></StackPanel></Grid>
 </Grid>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $mainXaml
$form = [Windows.Markup.XamlReader]::Load($reader)
$txtSourceRoot=$form.FindName('SourcePath'); $btnBrowseSourceRoot=$form.FindName('SourceBrowse'); $txtTargetRoot=$form.FindName('TargetPath'); $btnBrowseTargetRoot=$form.FindName('TargetBrowse'); $txtFolder=$form.FindName('FolderPath'); $btnBrowseFolder=$form.FindName('FolderBrowse')
$lblStatus=$form.FindName('StatusText'); $lblPercent=$form.FindName('ProgressText'); $progressBar=$form.FindName('ActivityBar'); $lblCurrentItem=$form.FindName('CurrentItem'); $lblFilesProgress=$form.FindName('FileCount'); $lblBytesProgress=$form.FindName('ByteCount'); $lblSpeed=$form.FindName('Speed'); $lblElapsed=$form.FindName('Elapsed'); $txtLog=$form.FindName('ActivityLog'); $btnOptions=$form.FindName('OptionsButton'); $btnStart=$form.FindName('StartButton'); $btnCancel=$form.FindName('CancelButton')
$form.Add_ContentRendered({ $txtLog.AppendText("WPF interface initialized. Ready to copy." + [Environment]::NewLine) })

# -----------------------------
# Process state
# -----------------------------

$script:CopyProcess = $null
$script:ScanProcess = $null
$script:OutputHandler = $null
$script:ErrorHandler = $null
$script:ExitHandler = $null
$script:TotalFiles = [int64]0
$script:TotalBytes = [int64]0
$script:CopiedFiles = [int64]0
$script:CopiedBytes = [int64]0
$script:CopyStartedAt = $null
$script:CurrentItem = ''
$script:ScanOutput = $null
$script:PendingCopySource = ''
$script:PendingCopyDestination = ''
$script:PendingCopyThreads = 32
$script:PendingCopySecurity = $false
$script:PendingTransferProfile = ''

$progressTimer = New-Object System.Windows.Threading.DispatcherTimer
$progressTimer.Interval = [TimeSpan]::FromMilliseconds(200)


function Format-ByteSize {
    param([int64] $Bytes)

    switch ($Bytes) {
        { $_ -ge 1099511627776 } { return ('{0:N2} TB' -f ($Bytes / 1099511627776)) }
        { $_ -ge 1073741824 } { return ('{0:N2} GB' -f ($Bytes / 1073741824)) }
        { $_ -ge 1048576 } { return ('{0:N2} MB' -f ($Bytes / 1048576)) }
        { $_ -ge 1024 } { return ('{0:N2} KB' -f ($Bytes / 1024)) }
        default        { return ('{0:N0} B' -f $Bytes) }
    }
}

function Reset-FolderProgress {
    $script:TotalFiles = 0
    $script:TotalBytes = 0
    $script:CopiedFiles = 0
    $script:CopiedBytes = 0
    $script:CopyStartedAt = $null
    $script:CurrentItem = ''

    $progressBar.Value = 0
    $lblPercent.Text = '0.0%'
    $lblCurrentItem.Text = 'Waiting to start'
    $lblFilesProgress.Text = 'Files: 0 / 0'
    $lblBytesProgress.Text = 'Data: 0 B / 0 B'
    $lblSpeed.Text = 'Speed: —'
    $lblElapsed.Text = 'Elapsed: 00:00:00'
}

function Update-FolderProgress {
    if ($null -eq $form -or -not $form.IsLoaded) { return }

    $totalFiles = $script:TotalFiles
    $totalBytes = $script:TotalBytes
    $copiedFiles = $script:CopiedFiles
    $copiedBytes = $script:CopiedBytes

    switch ($true) {
        ($totalBytes -gt 0) {
            $ratio = [Math]::Min(1.0, [Math]::Max(0.0, ($copiedBytes / [double]$totalBytes)))
            break
        }
        ($totalFiles -gt 0) {
            $ratio = [Math]::Min(1.0, [Math]::Max(0.0, ($copiedFiles / [double]$totalFiles)))
            break
        }
        default {
            $ratio = 0.0
        }
    }

    $progressBar.Value = [Math]::Min(
        $progressBar.Maximum,
        [Math]::Max($progressBar.Minimum, [int]($ratio * $progressBar.Maximum))
    )

    $lblPercent.Text = ('{0:N1}%' -f ($ratio * 100))
    $lblFilesProgress.Text = ('Files: {0:N0} / {1:N0}' -f $copiedFiles, $totalFiles)
    $lblBytesProgress.Text = ('Data: {0} / {1}' -f (Format-ByteSize $copiedBytes), (Format-ByteSize $totalBytes))

    if (-not [string]::IsNullOrWhiteSpace($script:CurrentItem)) {
        $lblCurrentItem.Text = $script:CurrentItem
    }

    if ($null -ne $script:CopyStartedAt) {
        $elapsed = (Get-Date) - $script:CopyStartedAt
        $lblElapsed.Text = ('Elapsed: {0:hh\:mm\:ss}' -f $elapsed)

        if ($elapsed.TotalSeconds -gt 0.25) {
            $bytesPerSecond = $copiedBytes / $elapsed.TotalSeconds
            $lblSpeed.Text = ('Speed: {0}/s' -f (Format-ByteSize ([int64]$bytesPerSecond)))
        }
    }
}

function Get-IntegerFromRobocopyField {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [int64]0
    }

    $digits = $Value -replace '[^\d]', ''
    if ([string]::IsNullOrWhiteSpace($digits)) {
        return [int64]0
    }

    return [int64]$digits
}


# ReadAsync performs managed I/O only. The UI timer processes completed reads;
# no PowerShell code runs on .NET worker threads and no temporary logs are needed.
$script:PipeStates = @()
$script:LogWriter = $null
$script:LogPath = ''
$script:LogWriteError = ''
$script:CancelRequested = $false
$script:SummaryTail = ''
$script:AccessDeniedLine = ''
$script:UiLogBuffer = New-Object System.Text.StringBuilder
$script:MaxUiLogCharacters = 150000
$script:RetainedUiLogCharacters = 100000

function Close-CopyReader {
    foreach ($pipe in $script:PipeStates) {
        try { $pipe.Reader.Dispose() } catch {}
    }
    $script:PipeStates = @()
    if ($script:LogWriter) {
        try { $script:LogWriter.Dispose() } catch { $script:LogWriteError = $_.Exception.Message }
        $script:LogWriter = $null
    }
}

function Open-OptionalLog {
    param([string] $Source, [string] $Destination)
    $script:LogPath = ''
    if (-not $script:RobocopyOptions.SaveLog) { return }
    $directory = (Resolve-Path -LiteralPath $script:RobocopyOptions.LogFolder).ProviderPath
    foreach ($path in @($Source, $Destination)) {
        $base = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($directory.TrimEnd('\').Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
            $directory.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Choose a log folder outside the source and destination folders.'
        }
    }
    $baseName = 'Copy Log ' + (Get-Date -Format 'yyyyMMdd')
    for ($number = 1; $number -le 10000; $number++) {
        $suffix = ''
        if ($number -gt 1) { $suffix = ' (' + $number + ')' }
        $candidate = Join-Path $directory ($baseName + $suffix + '.log')
        try {
            $stream = [System.IO.File]::Open($candidate, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        } catch [System.IO.IOException] {
            if ([System.IO.File]::Exists($candidate)) { continue }
            throw
        }
        $script:LogWriter = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
        $script:LogWriter.AutoFlush = $true
        $script:LogPath = $candidate
        return
    }
    throw 'Too many logs for this date in the selected folder.'
}

function Show-CopyChunk {
    param([string] $Chunk, $Pipe)
    if ($script:LogWriter) {
        try { $script:LogWriter.Write($Chunk) }
        catch {
            $script:LogWriteError = $_.Exception.Message
            try { $script:LogWriter.Dispose() } catch {}
            $script:LogWriter = $null
            Add-LogLine ('Log saving stopped; copying continues: ' + $script:LogWriteError)
        }
    }
    # Keep process draining/parsing separate from WPF rendering. The timer flushes
    # this buffer once per tick instead of repainting the TextBox for every chunk.
    [void]$script:UiLogBuffer.Append($Chunk)
    $script:SummaryTail += $Chunk
    if ($script:SummaryTail.Length -gt 16000) { $script:SummaryTail = $script:SummaryTail.Substring($script:SummaryTail.Length - 16000) }
    $Pipe.Pending += $Chunk
    $lines = $Pipe.Pending -split '[\r\n]+'
    $Pipe.Pending = $lines[-1]
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        $line = $lines[$i]
        if ($line -match '(?:[A-Za-z]:\\|\\\\).+') { $lblCurrentItem.Text = $Matches[0] }
        if ($line -match '(?i)ERROR\s+5\s+\(0x00000005\)|access is denied') {
            if (-not $script:AccessDeniedLine) {
                $script:AccessDeniedLine = $line + [Environment]::NewLine + $lblCurrentItem.Text
            }
        }
        if ($line -match '^\s*Speed\s*:\s*([\d,\.]+)\s*Bytes') {
            $lblSpeed.Text = 'Speed: ' + (Format-ByteSize (Get-IntegerFromRobocopyField $Matches[1])) + '/s'
        }
    }
    if ($Pipe.Pending.Length -gt 32768) { $Pipe.Pending = $Pipe.Pending.Substring($Pipe.Pending.Length - 32768) }
}


function Flush-UiLogBuffer {
    if ($null -eq $txtLog -or $script:UiLogBuffer.Length -eq 0) { return }
    $chunk = $script:UiLogBuffer.ToString()
    [void]$script:UiLogBuffer.Clear()
    $txtLog.AppendText($chunk)
    if ($txtLog.Text.Length -gt $script:MaxUiLogCharacters) {
        $txtLog.Text = $txtLog.Text.Substring($txtLog.Text.Length - $script:RetainedUiLogCharacters)
        $txtLog.CaretIndex = $txtLog.Text.Length
    }
    $txtLog.ScrollToEnd()
}

function Read-CopyLog {
    foreach ($pipe in $script:PipeStates) {
        for ($batch = 0; $batch -lt 8; $batch++) {
            if ($pipe.Done -or -not $pipe.Task.IsCompleted) { break }
            $count = $pipe.Task.GetAwaiter().GetResult()
            if ($count -eq 0) {
                if ($pipe.Pending) { Show-CopyChunk ([Environment]::NewLine) $pipe }
                $pipe.Done = $true
                break
            }
            $chunk = New-Object string($pipe.Buffer, 0, $count)
            Show-CopyChunk $chunk $pipe
            $pipe.Task = $pipe.Reader.ReadAsync($pipe.Buffer, 0, $pipe.Buffer.Length)
        }
    }
    return (@($script:PipeStates | Where-Object { -not $_.Done }).Count -eq 0)
}

function Start-CopyJob {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][int] $Threads,
        [Parameter(Mandatory)][bool] $CopySecurity,
        [Parameter(Mandatory)][string] $TransferProfile
    )
    # Start the actual copy immediately. No preliminary scan or asynchronous PS callbacks.
    Close-CopyReader
    $script:CancelRequested = $false
    $script:SummaryTail = ''
    $script:AccessDeniedLine = ''
    $script:LogWriteError = ''
    $arguments = Get-RobocopyArgumentString -Source $Source -Destination $Destination -Threads $Threads -CopySecurity $CopySecurity -TransferProfile $TransferProfile
    # Prevent custom switches from redirecting the managed log or changing job lifecycle.
    if ($arguments -match '(?i)(?:^|\s)/(?:LOG\+?|UNILOG\+?|JOB|SAVE|QUIT|MON|MOT|RH|NOSD|NODD|REG)(?=[:\s]|$)') {
        throw 'Log redirection, job files, scheduling and monitoring switches are not supported by this GUI.'
    }
    # Robocopy /UNICODE emitted mixed-width output in the supplied failing log.
    # Use ordinary console output and its Windows code page, then save UTF-8.
    if ($arguments -match '(?i)(?:^|\s)/UNICODE(?=\s|$)') {
        throw 'Remove /UNICODE from additional switches. The application manages output encoding.'
    }
    Open-OptionalLog -Source $Source -Destination $Destination
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $codePage = [FolderCopy.NativeEncoding]::GetConsoleOutputCP()
    if ($codePage -eq 0) { $codePage = [FolderCopy.NativeEncoding]::GetOEMCP() }
    $outputEncoding = [System.Text.Encoding]::GetEncoding([int]$codePage)
    $startInfo.StandardOutputEncoding = $outputEncoding
    $startInfo.StandardErrorEncoding = $outputEncoding
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Robocopy could not be started.' }
        $script:PipeStates = @()
        foreach ($reader in @($process.StandardOutput, $process.StandardError)) {
            $buffer = New-Object char[] 4096
            $script:PipeStates += [pscustomobject]@{
                Reader = $reader; Buffer = $buffer
                Task = $reader.ReadAsync($buffer, 0, $buffer.Length)
                Done = $false; Pending = ''
            }
        }
    } catch {
        try { if (-not $process.HasExited) { $process.Kill() } } catch {}
        Close-CopyReader
        $process.Dispose()
        throw
    }
    $script:CopyProcess = $process
    $script:CopyStartedAt = Get-Date
    $lblStatus.Text = 'Copying...'
    $lblCurrentItem.Text = $Source
    $lblPercent.Text = 'Working'
    $lblFilesProgress.Text = 'Files: see log'
    $lblBytesProgress.Text = 'Data: see log'
    $lblSpeed.Text = 'Speed: pending'
    $progressBar.IsIndeterminate = $true
    if ($script:LogPath) { Add-LogLine ('Saving log: ' + $script:LogPath) }
    else { Add-LogLine 'File logging is off. Activity is shown only in this window.' }
    Add-LogLine ('Running as: ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $progressTimer.Start()
}

$progressTimer.Add_Tick({
    try {
        if (-not $script:CopyProcess) { return }
        $drained = Read-CopyLog
        Flush-UiLogBuffer
        $elapsed = (Get-Date) - $script:CopyStartedAt
        $lblElapsed.Text = 'Elapsed: ' + $elapsed.ToString('hh\:mm\:ss')
        if (-not $script:CopyProcess.HasExited -or -not $drained) { return }
        $code = $script:CopyProcess.ExitCode
        $progressTimer.Stop()
        Close-CopyReader
        $script:CopyProcess.Dispose()
        $script:CopyProcess = $null
        $progressBar.IsIndeterminate = $false
        Set-RunningState $false
        foreach ($kind in @('Files','Bytes')) {
            $match = [regex]::Match($script:SummaryTail, '(?im)^\s*' + $kind + '\s*:\s*([\d,\.]+)\s+([\d,\.]+)')
            if ($match.Success) {
                $total = Get-IntegerFromRobocopyField $match.Groups[1].Value
                $copied = Get-IntegerFromRobocopyField $match.Groups[2].Value
                switch ($kind) {
                    'Files' { $lblFilesProgress.Text = "Copied: $copied / $total files" }
                    'Bytes' { $lblBytesProgress.Text = 'Copied: ' + (Format-ByteSize $copied) }
                }
            }
        }
        switch ($true) {
            ($script:CancelRequested) { $lblStatus.Text = 'Cancelled'; $lblPercent.Text = 'Stopped'; break }
            ($code -ge 0 -and $code -lt 8) {
                $lblStatus.Text = "Finished (code $code) - see log"
                $lblPercent.Text = 'Finished'
                $progressBar.Value = $progressBar.Maximum
                break
            }
            default { $lblStatus.Text = "Copy failed (code $code)"; $lblPercent.Text = 'Failed' }
        }
        Add-LogLine ($lblStatus.Text + '. This window remains open.')
        Flush-UiLogBuffer
        if ($script:LogWriteError) { Add-LogLine ('Warning: saved log may be incomplete: ' + $script:LogWriteError) }
        if ($code -ge 8 -and $script:AccessDeniedLine -and -not $script:CancelRequested) {
            $details = "Windows denied access to one or more files. Creating folders does not confirm that their files were copied." +
                [Environment]::NewLine + [Environment]::NewLine + $script:AccessDeniedLine +
                [Environment]::NewLine + [Environment]::NewLine +
                'Check whether the same file can be copied to this target in File Explorer. If /SEC or /COPYALL was selected, try a normal data copy without those permission-copy options. Also check file encryption and Windows Security protection history. No permissions were changed automatically.'
            Add-LogLine $details
            Show-ErrorMessage $details 'Copy incomplete - access denied'
        }
    } catch {
        $message = $_.Exception.Message
        $progressTimer.Stop()
        Close-CopyReader
        # Stop only our owned child process; never close the UI on a job error.
        if ($script:CopyProcess) {
            try { if (-not $script:CopyProcess.HasExited) { $script:CopyProcess.Kill() } } catch {}
            $script:CopyProcess.Dispose()
            $script:CopyProcess = $null
        }
        $progressBar.IsIndeterminate = $false
        $lblStatus.Text = 'Error - see log'
        Set-RunningState $false
        Add-LogLine ('Error: ' + $message)
        Show-ErrorMessage $message
    }
})

# -----------------------------
# UI events
# -----------------------------


$btnBrowseSourceRoot.Add_Click({
    $selected = Select-Folder `
        -Description 'Select the source server/root path.' `
        -InitialPath $txtSourceRoot.Text

    if ($selected) {
        $txtSourceRoot.Text = $selected
    }
})

$btnBrowseTargetRoot.Add_Click({
    $selected = Select-Folder `
        -Description 'Select the target server/root path.' `
        -InitialPath $txtTargetRoot.Text

    if ($selected) {
        $txtTargetRoot.Text = $selected
    }
})

$btnBrowseFolder.Add_Click({
    $initial = $txtSourceRoot.Text

    $selected = Select-Folder `
        -Description 'Select the specific folder to copy.' `
        -InitialPath $initial

    if ($selected) {
        $txtFolder.Text = $selected

        $normalizedSourceRoot = Normalize-PathText $txtSourceRoot.Text
        $normalizedSelected = Normalize-PathText $selected

        if (
            [string]::IsNullOrWhiteSpace($normalizedSourceRoot) -or
            -not $normalizedSelected.StartsWith(
                $normalizedSourceRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $txtSourceRoot.Text = Split-Path -Parent $normalizedSelected
        }
    }
})


$btnOptions.Add_Click({
    Show-RobocopyOptions
})

$btnCancel.Add_Click({
    $activeProcess = $null

    switch ($true) {
        ($script:CopyProcess -and -not $script:CopyProcess.HasExited) {
            $activeProcess = $script:CopyProcess
            break
        }
        ($script:ScanProcess -and -not $script:ScanProcess.HasExited) {
            $activeProcess = $script:ScanProcess
            break
        }
    }

    if ($activeProcess) {
        try {
            $script:CancelRequested = $true
            $lblStatus.Text = 'Cancelling...'
            $lblCurrentItem.Text = 'Cancellation requested'
            Add-LogLine ''
            Add-LogLine 'Cancellation requested by user.'

            try {
                & taskkill.exe /PID $activeProcess.Id /T /F | Out-Null
            }
            catch {
                $activeProcess.Kill()
            }
        }
        catch {
            Add-LogLine "Unable to cancel cleanly: $($_.Exception.Message)"
        }
    }
})

$btnStart.Add_Click({
    try {
        $paths = Get-CopyPaths
        $source = $paths.Source
        $destination = $paths.Destination

        if ([string]::IsNullOrWhiteSpace($source)) {
            Show-ErrorMessage 'Select a folder to copy.'
            return
        }

        if ([string]::IsNullOrWhiteSpace($destination)) {
            Show-ErrorMessage 'Select a target folder.'
            return
        }

        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            Show-ErrorMessage "The source folder does not exist or cannot be accessed:`r`n`r`n$source"
            return
        }

        $targetRoot = $paths.Target
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
            Show-ErrorMessage "The target root does not exist or cannot be accessed:`r`n`r`n$targetRoot"
            return
        }

        if (
            $destination.StartsWith(
                $source + '\',
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            $destination.Equals(
                $source,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Show-ErrorMessage 'The target cannot be the same as, or inside, the source folder.'
            return
        }

        $allConfiguredSwitches = @($script:RobocopyOptions.Switches) + @(
            $script:RobocopyOptions.CustomSwitches.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
        )
        $destructiveSwitches = @($allConfiguredSwitches | Where-Object {
            ($_ -split ':', 2)[0] -in @('/PURGE', '/MOV', '/MOVE', '/MIR')
        })
        if ($destructiveSwitches.Count -gt 0) {
            $choice = [System.Windows.MessageBox]::Show(
                "The selected options can delete source or destination files:`r`n`r`n$($destructiveSwitches -join ', ')`r`n`r`nContinue?",
                'Confirm Destructive Robocopy Options',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }

        $threads = [int]$script:RobocopyOptions.Threads
        $copySecurity = $script:RobocopyOptions.Switches -contains '/SEC'
        $transferProfile = Get-TransferProfile -Source $source -Destination $destination

        $txtLog.Clear()
        [void]$script:UiLogBuffer.Clear()
        Reset-FolderProgress

        Add-LogLine 'Fast Network Folder Copy'
        Add-LogLine ('Started: {0}' -f (Get-Date))
        Add-LogLine "Source:      $source"
        Add-LogLine "Destination: $destination"
        Add-LogLine "Threads:     $threads"
        Add-LogLine "Profile:     $transferProfile"
        Add-LogLine "Switches:    $($script:RobocopyOptions.Switches -join ' ') $($script:RobocopyOptions.CustomSwitches)"
        Add-LogLine ''

        Set-RunningState $true

        Start-CopyJob `
            -Source $source `
            -Destination $destination `
            -Threads $threads `
            -CopySecurity $copySecurity `
            -TransferProfile $transferProfile
    }
    catch {
        Set-RunningState $false
        $lblStatus.Text = 'Error'
        Add-LogLine ('Unable to start copy: ' + $_.Exception.Message)
        Show-ErrorMessage $_.Exception.Message
    }
})

$form.Add_Closing({
    param($Sender, $EventArgs)

    $activeProcess = $null

    switch ($true) {
        ($script:CopyProcess -and -not $script:CopyProcess.HasExited) {
            $activeProcess = $script:CopyProcess
            break
        }
        ($script:ScanProcess -and -not $script:ScanProcess.HasExited) {
            $activeProcess = $script:ScanProcess
            break
        }
    }

    if ($activeProcess) {
        $choice = [System.Windows.MessageBox]::Show(
            'A scan or copy operation is still running. Cancel it and close?',
            'Fast Network Folder Copy',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )

        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
            $EventArgs.Cancel = $true
            return
        }

        try {
            & taskkill.exe /PID $activeProcess.Id /T /F | Out-Null
        }
        catch {
            try {
                $activeProcess.Kill()
            }
            catch {
                # Closing anyway.
            }
        }
    }
})

Reset-FolderProgress
$form.Add_Closed({
    $progressTimer.Stop()
    Close-CopyReader
})
[void]$form.ShowDialog()

