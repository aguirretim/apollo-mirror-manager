' Runs the mirror-watcher watchdog hidden (no console window).
' Path-relative: works from wherever this folder lives.
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "\watchdog-mirror.ps1""", 0, False
