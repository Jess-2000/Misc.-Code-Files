Fast Network Folder Copy Tool

Usage
1. Run Fast-Network-Folder-Copy.exe on Windows.
2. Select the source folder and target root.
3. The selected source folder name is appended to the target automatically.
4. Optionally select Options to customize the Robocopy command.
5. Select Start Copy.

Robocopy exit codes 0 through 7 are successful outcomes. Default settings do
not delete source or destination files. Selecting /MIR, /PURGE, /MOV, or /MOVE
can delete files and causes a warning before the transfer begins.

The included PowerShell source requires Windows PowerShell 5.1 or PowerShell 7+
on Windows.