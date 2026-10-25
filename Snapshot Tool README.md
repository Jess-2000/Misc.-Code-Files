# Project Snapshot Tool

A Windows WPF/PowerShell utility for saving a ZIP snapshot of a local project or repository, with reusable project profiles.

## Where to find it

The current repository keeps the application in its root:

- [General Repository Snapshot Tool.ps1](../General%20Repository%20Snapshot%20Tool.ps1)
- [General Repository Snapshot Tool.exe](../General%20Repository%20Snapshot%20Tool.exe)

This README can live in a dedicated `Project Snapshot Tool/` documentation folder without requiring the source files to move.

## Using the tool

1. Start the executable or run the `.ps1` script on Windows.
2. Choose or configure a project profile and select the repository directory.
3. Choose the snapshot destination and name.
4. Review exclusions and compression settings supported by the installed version.
5. Create the snapshot and inspect the resulting ZIP before relying on it as a backup.

Profiles are saved under `%LOCALAPPDATA%\RepositorySnapshotTool\projects.json` by the source currently in the repository.

## Compression versions

- **v1.2.2 test build:** Uses a short temporary staging directory and Windows `tar.exe` to produce ZIP archives, with cleanup fallbacks.
- **v1.3.0 test build:** Archives directly from source without the staging copy. Supports Fast, Balanced, and Maximum modes; uses 7-Zip when available and Windows `tar.exe` as fallback. Windows tar uses its own compression settings, so the modes may not change compression level without 7-Zip.

**Important:** These version descriptions refer to development/test packages. The root `.ps1` and `.exe` on GitHub may not yet be updated to v1.3.0. Verify the installed build rather than assuming feature parity.

## Requirements and building

- Windows with WPF and Windows PowerShell 5.1.
- Windows `tar.exe` for the relevant built-in ZIP implementation; 7-Zip is optional in v1.3.0.
- PS2EXE if you want to package the PowerShell source into an EXE.

When you have the matching test package's build script, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Project-Snapshot-Tool.ps1
```

The builder is **not currently linked from this repository**; obtain it from the corresponding source package. Avoid using an old builder with a newer source without checking the settings.

## Notes and limitations

- The tool does not make a filesystem-consistent snapshot of files modified during compression.
- Generated build/test artifacts may be included unless explicitly excluded, increasing archive size.
- ZIP success and CRC checks do not prove that every intended source file was captured; verify important snapshots against the source.
- Deep paths, inaccessible files, and file locks should be tested with your own repository.

[Back to repository overview](../README.md)
