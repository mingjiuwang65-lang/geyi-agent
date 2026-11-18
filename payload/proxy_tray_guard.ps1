# proxy_tray_guard.ps1 - fail-open 主执行体 (PT1M 短任务, 由 GUI 宿主隐藏启动)
#
# 架构要点(exe 正式版 2026-11-14):
#   自动决策权在这个每分钟短任务里, 托盘 exe (格一代理.exe) 降级为纯 UI。
#   托盘进程挂了不影响上网: 本任务照常开关代理; 下面第 5 步再把它拉起来。
#   所有注册表写入仍只经 proxy_mode.ps1 的 Set-ProxyState(单点写入红线)。
#
$ErrorActionPreference = 'SilentlyContinue'
$dir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
if (-not $env:LOCALAPPDATA) { $dir = Join-Path $env:TEMP 'ProxyClient' }
. (Join-Path $dir 'proxy_mode.ps1')

if (Test-Path $script:DisableFile) { return }

$mode = Get-ProxyMode
# A switch may happen WHILE this Guard is probing (3 tries, up to ~9s).
# Writing a decision computed with the OLD server would overwrite the new one.
$startId = Get-ActiveServerId

# 三次探测去抖: 任一成功即视为可达; 三次全失败才判定不可达
$reach = $false
for ($i = 0; $i -lt 3; $i++) {
  if (Test-Gateway) { $reach = $true; break }
  if ($i -lt 2) { Start-Sleep -Seconds 3 }
}

$curId = Get-ActiveServerId
if ($curId -ne $startId) {
  Write-ProxyLog ('GUARD SKIP decision: active changed ' + $startId + ' -> ' + $curId + ' during probe')
} else {
$before = Get-ProxyOn
if ($mode -eq 'Auto')      { [void](Set-ProxyState $reach 'guard/auto') }
elseif ($mode -eq 'On')    { [void](Set-ProxyState $true 'guard/forced-on') }
elseif ($mode -eq 'Off')   { [void](Set-ProxyState $false 'guard/forced-off') }
$proxyOn = Get-ProxyOn

$color = 'yellow'
if ($proxyOn -and $reach) { $color = 'green' }
elseif ($proxyOn -and -not $reach) { $color = 'red' }
$reason = 'guard'
if ($before -ne $proxyOn) {
  $reason = $(if($proxyOn){$script:Srv.Name + ' 恢复: 自动开启代理'}else{$script:Srv.Name + ' 连续不可达: 自动关闭代理'})
  Write-ProxyLog ('GUARD SWITCH -> ' + $(if($proxyOn){'ON'}else{'OFF'}) + '  mode=' + $mode + '  server=' + $script:Srv.ID)
}
Write-ProxyState $mode $proxyOn $reach $color $reason 0
}

# 自动升级: PT1M 短任务里做节流检查(默认 60 分钟一次), 不新增任务、不新增窗口。
# canary/all 灰度与 SHA256 校验全部在 update_check.ps1 内, 本文件只负责触发。
$upd = Join-Path $dir 'update_check.ps1'
if (Test-Path $upd) {
  try { & $upd | Out-Null } catch { }
}

# 托盘 UI 存活检查(exe 版): 按命令行匹配 格一代理.exe /tray, 不误杀其它进程
$exeFile = Join-Path $dir '格一代理.exe'
$trayAlive = $false
try {
  $ps = Get-WmiObject Win32_Process -ErrorAction SilentlyContinue
  if (@($ps | Where-Object { $_.CommandLine -match '格一代理\.exe' -and $_.CommandLine -match '/tray' }).Count -gt 0) { $trayAlive = $true }
} catch { }

# 1.3.0 「退出程序」标记: 用户主动完全退出后, 守护脚本不得再把托盘拉起来。
# 该标记由托盘菜单「退出程序 (完全停止)」写入, 由桌面快捷方式启动时清除。
$quitFlag = Join-Path $dir 'tray_quit.flag'
if (Test-Path $quitFlag) {
  Write-ProxyLog 'GUARD skip tray relaunch: user chose 退出程序 (tray_quit.flag present)'
} elseif (-not $trayAlive -and (Test-Path $exeFile)) {
  # 冷却 5 分钟: 避免受限会话里每分钟反复创建/回收进程
  $rl  = Join-Path $dir 'tray_relaunch_ts.txt'
  $due = $true
  if (Test-Path $rl) {
    try {
      $last = [DateTime]::ParseExact(([IO.File]::ReadAllText($rl)).Trim(), 'yyyy-MM-dd HH:mm:ss', $null)
      if (((Get-Date) - $last).TotalMinutes -lt 5) { $due = $false }
    } catch { }
  }
  if ($due) {
    try { [IO.File]::WriteAllText($rl, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [Text.Encoding]::ASCII) } catch { }
    try {
      Start-Process -FilePath $exeFile -ArgumentList '/tray' -WindowStyle Hidden | Out-Null
      Write-ProxyLog 'GUARD tray-exe relaunch issued'
    } catch { }
  }
}
