Option Explicit

Const WINDOW_HANDLE = 0
Const BROWSE_OPTIONS = &H10&

Const WD_DO_NOT_SAVE_CHANGES = 0
Const WD_ALERTS_NONE = 0
Const WD_EXPORT_FORMAT_PDF = 17
Const WD_EXPORT_OPTIMIZE_FOR_PRINT = 0
Const WD_EXPORT_ALL_DOCUMENT = 0
Const WD_EXPORT_DOCUMENT_CONTENT = 0
Const WD_EXPORT_CREATE_HEADING_BOOKMARKS = 1
Const MSO_AUTOMATION_SECURITY_FORCE_DISABLE = 3

' Change to True to replace existing PDFs.
Const OVERWRITE_EXISTING = False

' Change to True to include documents in subfolders.
Const INCLUDE_SUBFOLDERS = False

' Restart Microsoft Word after this many attempted conversions.
' Set to 0 to disable periodic restarts.
Const WORD_RESTART_INTERVAL = 250

' Number of times to attempt each document conversion.
Const MAX_CONVERSION_ATTEMPTS = 2

' Minimum acceptable generated PDF size, in bytes.
Const MINIMUM_PDF_SIZE = 100

Dim shell
Dim selectedFolder
Dim fileSystem
Dim wordApplication

Dim folderPath

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

If Not StartWordApplication() Then
    exitCode = 1
    CleanUp
    WScript.Quit exitCode
End If

ProcessFolder folderPath

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

        failedCount = failedCount + 1
        Exit Sub
    End If

    On Error Resume Next

    For Each currentFile In currentFolder.Files
        If Err.Number <> 0 Then
            errorNumber = Err.Number
            errorDescription = Err.Description
            Err.Clear

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
    Dim resultCode

    resultCode = 0

    For attemptNumber = 1 To MAX_CONVERSION_ATTEMPTS
        If wordApplication Is Nothing Then
            If Not StartWordApplication() Then
                resultCode = -1
                Exit For
            End If
        End If

        resultCode = TryConvertDocumentToPdf(inputPath)

        ' 1 = converted, 2 = skipped, -1 = failed.
        If resultCode = 1 Or resultCode = 2 Then
            Exit For
        End If

        If attemptNumber < MAX_CONVERSION_ATTEMPTS Then

            If Not RestartWordApplication() Then
                resultCode = -1
                Exit For
            End If
        End If
    Next

    Select Case resultCode
        Case 1
            convertedCount = convertedCount + 1

        Case 2
            skippedCount = skippedCount + 1

        Case Else
            failedCount = failedCount + 1
    End Select

    attemptedSinceRestart = attemptedSinceRestart + 1

    If WORD_RESTART_INTERVAL > 0 Then
        If attemptedSinceRestart >= WORD_RESTART_INTERVAL Then
            If Not RestartWordApplication() Then
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

    ' Return values:
    '  1 = converted
    '  2 = skipped
    ' -1 = failed
    TryConvertDocumentToPdf = -1

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
            TryConvertDocumentToPdf = 2
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

        CloseDocument document
        Exit Function
    End If

    On Error Resume Next

    document.ExportAsFixedFormat _
        temporaryOutputPath, _
        WD_EXPORT_FORMAT_PDF, _
        False, _
        WD_EXPORT_OPTIMIZE_FOR_PRINT, _
        WD_EXPORT_ALL_DOCUMENT, _
        1, _
        1, _
        WD_EXPORT_DOCUMENT_CONTENT, _
        True, _
        True, _
        WD_EXPORT_CREATE_HEADING_BOOKMARKS, _
        True, _
        True, _
        False

    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    CloseDocument document

    If errorNumber <> 0 Then
        DeletePartialPdf temporaryOutputPath

        Exit Function
    End If

    If Not fileSystem.FileExists(temporaryOutputPath) Then

        Exit Function
    End If

    On Error Resume Next
    Set outputFile = fileSystem.GetFile(temporaryOutputPath)
    errorNumber = Err.Number
    errorDescription = Err.Description
    Err.Clear
    On Error GoTo 0

    If errorNumber <> 0 Or outputFile Is Nothing Then

        DeletePartialPdf temporaryOutputPath
        Exit Function
    End If

    If outputFile.Size < MINIMUM_PDF_SIZE Then

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

        DeletePartialPdf temporaryOutputPath
        Exit Function
    End If

    TryConvertDocumentToPdf = 1
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
    End If
End Sub

Sub CleanUp()
    StopWordApplication

    Set selectedFolder = Nothing
    Set shell = Nothing
    Set fileSystem = Nothing
End Sub
