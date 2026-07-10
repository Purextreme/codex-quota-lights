Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "CodexQuotaIndicator.ps1")
Set service = GetObject("winmgmts:\\.\root\cimv2")
Set processes = service.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'")
For Each process In processes
    If Not IsNull(process.CommandLine) Then
        If InStr(1, process.CommandLine, scriptPath, vbTextCompare) > 0 Then WScript.Quit 0
    End If
Next
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False
