' ProxyClient CA Refresh - silent launcher (GUI subsystem host)
' ------------------------------------------------------------------
' Why this file exists:
'   A Scheduled Task whose action is cmd.exe / powershell.exe allocates a
'   console (conhost) at process creation. -WindowStyle Hidden only hides
'   the window AFTER PowerShell has started, so a black/blue box still
'   flashes every minute. wscript.exe is a GUI-subsystem executable: it
'   never allocates a console, and WScript.Shell.Run(cmd, 0, True) passes
'   SW_HIDE in STARTUPINFO, so the child PowerShell is born hidden.
'
' Task action: wscript.exe //B //Nologo "<path>\ca_refresh.vbs"
'   //B      = batch mode, suppress any WSH message boxes
'   //Nologo = no logo
'   Run(..., True) waits for the refresh to finish, so the Task Scheduler
'   state/result still reflects the real outcome of the CA sync.
Option Explicit
Dim sh, fso, base, psExe, ps1, cmd, rc
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base = fso.GetParentFolderName(WScript.ScriptFullName)
psExe = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
ps1 = base & "\ca_refresh.ps1"

If Not fso.FileExists(ps1) Then WScript.Quit 1
If Not fso.FileExists(psExe) Then psExe = "powershell.exe"

cmd = """" & psExe & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"

On Error Resume Next
rc = sh.Run(cmd, 0, True)
If Err.Number <> 0 Then WScript.Quit 2
On Error GoTo 0

If IsNumeric(rc) Then
  WScript.Quit CInt(rc)
Else
  WScript.Quit 0
End If
