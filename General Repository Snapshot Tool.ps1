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
    param([Parameter(Mandatory)][string]$Name)

    return @($script:ProjectSettings.Projects) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Set-ProjectProfile {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$OutputFile
    )

    $trimmedName = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedName)) {
        throw 'Enter a project name before saving defaults.'
    }

    $existing = Get-ProjectProfile -Name $trimmedName
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
$form.ClientSize = New-Object System.Drawing.Size(720, 555)
$form.MinimumSize = New-Object System.Drawing.Size(736, 594)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.MaximizeBox = $false


$projectLabel = New-Object System.Windows.Forms.Label
$projectLabel.Text = 'Project defaults'
$projectLabel.AutoSize = $true
$projectLabel.Location = New-Object System.Drawing.Point(20, 22)
$form.Controls.Add($projectLabel)

$projectComboBox = New-Object System.Windows.Forms.ComboBox
$projectComboBox.Location = New-Object System.Drawing.Point(20, 44)
$projectComboBox.Size = New-Object System.Drawing.Size(380, 25)
$projectComboBox.Anchor = 'Top, Left, Right'
$projectComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$form.Controls.Add($projectComboBox)

$saveDefaultsButton = New-Object System.Windows.Forms.Button
$saveDefaultsButton.Text = 'Save Defaults'
$saveDefaultsButton.Location = New-Object System.Drawing.Point(410, 42)
$saveDefaultsButton.Size = New-Object System.Drawing.Size(105, 28)
$saveDefaultsButton.Anchor = 'Top, Right'
$form.Controls.Add($saveDefaultsButton)

$deleteDefaultsButton = New-Object System.Windows.Forms.Button
$deleteDefaultsButton.Text = 'Delete Defaults'
$deleteDefaultsButton.Location = New-Object System.Drawing.Point(525, 42)
$deleteDefaultsButton.Size = New-Object System.Drawing.Size(115, 28)
$deleteDefaultsButton.Anchor = 'Top, Right'
$form.Controls.Add($deleteDefaultsButton)

$newDefaultsButton = New-Object System.Windows.Forms.Button
$newDefaultsButton.Text = 'New'
$newDefaultsButton.Location = New-Object System.Drawing.Point(650, 42)
$newDefaultsButton.Size = New-Object System.Drawing.Size(50, 28)
$newDefaultsButton.Anchor = 'Top, Right'
$form.Controls.Add($newDefaultsButton)

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = 'Source folder'
$sourceLabel.AutoSize = $true
$sourceLabel.Location = New-Object System.Drawing.Point(20, 92)
$form.Controls.Add($sourceLabel)

$sourceTextBox = New-Object System.Windows.Forms.TextBox
$sourceTextBox.Location = New-Object System.Drawing.Point(20, 114)
$sourceTextBox.Size = New-Object System.Drawing.Size(585, 25)
$sourceTextBox.Anchor = 'Top, Left, Right'
$sourceTextBox.Text = ''
$form.Controls.Add($sourceTextBox)

$sourceBrowseButton = New-Object System.Windows.Forms.Button
$sourceBrowseButton.Text = 'Browse...'
$sourceBrowseButton.Location = New-Object System.Drawing.Point(615, 112)
$sourceBrowseButton.Size = New-Object System.Drawing.Size(85, 28)
$sourceBrowseButton.Anchor = 'Top, Right'
$form.Controls.Add($sourceBrowseButton)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = 'Output ZIP file'
$outputLabel.AutoSize = $true
$outputLabel.Location = New-Object System.Drawing.Point(20, 158)
$form.Controls.Add($outputLabel)

$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputTextBox.Location = New-Object System.Drawing.Point(20, 180)
$outputTextBox.Size = New-Object System.Drawing.Size(585, 25)
$outputTextBox.Anchor = 'Top, Left, Right'
$outputTextBox.Text = ''
$form.Controls.Add($outputTextBox)

$outputBrowseButton = New-Object System.Windows.Forms.Button
$outputBrowseButton.Text = 'Save As...'
$outputBrowseButton.Location = New-Object System.Drawing.Point(615, 178)
$outputBrowseButton.Size = New-Object System.Drawing.Size(85, 28)
$outputBrowseButton.Anchor = 'Top, Right'
$form.Controls.Add($outputBrowseButton)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Status'
$logLabel.AutoSize = $true
$logLabel.Location = New-Object System.Drawing.Point(20, 224)
$form.Controls.Add($logLabel)

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(20, 246)
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
$createButton.Location = New-Object System.Drawing.Point(455, 497)
$createButton.Size = New-Object System.Drawing.Size(130, 34)
$createButton.Anchor = 'Bottom, Right'
$form.Controls.Add($createButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'Close'
$closeButton.Location = New-Object System.Drawing.Point(595, 497)
$closeButton.Size = New-Object System.Drawing.Size(105, 34)
$closeButton.Anchor = 'Bottom, Right'
$form.Controls.Add($closeButton)


function Refresh-ProjectList {
    param([string]$SelectedProject = '')

    $projectComboBox.Items.Clear()
    foreach ($project in @($script:ProjectSettings.Projects) | Sort-Object Name) {
        [void]$projectComboBox.Items.Add($project.Name)
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

    $profile = Get-ProjectProfile -Name $name
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

$projectComboBox.Add_SelectionChangeCommitted({
    Load-SelectedProject
})

$saveDefaultsButton.Add_Click({
    try {
        Set-ProjectProfile `
            -Name $projectComboBox.Text `
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
    $profile = Get-ProjectProfile -Name $name

    if ($null -eq $profile) {
        Show-Error -Message 'Select a saved project before deleting defaults.'
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete the saved defaults for '$name'?",
        'Snapshot Tool',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
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
        if (-not [string]::IsNullOrWhiteSpace($sourceTextBox.Text) -and (Test-Path -LiteralPath $sourceTextBox.Text -PathType Container)) {
            $dialog.InitialDirectory = $sourceTextBox.Text
        }
        else {
            $dialog.InitialDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        }

        $projectName = $projectComboBox.Text.Trim()
        $dialog.FileName = if ([string]::IsNullOrWhiteSpace($projectName)) { 'Project-Snapshot.zip' } else { "$projectName-Snapshot.zip" }
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
    $saveDefaultsButton.Enabled = $false
    $deleteDefaultsButton.Enabled = $false
    $newDefaultsButton.Enabled = $false
    $projectComboBox.Enabled = $false
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
        $saveDefaultsButton.Enabled = $true
        $deleteDefaultsButton.Enabled = $true
        $newDefaultsButton.Enabled = $true
        $projectComboBox.Enabled = $true
    }
})

$closeButton.Add_Click({
    $form.Close()
})

$form.AcceptButton = $createButton
$form.CancelButton = $closeButton

[void]$form.ShowDialog()
