Option Explicit

Const WINDOW_HANDLE = 0
Const BROWSE_OPTIONS = &H10&

Const WD_DO_NOT_SAVE_CHANGES = 0
Const WD_ALERTS_NONE = 0
Const WD_EXPORT_FORMAT_PDF = 17
Const MSO_AUTOMATION_SECURITY_FORCE_DISABLE = 3

' Change to True to replace existing PDFs.
Const OVERWRITE_EXISTING = False

' Change to True to include documents in subfolders.
Const INCLUDE_SUBFOLDERS = False

' Restart Microsoft Word after this many attempted conversions.
' Set to 0 to disable periodic restarts.
Const WORD_RESTART_INTERVAL = 250

' Number of times to retry a document after restarting Microsoft Word.
Const MAX_CONVERSION_ATTEMPTS = 2

' Minimum acceptable generated PDF size, in bytes.
Const MINIMUM_PDF_SIZE = 100

' Name of the log file created in the selected folder.
Const LOG_FILE_NAME = "Converted Documents.log"

Dim shell
Dim selectedFolder
Dim fileSystem
Dim wordApplication
Dim logFile

Dim folderPath
Dim logPath

Dim convertedCount
Dim skippedCount
Dim failedCount
Dim attemptedSinceRestart

Dim exitCode

convertedCount = 0
skippedCount = 0
failedCount = 0
attemptedSinceRestart = 0
exitCode = 0

Set shell = Nothing
Set selectedFolder = Nothing
Set fileSystem = Nothing
Set wordApplication = Nothing
Set logFile = Nothing

If Not CreateFileSystem() Then
    WScript.Quit 1
End If

folderPath = GetInputFolder()

If Len(folderPath) = 0 Then
    CleanUp
    WScript.Quit 0
End If

If Not fileSystem.FolderExists(folderPath) Then
    CleanUp
    WScript.Quit 1
End If

OpenLogFile folderPath

WriteLog String(72, "=")
WriteLog "Document-to-PDF conversion started."
WriteLog "Folder: " & folderPath
WriteLog "Overwrite existing PDFs: " & CStr(OVERWRITE_EXISTING)
WriteLog "Include subfolders: " & CStr(INCLUDE_SUBFOLDERS)

If Not StartWordApplication() Then
    exitCode = 1
    CleanUp
    WScript.Quit exitCode
End If

ProcessFolder folderPath

WriteLog "Conversion finished."
WriteLog "Converted: " & convertedCount
WriteLog "Skipped: " & skippedCount
WriteLog "Failed: " & failedCount

If failedCount > 0 Then
    exitCode = 1
Else
    exitCode = 0
End If

CleanUp
WScript.Quit exitCode


Function CreateFileSystem()
    Dim errorNumber
    Dim errorDescription

    CreateFileSystem = False

    On Error Resume Next
    Set fileSystem = CreateObject("Scripting.FileSystemObject")
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or fileSystem Is Nothing Then
        CreateFileSystem = False
        Exit Function
    End If

    CreateFileSystem = True
End Function


Function GetInputFolder()
    Dim arguments
    Dim errorNumber

    GetInputFolder = ""

    Set arguments = WScript.Arguments

    ' A folder can be supplied on the command line for completely silent use.
    If arguments.Count > 0 Then
        GetInputFolder = Trim(CStr(arguments.Item(0)))
        Set arguments = Nothing
        Exit Function
    End If

    Set arguments = Nothing

    On Error Resume Next
    Set shell = CreateObject("Shell.Application")
    errorNumber = Err.Number
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or shell Is Nothing Then
        Exit Function
    End If

    On Error Resume Next
    Set selectedFolder = shell.BrowseForFolder( _
        WINDOW_HANDLE, _
        "Select a folder containing Word documents:", _
        BROWSE_OPTIONS, _
        "C:\" _
    )
    errorNumber = Err.Number
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or selectedFolder Is Nothing Then
        Exit Function
    End If

    On Error Resume Next
    GetInputFolder = selectedFolder.Self.Path

    If Err.Number <> 0 Then
        GetInputFolder = ""
        Err.Clear
    End If

    On Error GoTo 0
End Function


Sub OpenLogFile(inputFolderPath)
    Dim errorNumber

    logPath = fileSystem.BuildPath(inputFolderPath, LOG_FILE_NAME)

    On Error Resume Next
    Set logFile = fileSystem.OpenTextFile( _
        logPath, _
        8, _
        True, _
        -1 _
    )
    errorNumber = Err.Number
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Then
        ' Conversion can continue even if the log file cannot be created.
        Set logFile = Nothing
    End If
End Sub


Function StartWordApplication()
    Dim errorNumber
    Dim errorDescription

    StartWordApplication = False

    StopWordApplication

    On Error Resume Next
    Set wordApplication = CreateObject("Word.Application")
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or wordApplication Is Nothing Then
        WriteLogError _
            "Microsoft Word could not be started.", _
            errorNumber, _
            errorDescription

        Set wordApplication = Nothing
        Exit Function
    End If

    On Error Resume Next

    With wordApplication
        .Visible = False
        .DisplayAlerts = WD_ALERTS_NONE
        .AutomationSecurity = MSO_AUTOMATION_SECURITY_FORCE_DISABLE
    End With

    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Then
        WriteLogError _
            "Microsoft Word could not be configured for automation.", _
            errorNumber, _
            errorDescription

        StopWordApplication
        Exit Function
    End If

    attemptedSinceRestart = 0
    StartWordApplication = True
