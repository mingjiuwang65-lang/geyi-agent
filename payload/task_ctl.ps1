# task_ctl.ps1 - 计划任务注册/删除/立即运行 (由 格一代理.exe 调用)
# Win8+/PS3+ 用原生 ScheduledTasks cmdlet(不启动任何外部 exe, 无窗口);
# Win7/PS2.0 无该模块时回退 schtasks.exe(仅真实客户机可用, AI 会话沙箱会拦)。
# 两个任务的宿主固定为 wscript.exe (GUI 子系统): 零 CMD 黑框 / 零 PowerShell 蓝框。
param([string]$Action = 'install')
$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
$ws  = Join-Path $env:WINDIR 'System32\wscript.exe'
$jobs = @(
  @{ Name = 'ProxyClient_CARefresh'; Vbs = (Join-Path $dir 'ca_refresh.vbs') },
  @{ Name = 'ProxyClient_TrayGuard'; Vbs = (Join-Path $dir 'proxy_tray_guard.vbs') }
)
$id    = [Security.Principal.WindowsIdentity]::GetCurrent()
$user  = $id.Name
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$lvl   = 'Limited'
if ($admin) { $lvl = 'Highest' }

foreach ($j in $jobs) {
  $n   = $j.Name
  $arg = '//B //Nologo "' + $j.Vbs + '"'
  if ($Action -eq 'install') {
    $ok = $false
    try {
      $act = New-ScheduledTaskAction -Execute $ws -Argument $arg
      $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
      # 2026-11-14 实测坑: New-ScheduledTaskSettingsSet 默认带
      #   DisallowStartIfOnBatteries=true / StopIfGoingOnBatteries=true。
      # 笔记本拔电源后 Windows 会把两个 PT1M 任务整体停掉 -> Guard 不写心跳 ->
      # 托盘 180s 超时反复弹"等待在线监测状态"/"海外可访问"。必须显式关掉这两个位。
      try {
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
      } catch {
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
      }
      try { $set.DisallowStartIfOnBatteries = $false; $set.StopIfGoingOnBatteries = $false } catch { }
      Register-ScheduledTask -TaskName $n -Action $act -Trigger $trg -Settings $set -User $user -RunLevel $lvl -Force -ErrorAction Stop | Out-Null
      # 任务计划程序里显示中文用途名, 界面统一称「在线监测」(旧称已弃用)。
      try {
        $td = Get-ScheduledTask -TaskName $n -ErrorAction Stop
        $td.Description = '格一代理 · 在线监测（每分钟检测网关可达性并自动开关代理）'
        Set-ScheduledTask -InputObject $td -ErrorAction Stop | Out-Null
      } catch { }
      $ok = $true
      Write-Output ('INSTALL_OK ' + $n)
    } catch {
      Write-Output ('INSTALL_CMDLET_FAIL ' + $n + ' : ' + $_.Exception.Message)
    }
    if (-not $ok) {
      $tr = '\"' + $ws + '\" //B //Nologo \"' + $j.Vbs + '\"'
      & cmd.exe /c ('schtasks /Create /TN "' + $n + '" /TR "' + $tr + '" /SC MINUTE /MO 1 /F') >$null 2>&1
      Write-Output ('INSTALL_FALLBACK_EXIT ' + $LASTEXITCODE + ' ' + $n)
      # Win7/PS2.0 回退路径: schtasks 没有电源策略开关, 导出 XML 改位后再注册回去。
      $xp = Join-Path $env:TEMP ('geyi_task_' + $n + '.xml')
      try {
        & cmd.exe /c ('schtasks /Query /TN "' + $n + '" /XML > "' + $xp + '"') >$null 2>&1
        if (Test-Path $xp) {
          $x = [IO.File]::ReadAllText($xp, [Text.Encoding]::Unicode)
          if ($x -match '<Task') {
            $x = $x.Replace('<DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>', '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>')
            $x = $x.Replace('<StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>', '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>')
            [IO.File]::WriteAllText($xp, $x, [Text.Encoding]::Unicode)
            & cmd.exe /c ('schtasks /Create /TN "' + $n + '" /XML "' + $xp + '" /F') >$null 2>&1
            Write-Output ('INSTALL_FALLBACK_BATTERY_PATCH ' + $n + ' exit=' + $LASTEXITCODE)
          }
        }
      } catch { }
      try { Remove-Item $xp -Force -EA SilentlyContinue } catch { }
    }
  } elseif ($Action -eq 'delete') {
    $exists = $false
    try { if (Get-ScheduledTask -TaskName $n -ErrorAction Stop) { $exists = $true } } catch { }
    if (-not $exists) { Write-Output ('DELETE_SKIP_NOTFOUND ' + $n); continue }
    try {
      Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop
      Write-Output ('DELETE_OK ' + $n)
    } catch {
      & cmd.exe /c ('schtasks /Delete /TN "' + $n + '" /F') >$null 2>&1
      Write-Output ('DELETE_FALLBACK_EXIT ' + $LASTEXITCODE + ' ' + $n)
    }
  } elseif ($Action -eq 'run') {
    try { Start-ScheduledTask -TaskName $n -ErrorAction Stop; Write-Output ('RUN_OK ' + $n) }
    catch { Write-Output ('RUN_FAIL ' + $n + ' : ' + $_.Exception.Message) }
  }
}
