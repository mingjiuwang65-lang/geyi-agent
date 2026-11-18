' ProxyTrayGuard launcher - short scheduled task, GUI subsystem host, no console window.
' Run(...,0,True): guard is a short-lived script, wait so task State/LastResult reflect real result.
Option Explicit
Dim sh, fso, here, ps1, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = here & "\proxy_tray_guard.ps1"
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, True