End Function


Sub StopWordApplication()
    If wordApplication Is Nothing Then
        Exit Sub
    End If

    On Error Resume Next
    wordApplication.Quit WD_DO_NOT_SAVE_CHANGES
    Err.Clear
    Set wordApplication = Nothing
    On Error GoTo 0
End Sub


Function RestartWordApplication()
    WriteLog "Restarting Microsoft Word automation."

    StopWordApplication
    RestartWordApplication = StartWordApplication()
End Function


Sub ProcessFolder(currentFolderPath)
    Dim currentFolder
    Dim currentFile
    Dim subfolder
    Dim errorNumber
    Dim errorDescription

    Set currentFolder = Nothing

    On Error Resume Next
    Set currentFolder = fileSystem.GetFolder(currentFolderPath)
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or currentFolder Is Nothing Then
        WriteLogError _
            "Could not access folder: " & currentFolderPath, _
            errorNumber, _
            errorDescription

        failedCount = failedCount + 1
        Exit Sub
    End If

    On Error Resume Next

    For Each currentFile In currentFolder.Files
        If Err.Number <> 0 Then
            errorNumber = Err.Number
            errorDescription = Err.Description
            Err.Clear

            WriteLogError _
                "Could not enumerate files in folder: " & currentFolderPath, _
                errorNumber, _
                errorDescription

            failedCount = failedCount + 1
            Exit For
        End If

        If IsSupportedDocument(currentFile) Then
            ConvertDocumentToPdf currentFile.Path
        End If
    Next

    Err.Clear
    On Error GoTo 0

    If INCLUDE_SUBFOLDERS Then
        On Error Resume Next

        For Each subfolder In currentFolder.SubFolders
            If Err.Number <> 0 Then
                errorNumber = Err.Number
                errorDescription = Err.Description
                Err.Clear

                WriteLogError _
                    "Could not enumerate subfolders in: " & currentFolderPath, _
                    errorNumber, _
                    errorDescription

                failedCount = failedCount + 1
                Exit For
            End If

            ProcessFolder subfolder.Path
        Next

        Err.Clear
        On Error GoTo 0
    End If

    Set subfolder = Nothing
    Set currentFile = Nothing
    Set currentFolder = Nothing
End Sub


Function IsSupportedDocument(documentFile)
    Dim extension

    IsSupportedDocument = False

    ' Ignore Microsoft Word temporary lock files.
    If Left(documentFile.Name, 2) = "~$" Then
        Exit Function
    End If

    extension = LCase(fileSystem.GetExtensionName(documentFile.Name))

    Select Case extension
        Case "doc", "docx", "docm", "rtf"
            IsSupportedDocument = True
    End Select
End Function


Sub ConvertDocumentToPdf(inputPath)
    Dim attemptNumber
    Dim conversionSucceeded

    conversionSucceeded = False

    For attemptNumber = 1 To MAX_CONVERSION_ATTEMPTS
        If wordApplication Is Nothing Then
            If Not StartWordApplication() Then
                failedCount = failedCount + 1
                Exit Sub
            End If
        End If

        conversionSucceeded = TryConvertDocumentToPdf(inputPath)

        If conversionSucceeded Then
            Exit For
        End If

        If attemptNumber < MAX_CONVERSION_ATTEMPTS Then
            WriteLog _
                "Retrying after Word restart: " & inputPath

            If Not RestartWordApplication() Then
                Exit For
            End If
        End If
    Next

    If Not conversionSucceeded Then
        failedCount = failedCount + 1
    End If

    attemptedSinceRestart = attemptedSinceRestart + 1

    If WORD_RESTART_INTERVAL > 0 Then
        If attemptedSinceRestart >= WORD_RESTART_INTERVAL Then
            If Not RestartWordApplication() Then
                WriteLog "ERROR: Microsoft Word could not be restarted."
            End If
        End If
    End If
End Sub


