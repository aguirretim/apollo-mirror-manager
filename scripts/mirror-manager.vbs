' Launches Apollo Mirror Manager without a console window.
' The script self-elevates (you'll get one UAC prompt).
' Path-relative: works from wherever this folder lives.
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "\mirror-manager.ps1""", 0, False
