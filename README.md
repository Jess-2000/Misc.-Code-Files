# Misc. Code Files

A collection of small applications, utilities, scripts, and programming exercises in PowerShell, Java, C#, VBScript, Bash, and Perl. Projects vary in purpose and maturity; check each tool's instructions before running it.

## Windows utilities

| Tool | What it does | Files |
| --- | --- | --- |
| [General Repository Snapshot Tool](General%20Repository%20Snapshot%20Tool.ps1) | Creates ZIP snapshots of project folders, with a Windows GUI and project profiles. | [PowerShell source](General%20Repository%20Snapshot%20Tool.ps1) · [Executable](General%20Repository%20Snapshot%20Tool.exe) · [Detailed guide](Project%20Snapshot%20Tool/README.md) |
| [Network Folder Copy Tool](Network%20Folder%20Copy%20Tool/) | WPF front end for Robocopy, including UNC paths, transfer options, progress/logging, and cancellation. | [PowerShell source](Network%20Folder%20Copy%20Tool/Network%20Folder%20Copy%20Tool.ps1) · [Executable](Network%20Folder%20Copy%20Tool/Network%20Folder%20Copy%20Tool.exe) · [Detailed guide](Network%20Folder%20Copy%20Tool/README.md) |
| [Multi-Folder Creator](Multi-Folder%20Creator.ps1) | Creates multiple named folders through a Windows GUI. | [PowerShell source](Multi-Folder%20Creator.ps1) · [Executable](Multi-Folder%20Creator.exe) |

> **Version note:** The repository files may not yet match the newer test builds discussed in development. In particular, Project Snapshot Tool v1.3.0 introduces direct-to-ZIP archiving and optional 7-Zip acceleration; verify which version of the source/EXE is committed before relying on those features.

## Other scripts and examples

| Language | Files |
| --- | --- |
| Java | [ArrayMethod.java](ArrayMethod.java), [DateConversion.java](DateConversion.java), [Lottery.java](Lottery.java), [OldMacDonald.java](OldMacDonald.java), [RandomGuess2.java](RandomGuess2.java), [TestAverager.java](TestAverager.java) |
| C# | [TemperatureConversion.cs](TemperatureConversion.cs) |
| VBScript | [Convert2PDF.vbs](Convert2PDF.vbs) |
| Bash | [Grayscale.sh](Grayscale.sh) |
| Perl | [NumSplitter.pl](NumSplitter.pl) |
| Sample data | [dates.txt](dates.txt) |

These are independent files rather than a single application. Their runtime requirements vary.

## Running PowerShell utilities

On Windows, download the relevant `.ps1` and run it in an appropriate PowerShell host, or use the supplied `.exe` where available. WPF requires Windows. Review scripts before execution, particularly when copying or deleting files. If Windows blocks a downloaded script, check its provenance and execution-policy guidance rather than permanently disabling system protections.

The EXEs are packaged PowerShell scripts, not standalone native applications. For rebuilding, see each tool's guide. Building requires the matching source and a PS2EXE installation; build scripts are not necessarily present in this repository yet.

## Safety and data handling

- **Snapshot Tool:** A successful ZIP creation does not guarantee a consistent point-in-time view if source files are changing during archiving. Inspect the archive before deleting original data.
- **Network Folder Copy:** Robocopy switches such as `/MIR`, `/PURGE`, `/MOV`, and `/MOVE` can delete files. The default configuration is non-destructive; verify both paths and custom options before copying.
- **General:** Test utilities on non-critical data first. No guarantee is made that all examples are production-ready.

## License

See [LICENSE](LICENSE) for the repository's licensing terms.