Function TryConvertDocumentToPdf(inputPath)
    Dim document
    Dim outputPath
    Dim temporaryOutputPath
    Dim parentFolder
    Dim baseName
    Dim errorNumber
    Dim errorDescription
    Dim outputFile

    TryConvertDocumentToPdf = False

    Set document = Nothing
    Set outputFile = Nothing

    parentFolder = fileSystem.GetParentFolderName(inputPath)
    baseName = fileSystem.GetBaseName(inputPath)
    outputPath = fileSystem.BuildPath(parentFolder, baseName & ".pdf")
    temporaryOutputPath = fileSystem.BuildPath( _
        parentFolder, _
        baseName & ".partial.pdf" _
    )

    If fileSystem.FileExists(outputPath) Then
        If OVERWRITE_EXISTING Then
            If Not DeleteFileSafely(outputPath) Then
                Exit Function
            End If
        Else
            skippedCount = skippedCount + 1
            WriteLog "Skipped; PDF already exists: " & outputPath
            TryConvertDocumentToPdf = True
            Exit Function
        End If
    End If

    If fileSystem.FileExists(temporaryOutputPath) Then
        If Not DeleteFileSafely(temporaryOutputPath) Then
            Exit Function
        End If
    End If

    On Error Resume Next

    ' Arguments:
    ' FileName, ConfirmConversions, ReadOnly, AddToRecentFiles
    Set document = wordApplication.Documents.Open( _
        inputPath, _
        False, _
        True, _
        False _
    )

    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or document Is Nothing Then
        WriteLogError _
            "Could not open document: " & inputPath, _
            errorNumber, _
            errorDescription

        CloseDocument document
        Exit Function
    End If

    On Error Resume Next

    document.ExportAsFixedFormat _
        temporaryOutputPath, _
        WD_EXPORT_FORMAT_PDF

    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    CloseDocument document

    If errorNumber <> 0 Then
        DeletePartialPdf temporaryOutputPath

        WriteLogError _
            "Could not create PDF from: " & inputPath, _
            errorNumber, _
            errorDescription

        Exit Function
    End If

    If Not fileSystem.FileExists(temporaryOutputPath) Then
        WriteLog _
            "Failed; export completed but the PDF was not found: " & _
            temporaryOutputPath

        Exit Function
    End If

    On Error Resume Next
    Set outputFile = fileSystem.GetFile(temporaryOutputPath)
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or outputFile Is Nothing Then
        WriteLogError _
            "Could not inspect the generated PDF: " & temporaryOutputPath, _
            errorNumber, _
            errorDescription

        DeletePartialPdf temporaryOutputPath
        Exit Function
    End If

    If outputFile.Size < MINIMUM_PDF_SIZE Then
        WriteLog _
            "Failed; generated PDF is too small: " & temporaryOutputPath

        Set outputFile = Nothing
        DeletePartialPdf temporaryOutputPath
        Exit Function
    End If

    Set outputFile = Nothing

    On Error Resume Next
    fileSystem.MoveFile temporaryOutputPath, outputPath
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Then
        WriteLogError _
            "Could not finalize generated PDF: " & outputPath, _
            errorNumber, _
            errorDescription

        DeletePartialPdf temporaryOutputPath
        Exit Function
    End If

    convertedCount = convertedCount + 1

    WriteLog _
        "Converted: " & inputPath & _
        " -> " & outputPath

    TryConvertDocumentToPdf = True
End Function


Function DeleteFileSafely(filePath)
    Dim errorNumber
    Dim errorDescription

    DeleteFileSafely = True

    If Not fileSystem.FileExists(filePath) Then
        Exit Function
    End If

    On Error Resume Next
    fileSystem.DeleteFile filePath, True
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Then
        WriteLogError _
            "Could not delete file: " & filePath, _
            errorNumber, _
            errorDescription

        DeleteFileSafely = False
    End If
End Function


Sub CloseDocument(ByRef document)
    If document Is Nothing Then
        Exit Sub
    End If

    On Error Resume Next
    document.Close WD_DO_NOT_SAVE_CHANGES
    Err.Clear
    Set document = Nothing
    On Error GoTo 0
End Sub


Sub DeletePartialPdf(pdfPath)
    Dim errorNumber
    Dim errorDescription

    If Not fileSystem.FileExists(pdfPath) Then
        Exit Sub
    End If

    On Error Resume Next
    fileSystem.DeleteFile pdfPath, True
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Then
        WriteLogError _
            "Could not delete incomplete PDF: " & pdfPath, _
            errorNumber, _
            errorDescription
    End If
End Sub


Sub WriteLog(message)
    If logFile Is Nothing Then
        Exit Sub
    End If

    On Error Resume Next

    logFile.WriteLine _
        FormatLogTimestamp(Now) & _
        "  " & _
        message

    Err.Clear
    On Error GoTo 0
End Sub


Sub WriteLogError(message, errorNumber, errorDescription)
    WriteLog _
        "ERROR: " & message & _
        " | Error " & CStr(errorNumber) & _
        ": " & errorDescription
End Sub


Function FormatLogTimestamp(timestamp)
    FormatLogTimestamp = _
        Year(timestamp) & "-" & _
        Right("0" & Month(timestamp), 2) & "-" & _
        Right("0" & Day(timestamp), 2) & " " & _
        Right("0" & Hour(timestamp), 2) & ":" & _
        Right("0" & Minute(timestamp), 2) & ":" & _
        Right("0" & Second(timestamp), 2)
End Function


Sub CleanUp()
    StopWordApplication

    If Not logFile Is Nothing Then
        On Error Resume Next
        logFile.Close
        Err.Clear
        Set logFile = Nothing
        On Error GoTo 0
    End If

    Set selectedFolder = Nothing
    Set shell = Nothing
    Set fileSystem = Nothing
End Sub
