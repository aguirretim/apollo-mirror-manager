' Launches the mirror watcher hidden (no console window).
' Path-relative: works from wherever this folder lives.
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "\mirror-watcher.ps1""", 0, False
