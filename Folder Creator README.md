# Multi-Folder Creator

A lightweight Windows desktop utility for creating multiple directories in a chosen destination in one operation. Built with **PowerShell 5.1** and **Windows Presentation Foundation (WPF)**.

This documentation describes the **Multi-Folder Creator 1.1** source currently in [Misc.-Code-Files](https://github.com/Jess-2000/Misc.-Code-Files).

## Features

- Create many folders from a newline-separated list.
- Create nested directory structures with relative paths such as `Projects\2026\Reports`.
- Preview proposed changes, including **Ready**, **Exists**, **Duplicate**, and **Invalid** entries.
- Skip existing folders and duplicate entries (case-insensitive comparison).
- Reject absolute paths, `..` traversal, invalid Windows filename characters, empty path segments, trailing spaces/periods, and reserved Windows device names.
- Show per-folder results and totals for created, skipped, and failed operations.
- Optional confirmation preview, destination opening, list clearing, and remembering the last destination.
- Resizable WPF interface; no separate GUI framework installation required on supported Windows systems.

## Requirements

- Windows with WPF and Windows PowerShell **5.1**.
- Permission to create directories in the selected destination.
- To run the prebuilt `.exe`, download it from the repository. You do **not** need PS2EXE just to run it.

## Getting started

1. Download [`Multi-Folder Creator.exe`](https://github.com/Jess-2000/Misc.-Code-Files/blob/main/Multi-Folder%20Creator.exe), or use the `.ps1` source.
2. Launch the application.
3. Select an **existing** destination folder using **Browse...** or enter its path.
4. Type one folder name or relative folder path per line.
5. Select **Preview** to inspect the plan.
6. Select **Create Folders**. If automatic preview is enabled, review the plan and select **Confirm Creation**.
7. Check **Preview and activity** for results.

### Example

With destination `C:\Work`, enter:

```text
Projects
Projects\2026
Projects\2026\Reports
Invoices
Archives\October
```

The application creates these folders under `C:\Work`, including required parent folders. It does not create anything outside the selected destination through ordinary relative-path traversal.

## Options

Open **Options...** to configure:

| Setting | Default | Behavior |
| --- | --- | --- |
| Automatically preview before creating folders | Off | Requires a review and second confirmation click |
| Open destination folder after successful creation | Off | Opens File Explorer when creation succeeds |
| Clear folder-name list after successful creation | Off | Clears the input list after success |
| Remember last selected destination | On | Restores the previous valid destination |

Use **Restore Defaults** in the options dialog to reset these preferences.

Settings are stored locally at:

```text
%LOCALAPPDATA%\MultiFolderCreator\settings.json
```

## Running the PowerShell source

Download [`Multi-Folder Creator.ps1`](https://github.com/Jess-2000/Misc.-Code-Files/blob/main/Multi-Folder%20Creator.ps1), then from its directory run:

```powershell
powershell.exe -NoProfile -STA -File '.\Multi-Folder Creator.ps1'
```

If Windows blocks the downloaded script, review the file and its origin before changing execution policy or unblocking it. Avoid permanently weakening system-wide execution-policy settings.

## Building an executable (optional)

The repository already provides an executable. If you prefer to rebuild it from source, install the community PS2EXE module and use its `Invoke-PS2EXE` command:

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE -InputFile '.\Multi-Folder Creator.ps1' `
    -OutputFile '.\Multi-Folder Creator.exe' `
    -NoConsole -STA
```

PS2EXE packages the PowerShell script as an executable; it does not convert it into a fully native program. Review third-party modules before installation. The packaged application has not been independently tested in every Windows environment.

## Behavior and limitations

- **No deletion feature:** The tool creates folders; it does not intentionally remove existing directories or their contents.
- **Existing folders are skipped:** It will not overwrite a directory merely because its name appears in the input.
- **Invalid entries block creation:** Correct invalid names before retrying; duplicate and existing entries can be skipped.
- **Partial completion is possible:** If permissions, disk availability, or another filesystem error prevents some creations, successful earlier creations are not rolled back.
- **Destination must exist:** Select or create the destination directory first.
- **Filesystem links:** The path validation is lexical. If a destination contains junctions or symbolic links, filesystem resolution can lead elsewhere; inspect the destination before using the tool with untrusted directory structures.
- **Long paths:** Windows filesystem and configuration limits may still apply.

## Troubleshooting

| Issue | Suggested action |
| --- | --- |
| Destination rejected | Confirm the folder exists and is accessible |
| Invalid name in preview | Remove invalid characters, absolute paths, `..`, or reserved names |
| Nothing to create | Entries may already exist or be duplicates |
| Access denied | Check directory permissions and whether the destination is protected |
| GUI does not appear from `.ps1` | Run on Windows with WPF and Windows PowerShell 5.1; use `-STA` |
| Preferences do not persist | Check write access to `%LOCALAPPDATA%\MultiFolderCreator` |

## Related utilities

See the [Misc.-Code-Files repository](https://github.com/Jess-2000/Misc.-Code-Files) for Project Snapshot Tool, Network Folder Copy Tool, and other scripts.

## License

See the repository's [LICENSE](https://github.com/Jess-2000/Misc.-Code-Files/blob/main/LICENSE).
