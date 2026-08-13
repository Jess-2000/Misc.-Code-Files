#requires -Version 5.1
param(
    [switch]$GuiMode
)

<#
.SYNOPSIS
    Creates a clean ZIP snapshot of a local project folder using a GUI only.

.DESCRIPTION
    This single file replaces both the former CMD launcher and the PowerShell
    script. When started normally, it relaunches itself in a hidden PowerShell
    window so only the Windows Forms UI is visible.

    Robocopy output and other operational messages are written into the Status
    box in the UI instead of being shown in a console window.
#>

# Relaunch in a hidden PowerShell host. This replaces the old .cmd launcher.
if (-not $GuiMode) {
    $hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $scriptPath = $MyInvocation.MyCommand.Path

    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'The script must be saved to disk before it can be launched.'
    }

    $argumentList = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-WindowStyle', 'Hidden'
        '-File', ('"{0}"' -f $scriptPath)
        '-GuiMode'
    )

    Start-Process -FilePath $hostExe -ArgumentList $argumentList -WindowStyle Hidden
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:DefaultSource = 'C:\Development\PiratePDF'
$script:DefaultOutputFile = 'C:\Development\PiratePDF-BF-1039-Snapshot.zip'

function Show-Error {
    param([Parameter(Mandatory)][string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Snapshot Tool',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Write-Status {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TextBox]$TextBox,
        [AllowEmptyString()][string]$Message = ''
    )

    $TextBox.AppendText($Message + "`r`n")
    $TextBox.SelectionStart = $TextBox.TextLength
    $TextBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-NormalizedArchivePath {
    param([Parameter(Mandatory)][string]$OutputFile)

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

function New-ProjectSnapshot {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$OutputFile,
        [Parameter(Mandatory)][System.Windows.Forms.TextBox]$LogTextBox
    )

    $resolvedSource = [System.IO.Path]::GetFullPath($Source.Trim())
    $archive = Get-NormalizedArchivePath -OutputFile $OutputFile
    $resolvedOutput = [System.IO.Path]::GetDirectoryName($archive)
    $archiveBaseName = [System.IO.Path]::GetFileNameWithoutExtension($archive)
    $staging = Join-Path $resolvedOutput ('.' + $archiveBaseName + '-staging-' + [Guid]::NewGuid().ToString('N'))

    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) {
        throw "The source folder does not exist:`r`n$resolvedSource"
    }

    if ([string]::IsNullOrWhiteSpace($resolvedOutput)) {
        throw 'Choose a valid output location.'
    }

    if (-not (Test-Path -LiteralPath $resolvedOutput -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
    }

    if ($resolvedSource.TrimEnd('\') -eq $staging.TrimEnd('\')) {
        throw 'The staging folder cannot be the same as the source folder.'
    }

    $LogTextBox.Clear()
    Write-Status -TextBox $LogTextBox -Message "Source:  $resolvedSource"
    Write-Status -TextBox $LogTextBox -Message "Archive: $archive"
    Write-Status -TextBox $LogTextBox

    try {
        if (Test-Path -LiteralPath $archive) {
            Write-Status -TextBox $LogTextBox -Message 'Removing existing archive...'
            Remove-Item -LiteralPath $archive -Force -ErrorAction Stop
        }

        Write-Status -TextBox $LogTextBox -Message 'Copying project files...'
        Write-Status -TextBox $LogTextBox

        $robocopyArguments = @(
            $resolvedSource,
            $staging,
            '/E',
            '/XD', '.git', 'bin', 'obj',
            '/XF', '*.user', '*.suo',
            '/R:1',
            '/W:1',
            '/NP'
        )

        # Merge native stdout/stderr and display every Robocopy line in Status.
        & robocopy @robocopyArguments 2>&1 | ForEach-Object {
            Write-Status -TextBox $LogTextBox -Message $_.ToString()
        }
        $robocopyExitCode = $LASTEXITCODE

        Write-Status -TextBox $LogTextBox
        Write-Status -TextBox $LogTextBox -Message "Robocopy exit code: $robocopyExitCode"

        if ($robocopyExitCode -ge 8) {
            throw "Robocopy failed with exit code $robocopyExitCode."
        }

        Write-Status -TextBox $LogTextBox -Message 'Compressing snapshot...'

        Compress-Archive `
            -Path (Join-Path $staging '*') `
            -DestinationPath $archive `
            -CompressionLevel Optimal `
            -Force `
            -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            throw 'The ZIP archive was not created.'
        }

        $archiveItem = Get-Item -LiteralPath $archive -ErrorAction Stop

        Write-Status -TextBox $LogTextBox -Message 'Removing staging folder...'
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop

        $sizeInMegabytes = [Math]::Round($archiveItem.Length / 1MB, 2)
        Write-Status -TextBox $LogTextBox
        Write-Status -TextBox $LogTextBox -Message 'Snapshot completed successfully.'
        Write-Status -TextBox $LogTextBox -Message "Output name: $($archiveItem.Name)"
        Write-Status -TextBox $LogTextBox -Message "Size: $sizeInMegabytes MB"
        Write-Status -TextBox $LogTextBox -Message "Created: $($archiveItem.LastWriteTime)"

        return $archiveItem
    }
    catch {
        if (Test-Path -LiteralPath $staging) {
            try {
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Status -TextBox $LogTextBox
                Write-Status -TextBox $LogTextBox -Message 'Warning: The staging folder could not be removed:'
                Write-Status -TextBox $LogTextBox -Message $staging
            }
        }

        throw
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Project Snapshot Tool'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(720, 485)
$form.MinimumSize = New-Object System.Drawing.Size(736, 524)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.MaximizeBox = $false

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = 'Source folder'
$sourceLabel.AutoSize = $true
$sourceLabel.Location = New-Object System.Drawing.Point(20, 22)
$form.Controls.Add($sourceLabel)

$sourceTextBox = New-Object System.Windows.Forms.TextBox
$sourceTextBox.Location = New-Object System.Drawing.Point(20, 44)
$sourceTextBox.Size = New-Object System.Drawing.Size(585, 25)
$sourceTextBox.Anchor = 'Top, Left, Right'
$sourceTextBox.Text = $script:DefaultSource
$form.Controls.Add($sourceTextBox)

$sourceBrowseButton = New-Object System.Windows.Forms.Button
$sourceBrowseButton.Text = 'Browse...'
$sourceBrowseButton.Location = New-Object System.Drawing.Point(615, 42)
$sourceBrowseButton.Size = New-Object System.Drawing.Size(85, 28)
$sourceBrowseButton.Anchor = 'Top, Right'
$form.Controls.Add($sourceBrowseButton)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = 'Output ZIP file'
$outputLabel.AutoSize = $true
$outputLabel.Location = New-Object System.Drawing.Point(20, 88)
$form.Controls.Add($outputLabel)

$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputTextBox.Location = New-Object System.Drawing.Point(20, 110)
$outputTextBox.Size = New-Object System.Drawing.Size(585, 25)
$outputTextBox.Anchor = 'Top, Left, Right'
$outputTextBox.Text = $script:DefaultOutputFile
$form.Controls.Add($outputTextBox)

$outputBrowseButton = New-Object System.Windows.Forms.Button
$outputBrowseButton.Text = 'Save As...'
$outputBrowseButton.Location = New-Object System.Drawing.Point(615, 108)
$outputBrowseButton.Size = New-Object System.Drawing.Size(85, 28)
$outputBrowseButton.Anchor = 'Top, Right'
$form.Controls.Add($outputBrowseButton)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Status'
$logLabel.AutoSize = $true
$logLabel.Location = New-Object System.Drawing.Point(20, 154)
$form.Controls.Add($logLabel)

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(20, 176)
$logTextBox.Size = New-Object System.Drawing.Size(680, 231)
$logTextBox.Anchor = 'Top, Bottom, Left, Right'
$logTextBox.Multiline = $true
$logTextBox.ReadOnly = $true
$logTextBox.ScrollBars = 'Both'
$logTextBox.WordWrap = $false
$logTextBox.BackColor = [System.Drawing.SystemColors]::Window
$form.Controls.Add($logTextBox)

$createButton = New-Object System.Windows.Forms.Button
$createButton.Text = 'Create Snapshot'
$createButton.Location = New-Object System.Drawing.Point(455, 427)
$createButton.Size = New-Object System.Drawing.Size(130, 34)
$createButton.Anchor = 'Bottom, Right'
$form.Controls.Add($createButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Location = New-Object System.Drawing.Point(595, 427)
$closeButton.Size = New-Object System.Drawing.Size(105, 34)
$closeButton.Anchor = 'Bottom, Right'
$form.Controls.Add($closeButton)

$sourceBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the project source folder.'
    $dialog.ShowNewFolderButton = $false

    if (Test-Path -LiteralPath $sourceTextBox.Text -PathType Container) {
        $dialog.SelectedPath = $sourceTextBox.Text
    }

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
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
        $dialog.InitialDirectory = 'C:\Development'
        $dialog.FileName = 'PiratePDF-Snapshot.zip'
    }

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $outputTextBox.Text = $dialog.FileName
    }

    $dialog.Dispose()
})

$createButton.Add_Click({
    $createButton.Enabled = $false
    $closeButton.Enabled = $false
    $sourceBrowseButton.Enabled = $false
    $outputBrowseButton.Enabled = $false
    $form.UseWaitCursor = $true

    try {
        $archiveItem = New-ProjectSnapshot `
            -Source $sourceTextBox.Text `
            -OutputFile $outputTextBox.Text `
            -LogTextBox $logTextBox

        $result = [System.Windows.Forms.MessageBox]::Show(
            "Snapshot created successfully.`r`n`r`n$($archiveItem.FullName)`r`n`r`nOpen the containing folder?",
            'Snapshot Tool',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process explorer.exe -ArgumentList "/select,`"$($archiveItem.FullName)`""
        }
    }
    catch {
        Write-Status -TextBox $logTextBox
        Write-Status -TextBox $logTextBox -Message "ERROR: $($_.Exception.Message)"
        Show-Error -Message $_.Exception.Message
    }
    finally {
        $form.UseWaitCursor = $false
        $createButton.Enabled = $true
        $closeButton.Enabled = $true
        $sourceBrowseButton.Enabled = $true
        $outputBrowseButton.Enabled = $true
    }
})

$closeButton.Add_Click({
    $form.Close()
})

$form.AcceptButton = $createButton
$form.CancelButton = $closeButton

[void]$form.ShowDialog()
