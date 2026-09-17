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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
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
[System.Windows.Forms.Application]::EnableVisualStyles()

# -----------------------------
# Helper functions
# -----------------------------

function Show-Info {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [string] $Title = 'Fast Network Folder Copy'
    )

    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Show-ErrorMessage {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [string] $Title = 'Fast Network Folder Copy'
    )

    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
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

    $btnStart.Enabled = -not $Running
    $btnCancel.Enabled = $Running

    $btnBrowseSourceRoot.Enabled = -not $Running
    $btnBrowseTargetRoot.Enabled = -not $Running
    $btnBrowseFolder.Enabled = -not $Running

    $txtSourceRoot.ReadOnly = $Running
    $txtTargetRoot.ReadOnly = $Running
    $txtFolder.ReadOnly = $Running

    $btnOptions.Enabled = -not $Running
}

function Add-LogLine {
    param([string] $Line)

    if ($form.IsDisposed) {
        return
    }

    # All callers now run on the Windows Forms UI thread.
    $txtLog.AppendText($Line + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
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
    $optionsForm = New-Object System.Windows.Forms.Form
    $optionsForm.Text = 'Robocopy Options'
    $optionsForm.StartPosition = 'CenterParent'
    $optionsForm.ClientSize = New-Object System.Drawing.Size(775, 720)
    $optionsForm.MinimumSize = New-Object System.Drawing.Size(793, 759)
    $optionsForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $optionsForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $optionsForm.FormBorderStyle = 'Sizable'

    $optionsTitle = New-Object System.Windows.Forms.Label
    $optionsTitle.Text = 'Select the Robocopy behavior for this copy job.'
    $optionsTitle.AutoSize = $true
    $optionsTitle.Location = New-Object System.Drawing.Point(18, 16)
    $optionsForm.Controls.Add($optionsTitle)

    $lblOptionThreads = New-Object System.Windows.Forms.Label
    $lblOptionThreads.Text = 'Parallel threads (/MT)'
    $lblOptionThreads.AutoSize = $true
    $lblOptionThreads.Location = New-Object System.Drawing.Point(18, 52)
    $optionsForm.Controls.Add($lblOptionThreads)

    $optionThreads = New-Object System.Windows.Forms.NumericUpDown
    $optionThreads.Location = New-Object System.Drawing.Point(190, 49)
    $optionThreads.Size = New-Object System.Drawing.Size(90, 27)
    $optionThreads.Minimum = 1
    $optionThreads.Maximum = 128
    $optionThreads.Value = $script:RobocopyOptions.Threads
    $optionsForm.Controls.Add($optionThreads)

    $lblRetries = New-Object System.Windows.Forms.Label
    $lblRetries.Text = 'Retries (/R)'
    $lblRetries.AutoSize = $true
    $lblRetries.Location = New-Object System.Drawing.Point(310, 52)
    $optionsForm.Controls.Add($lblRetries)

    $optionRetries = New-Object System.Windows.Forms.NumericUpDown
    $optionRetries.Location = New-Object System.Drawing.Point(405, 49)
    $optionRetries.Size = New-Object System.Drawing.Size(90, 27)
    $optionRetries.Minimum = 0
    $optionRetries.Maximum = 100
    $optionRetries.Value = $script:RobocopyOptions.Retries
    $optionsForm.Controls.Add($optionRetries)

    $lblWait = New-Object System.Windows.Forms.Label
    $lblWait.Text = 'Wait seconds (/W)'
    $lblWait.AutoSize = $true
    $lblWait.Location = New-Object System.Drawing.Point(525, 52)
    $optionsForm.Controls.Add($lblWait)

    $optionWait = New-Object System.Windows.Forms.NumericUpDown
    $optionWait.Location = New-Object System.Drawing.Point(665, 49)
    $optionWait.Size = New-Object System.Drawing.Size(90, 27)
    $optionWait.Minimum = 0
    $optionWait.Maximum = 60
    $optionWait.Value = $script:RobocopyOptions.WaitSeconds
    $optionsForm.Controls.Add($optionWait)

    $autoProfile = New-Object System.Windows.Forms.CheckBox
    $autoProfile.Text = 'Automatically add /Z and /FFT for transfers between different servers/computers'
    $autoProfile.AutoSize = $true
    $autoProfile.Location = New-Object System.Drawing.Point(18, 88)
    $autoProfile.Checked = $script:RobocopyOptions.AutoProfile
    $optionsForm.Controls.Add($autoProfile)

    $lblSwitches = New-Object System.Windows.Forms.Label
    $lblSwitches.Text = 'Standard switches (check the commands you want Robocopy to use)'
    $lblSwitches.AutoSize = $true
    $lblSwitches.Location = New-Object System.Drawing.Point(18, 122)
    $optionsForm.Controls.Add($lblSwitches)

    $switchList = New-Object System.Windows.Forms.CheckedListBox
    $switchList.Location = New-Object System.Drawing.Point(18, 147)
    $switchList.Size = New-Object System.Drawing.Size(737, 405)
    $switchList.Anchor = 'Top,Bottom,Left,Right'
    $switchList.CheckOnClick = $true
    $switchDescriptions = [ordered]@{
        '/E' = 'Copy all subfolders, including empty ones'
        '/COPY:DAT' = 'Copy file data, attributes, and timestamps'
        '/DCOPY:DAT' = 'Copy folder data, attributes, and timestamps'
        '/J' = 'Use unbuffered I/O for large files'
        '/Z' = 'Use restartable mode'
        '/ZB' = 'Use restartable mode, then backup mode if access is denied'
        '/XJ' = 'Exclude junction points'
        '/FFT' = 'Use two-second timestamp tolerance'
        '/SEC' = 'Copy NTFS permissions and ACLs'
        '/SECFIX' = 'Apply security to skipped files too (use with /SEC)'
        '/MIR' = 'Mirror the source and delete extra destination items'
        '/PURGE' = 'Delete destination items that no longer exist in the source'
        '/MOV' = 'Move files and delete them from the source after copying'
        '/MOVE' = 'Move files and folders and delete them from the source'
        '/BYTES' = 'Show file sizes as bytes'
        '/ETA' = 'Show estimated completion time'
        '/FP' = 'Show full file paths'
        '/TEE' = 'Show output in the application log'
    }

    foreach ($entry in $switchDescriptions.GetEnumerator()) {
        $index = $switchList.Items.Add("$($entry.Key) — $($entry.Value)")
        if ($script:RobocopyOptions.Switches -contains $entry.Key) {
            $switchList.SetItemChecked($index, $true)
        }
    }
    $optionsForm.Controls.Add($switchList)

    $lblCustom = New-Object System.Windows.Forms.Label
    $lblCustom.Text = 'Additional switches (space-separated, for example /MAXAGE:30 /XO)'
    $lblCustom.AutoSize = $true
    $lblCustom.Anchor = 'Bottom,Left'
    $lblCustom.Location = New-Object System.Drawing.Point(18, 570)
    $optionsForm.Controls.Add($lblCustom)

    $customSwitches = New-Object System.Windows.Forms.TextBox
    $customSwitches.Text = $script:RobocopyOptions.CustomSwitches
    $customSwitches.Location = New-Object System.Drawing.Point(18, 595)
    $customSwitches.Size = New-Object System.Drawing.Size(737, 27)
    $customSwitches.Anchor = 'Bottom,Left,Right'
    $optionsForm.Controls.Add($customSwitches)

    $optionsWarning = New-Object System.Windows.Forms.Label
    $optionsWarning.Text = 'Warning: /MIR, /PURGE, /MOV, and /MOVE can delete files. Review selections before starting.'
    $optionsWarning.ForeColor = [System.Drawing.Color]::DarkRed
    $optionsWarning.AutoSize = $true
    $optionsWarning.Anchor = 'Bottom,Left'
    $optionsWarning.Location = New-Object System.Drawing.Point(18, 635)
    $optionsForm.Controls.Add($optionsWarning)

    $saveOptions = New-Object System.Windows.Forms.Button
    $saveOptions.Text = 'Save Options'
    $saveOptions.Location = New-Object System.Drawing.Point(515, 675)
    $saveOptions.Size = New-Object System.Drawing.Size(120, 32)
    $saveOptions.Anchor = 'Bottom,Right'
    $optionsForm.Controls.Add($saveOptions)

    $cancelOptions = New-Object System.Windows.Forms.Button
    $cancelOptions.Text = 'Cancel'
    $cancelOptions.Location = New-Object System.Drawing.Point(645, 675)
    $cancelOptions.Size = New-Object System.Drawing.Size(110, 32)
    $cancelOptions.Anchor = 'Bottom,Right'
    $optionsForm.Controls.Add($cancelOptions)

    $cancelOptions.Add_Click({ $optionsForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
    $saveLog = New-Object System.Windows.Forms.CheckBox
    $saveLog.Text = 'Save log to file (Copy Log YYYYMMDD.log)'
    $saveLog.AutoSize = $true
    $saveLog.Checked = $script:RobocopyOptions.SaveLog
    $logFolder = New-Object System.Windows.Forms.TextBox
    $logFolder.Text = $script:RobocopyOptions.LogFolder
    $logBrowse = New-Object System.Windows.Forms.Button
    $logBrowse.Text = 'Log folder...'
    $logFolder.Enabled = $saveLog.Checked
    $logBrowse.Enabled = $saveLog.Checked
    $saveLog.Add_CheckedChanged({ $logFolder.Enabled = $saveLog.Checked; $logBrowse.Enabled = $saveLog.Checked })
    $logBrowse.Add_Click({
        $chosen = Select-Folder -Description 'Choose where copy logs are saved.' -InitialPath $logFolder.Text
        if ($chosen) { $logFolder.Text = $chosen }
    })
    $saveOptions.Add_Click({
        if ($saveLog.Checked -and -not (Test-Path -LiteralPath $logFolder.Text -PathType Container)) {
            Show-ErrorMessage 'Select an existing folder for saved logs.'
            return
        }
        $custom = $customSwitches.Text.Trim()
        if ($custom -match '["\r\n]' -or ($custom -and ($custom.Split(' ') | Where-Object { $_ -and -not $_.StartsWith('/') }))) {
            Show-ErrorMessage 'Additional entries must be space-separated Robocopy switches beginning with /. Quotes and line breaks are not allowed.' 'Invalid Robocopy Options'
            return
        }

        $selectedSwitches = New-Object System.Collections.Generic.List[string]
        foreach ($checkedItem in $switchList.CheckedItems) {
            $selectedSwitches.Add(($checkedItem -split '\s+—\s+', 2)[0])
        }

        $script:RobocopyOptions.Threads = [int]$optionThreads.Value
        $script:RobocopyOptions.Retries = [int]$optionRetries.Value
        $script:RobocopyOptions.WaitSeconds = [int]$optionWait.Value
        $script:RobocopyOptions.AutoProfile = $autoProfile.Checked
        $script:RobocopyOptions.Switches = $selectedSwitches.ToArray()
        $script:RobocopyOptions.CustomSwitches = $custom
        $script:RobocopyOptions.SaveLog = $saveLog.Checked
        $script:RobocopyOptions.LogFolder = $logFolder.Text
        $optionsForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })

    $optionsForm.AcceptButton = $saveOptions
    $optionsForm.CancelButton = $cancelOptions
    # Let labels and buttons reserve their measured size, not fixed coordinates.
    $optionsForm.SuspendLayout()
    $optionsForm.Controls.Clear()
    $optionsForm.Size = New-Object System.Drawing.Size(793, 769)
    $optionsForm.MinimumSize = New-Object System.Drawing.Size(740, 680)
    $optionsForm.Padding = New-Object System.Windows.Forms.Padding(20)
    $layout = New-LayoutColumn
    $layout.AutoSize = $false
    $layout.Dock = 'Fill'
    $optionsForm.Controls.Add($layout)
    Add-LayoutRow $layout $optionsTitle
    $numberColumns = @()
    foreach ($pair in @(@($lblOptionThreads, $optionThreads), @($lblRetries, $optionRetries), @($lblWait, $optionWait))) {
        $column = New-LayoutColumn
        Add-LayoutRow $column $pair[0]
        Add-LayoutRow $column $pair[1]
        $numberColumns += $column
    }
    $numbers = New-LayoutRow $numberColumns
    foreach ($style in $numbers.ColumnStyles) { $style.SizeType = 'Percent'; $style.Width = 33.333 }
    Add-LayoutRow $layout $numbers
    $autoProfile.Text = 'Automatic cross-server tuning: add /Z and /FFT'
    Add-LayoutRow $layout $autoProfile
    Add-LayoutRow $layout $lblSwitches
    $switchList.IntegralHeight = $false
    $switchList.HorizontalScrollbar = $true
    Add-LayoutRow $layout $switchList $true
    $lblCustom.Text = 'Additional switches (example: /MAXAGE:30 /XO)'
    Add-LayoutRow $layout $lblCustom
    Add-LayoutRow $layout $customSwitches
    Add-LayoutRow $layout $saveLog
    Add-LayoutRow $layout (New-LayoutRow @($logFolder, $logBrowse) 0)
    $optionsWarning.Text = 'Warning: /MIR, /PURGE, /MOV and /MOVE can delete files.'
    Add-LayoutRow $layout $optionsWarning
    Add-LayoutRow $layout (New-LayoutRow @($saveOptions, $cancelOptions))
    $optionsForm.ResumeLayout($true)
    [void]$optionsForm.ShowDialog($form)
    $optionsForm.Dispose()
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
# GUI
# -----------------------------


# Build every control once, directly in its permanent parent.
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Fast Network Folder Copy - Layout repair 1.4'
$form.AutoScaleMode = 'None'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$workArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$form.Size = New-Object System.Drawing.Size([Math]::Min(1100, $workArea.Width - 24), [Math]::Min(1095, $workArea.Height - 24))

function New-MainControl {
    param([string] $Type, [string] $Name, [string] $Text, $Parent)
    $control = New-Object ('System.Windows.Forms.' + $Type)
    $control.Name = $Name
    $control.Text = $Text
    $control.Dock = 'None'
    $control.Anchor = 'Top,Left'
    $control.AutoSize = $false
    $control.Margin = New-Object System.Windows.Forms.Padding(0)
    $Parent.Controls.Add($control)
    return $control
}

$form.SuspendLayout()
$lblSource = New-MainControl 'Label' 'SourceCaption' 'Source root path' $form
$txtSourceRoot = New-MainControl 'TextBox' 'SourcePath' '' $form
$btnBrowseSourceRoot = New-MainControl 'Button' 'SourceBrowse' 'Browse...' $form
$lblTarget = New-MainControl 'Label' 'TargetCaption' 'Target folder path' $form
$txtTargetRoot = New-MainControl 'TextBox' 'TargetPath' '' $form
$btnBrowseTargetRoot = New-MainControl 'Button' 'TargetBrowse' 'Browse...' $form
$lblFolder = New-MainControl 'Label' 'FolderCaption' 'Folder to copy' $form
$txtFolder = New-MainControl 'TextBox' 'FolderPath' '' $form
$btnBrowseFolder = New-MainControl 'Button' 'FolderBrowse' 'Browse...' $form
$statusPanel = New-MainControl 'GroupBox' 'StatusPanel' 'Copy progress and activity' $form
$statusPanel.SuspendLayout()
$lblStatus = New-MainControl 'Label' 'StatusText' 'Ready' $statusPanel
$lblPercent = New-MainControl 'Label' 'ProgressText' 'Ready' $statusPanel
$progressBar = New-MainControl 'ProgressBar' 'ActivityBar' '' $statusPanel
$progressBar.Maximum = 1000
$lblCurrentItemCaption = New-MainControl 'Label' 'CurrentCaption' 'Current item:' $statusPanel
$lblCurrentItem = New-MainControl 'Label' 'CurrentItem' 'Waiting to start' $statusPanel
$lblCurrentItem.AutoEllipsis = $true
$lblFilesProgress = New-MainControl 'Label' 'FileCount' 'Files: 0 / 0' $statusPanel
$lblBytesProgress = New-MainControl 'Label' 'ByteCount' 'Data: 0 B / 0 B' $statusPanel
$lblSpeed = New-MainControl 'Label' 'Speed' 'Speed: pending' $statusPanel
$lblElapsed = New-MainControl 'Label' 'Elapsed' 'Elapsed: 00:00:00' $statusPanel
$txtLog = New-MainControl 'TextBox' 'ActivityLog' '' $statusPanel
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.WordWrap = $false
$txtLog.ScrollBars = 'Both'
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$btnOptions = New-MainControl 'Button' 'OptionsButton' 'Options...' $form
$btnStart = New-MainControl 'Button' 'StartButton' 'Start Copy' $form
$btnCancel = New-MainControl 'Button' 'CancelButton' 'Cancel' $form
$btnCancel.Enabled = $false

function Set-MainBounds {
    # Controls already have their final parent. No reparenting or table layouts.
    $form.SuspendLayout()
    $statusPanel.SuspendLayout()
    $clientWidth = $form.ClientSize.Width
    $clientHeight = $form.ClientSize.Height
    $lineHeight = [Math]::Max(24, $form.Font.Height + 8)
    $buttonHeight = [Math]::Max(38, $lineHeight + 12)
    $nextY = 24
    foreach ($field in @(
        @($lblSource, $txtSourceRoot, $btnBrowseSourceRoot),
        @($lblTarget, $txtTargetRoot, $btnBrowseTargetRoot),
        @($lblFolder, $txtFolder, $btnBrowseFolder)
    )) {
        $field[0].SetBounds(28, $nextY, $clientWidth - 56, $lineHeight)
        $nextY += $lineHeight + 6
        $field[1].SetBounds(28, $nextY, $clientWidth - 190, $lineHeight + 4)
        $field[2].SetBounds($clientWidth - 146, $nextY, 118, $buttonHeight)
        $nextY += $buttonHeight + 20
    }
    $statusPanel.SetBounds(28, $nextY, $clientWidth - 56, $clientHeight - $nextY - $buttonHeight - 44)
    $paneWidth = $statusPanel.ClientSize.Width
    $paneY = $lineHeight + 4
    $lblStatus.SetBounds(14, $paneY, $paneWidth - 160, $lineHeight)
    $lblPercent.SetBounds($paneWidth - 132, $paneY, 118, $lineHeight)
    $paneY += $lineHeight + 6
    $progressBar.SetBounds(14, $paneY, $paneWidth - 28, 22)
    $paneY += 30
    $captionWidth = [System.Windows.Forms.TextRenderer]::MeasureText('Current item:', $form.Font).Width + 12
    $lblCurrentItemCaption.SetBounds(14, $paneY, $captionWidth, $lineHeight)
    $lblCurrentItem.SetBounds(14 + $captionWidth, $paneY, $paneWidth - $captionWidth - 28, $lineHeight)
    $paneY += $lineHeight + 6
    $cellWidth = [int][Math]::Floor(($paneWidth - 28) / 4)
    $column = 0
    foreach ($control in @($lblFilesProgress, $lblBytesProgress, $lblSpeed, $lblElapsed)) {
        $control.AutoEllipsis = $true
        $control.SetBounds(14 + $column * $cellWidth, $paneY, $cellWidth, $lineHeight)
        $column++
    }
    $paneY += $lineHeight + 8
    $txtLog.SetBounds(14, $paneY, $paneWidth - 28, [Math]::Max(40, $statusPanel.ClientSize.Height - $paneY - 16))
    $nextX = 28
    foreach ($button in @($btnOptions, $btnStart, $btnCancel)) {
        $button.SetBounds($nextX, $clientHeight - $buttonHeight - 20, 130, $buttonHeight)
        $nextX += 142
    }
    $statusPanel.ResumeLayout($false)
    $form.ResumeLayout($false)
}

function Test-ControlBounds {
    param($Parent)
    $children = @($Parent.Controls)
    for ($i = 0; $i -lt $children.Count; $i++) {
        $control = $children[$i]
        if (-not $Parent.ClientRectangle.Contains($control.Bounds) -or $control.Width -le 0 -or $control.Height -le 0) {
            throw ('Control outside parent: ' + $control.Name + ' ' + $control.Bounds.ToString())
        }
        for ($j = $i + 1; $j -lt $children.Count; $j++) {
            if ($control.Bounds.IntersectsWith($children[$j].Bounds)) {
                throw ('Overlapping controls: ' + $control.Name + ' / ' + $children[$j].Name)
            }
        }
    }
}
Set-MainBounds
$form.Add_Shown({
    try {
        # Re-measure after handle creation, when the actual display font is known.
        Set-MainBounds
        Test-ControlBounds $form
        Test-ControlBounds $statusPanel
        $txtLog.AppendText("Layout repair 1.4 initialized. Ready to copy." + [Environment]::NewLine)
    } catch {
        $message = 'Layout check failed: ' + $_.Exception.Message
        $txtLog.AppendText($message + [Environment]::NewLine)
        Show-ErrorMessage $message
    }
})

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

$progressTimer = New-Object System.Windows.Forms.Timer
$progressTimer.Interval = 500


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
    if ($form.IsDisposed) {
        return
    }

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
    $txtLog.AppendText($Chunk)
    if ($txtLog.TextLength -gt 150000) { $txtLog.Text = $txtLog.Text.Substring($txtLog.TextLength - 100000) }
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
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
    $progressBar.Style = 'Marquee'
    if ($script:LogPath) { Add-LogLine ('Saving log: ' + $script:LogPath) }
    else { Add-LogLine 'File logging is off. Activity is shown only in this window.' }
    Add-LogLine ('Running as: ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $progressTimer.Start()
}

$progressTimer.Add_Tick({
    try {
        if (-not $script:CopyProcess) { return }
        $drained = Read-CopyLog
        $elapsed = (Get-Date) - $script:CopyStartedAt
        $lblElapsed.Text = 'Elapsed: ' + $elapsed.ToString('hh\:mm\:ss')
        if (-not $script:CopyProcess.HasExited -or -not $drained) { return }
        $code = $script:CopyProcess.ExitCode
        $progressTimer.Stop()
        Close-CopyReader
        $script:CopyProcess.Dispose()
        $script:CopyProcess = $null
        $progressBar.Style = 'Blocks'
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
        $progressBar.Style = 'Blocks'
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
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "The selected options can delete source or destination files:`r`n`r`n$($destructiveSwitches -join ', ')`r`n`r`nContinue?",
                'Confirm Destructive Robocopy Options',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $threads = [int]$script:RobocopyOptions.Threads
        $copySecurity = $script:RobocopyOptions.Switches -contains '/SEC'
        $transferProfile = Get-TransferProfile -Source $source -Destination $destination

        $txtLog.Clear()
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

$form.Add_FormClosing({
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
        $choice = [System.Windows.Forms.MessageBox]::Show(
            'A scan or copy operation is still running. Cancel it and close?',
            'Fast Network Folder Copy',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
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
$form.Add_FormClosed({
    $progressTimer.Stop()
    Close-CopyReader
    $progressTimer.Dispose()
})
[void]$form.ShowDialog()
