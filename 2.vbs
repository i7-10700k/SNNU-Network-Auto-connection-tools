' ------------------------------------------------------------------
'  SNNU campus network auto-login : silent background launcher
'  ASCII-only on purpose (no encoding / code page issues).
' ------------------------------------------------------------------
Option Explicit
Dim fso, sh, baseDir, f, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = ""
For Each f In fso.GetFolder(baseDir).Files
  If LCase(Right(f.Name, 4)) = ".ps1" Then
    If ps1 = "" Then ps1 = f.Path
  End If
Next
If ps1 = "" Then WScript.Quit 1
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """ -Action Run"
sh.Run cmd, 0, False
