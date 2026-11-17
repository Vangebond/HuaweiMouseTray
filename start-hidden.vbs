' Start the NearLink battery tray silently (no console window).
' Extra arguments are forwarded to PowerShell, e.g. -Restart.
Option Explicit

Dim shell, fso, baseDir, scriptPath, extra, a, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = baseDir & "\HuaweiMouseTray.ps1"

If Not fso.FileExists(scriptPath) Then
    MsgBox "HuaweiMouseTray.ps1 not found: " & scriptPath, 16, "NearLink Battery"
    WScript.Quit 1
End If

extra = ""
For Each a In WScript.Arguments
    extra = extra & " " & a
Next

cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """" & extra
shell.Run cmd, 0, False
