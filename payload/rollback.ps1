# rollback.ps1 - 回滚上网助手网关客户端配置(移除CA信任+恢复吊销检查+清代理)
$ErrorActionPreference = 'SilentlyContinue'
$CUReg     = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$LMReg     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'

Write-Host '=== 上网助手网关客户端配置 - 回滚 ==='

# 0) 【顺序铁律】先停托盘/保活/启动项, 否则 1 分钟内 Guard 会把托盘拉起、托盘会把代理开回
#    正式卸载入口是 格一代理.exe /uninstall(同时清卸载注册项/快捷方式/程序文件);
#    本脚本保留为手工兜底, 清理顺序与 exe 卸载保持一致。
schtasks /Delete /TN "ProxyClient_TrayGuard" /F >$null 2>&1
try { Unregister-ScheduledTask -TaskName 'ProxyClient_TrayGuard' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'ProxyClientTray' -ErrorAction SilentlyContinue
$InstallDir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
if (-not $env:LOCALAPPDATA) { $InstallDir = Join-Path $env:TEMP 'ProxyClient' }
# 暂停标记: 防止清理窗口内残留的托盘/Guard 再做一次决策
try { [IO.File]::WriteAllText((Join-Path $InstallDir 'tray_disabled.flag'), 'rollback', [Text.Encoding]::ASCII) } catch { }
try { [IO.File]::WriteAllText((Join-Path $InstallDir 'tray_exit.flag'), 'rollback', [Text.Encoding]::ASCII) } catch { }
# 停 exe 托盘(精确按进程名, 不误杀其它程序)
try {
  Get-Process -Name '格一代理' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
} catch { }
# 精确按命令行匹配 PS 版旧托盘进程(兼容从旧包升级过来的机器)
try {
  Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'proxy_tray\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
# 卸载注册项 + 开始菜单快捷方式
try { Remove-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\GeYiProxy' -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try {
  $sd = Join-Path $InstallDir 'shortcut_dir.txt'
  if (Test-Path $sd) {
    $p = ([IO.File]::ReadAllText($sd)).Trim()
    if ($p -and (Test-Path $p)) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
  }
} catch { }
Write-Host '[托盘] 已停保活任务/启动项/exe托盘/卸载项'

# 1) 再停 CA 自动刷新任务, 否则 1 分钟内它会把刚删掉的 CA 重新装回来
schtasks /Delete /TN "ProxyClient_CARefresh" /F >$null 2>&1
try { Unregister-ScheduledTask -TaskName 'ProxyClient_CARefresh' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
foreach ($f in @('ca_refresh.ps1','ca_refresh.vbs','ca_refresh.bat','ca_sign_pub.xml','ca_refresh.log','ca_state.txt',
                 'proxy_mode.ps1','proxy_tray.ps1','proxy_tray.vbs','proxy_tray_guard.ps1','proxy_tray_guard.vbs',
                 'proxy_mode.txt','proxy_state.txt','proxy_mode.log','tray_probe.txt','tray_relaunch_ts.txt',
                 'tray_diag.txt','tray_diag_demo.txt','tray_disabled.flag','tray_exit.flag','simulate_unreachable.flag',
                 'app.log','install_manifest.txt','shortcut_dir.txt','verify_result.txt','status.txt','格一代理.exe')) {
  Remove-Item (Join-Path $InstallDir $f) -Force -ErrorAction SilentlyContinue
}
Write-Host '[CA自愈/托盘] 已移除全部任务并清理本地文件'

# 删除 CA(本机级 + 用户级) —— 按 Subject 枚举, 不写死指纹!
# 关键: 上网助手(IA)每次 GUI 重新登录/重启可能重新生成 mitmproxy CA 密钥对,
#       subject 固定为 O=mitmproxy, CN=mitmproxy 但指纹会变。写死单一指纹会漏删旧 CA,
#       同名不同钥的 CA 残留会让链引擎挑错公钥 -> Chrome 仍报 ERR_CERT_AUTHORITY_INVALID。
$caFound = @()
foreach ($s in @('Cert:\CurrentUser\Root','Cert:\LocalMachine\Root')) {
  Get-ChildItem $s -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'mitmproxy' } | ForEach-Object { $caFound += $_.Thumbprint }
}
$caFound = @($caFound | Select-Object -Unique)
foreach ($t in $caFound) {
  certutil -delstore -user Root $t >$null 2>&1
  certutil -delstore Root $t >$null 2>&1
}
# 复核删除结果, 残留必须显式告警(不能静默报成功)
$caLeft = @()
foreach ($s in @('Cert:\CurrentUser\Root','Cert:\LocalMachine\Root')) {
  Get-ChildItem $s -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'mitmproxy' } | ForEach-Object { $caLeft += ($s + ':' + $_.Thumbprint.Substring(0,16)) }
}
if ($caLeft.Count -gt 0) {
  Write-Host ('[CA] 警告: 仍有 ' + $caLeft.Count + ' 张 mitmproxy CA 未删除(需管理员): ' + ($caLeft -join ', ')) -ForegroundColor Yellow
  Write-Host '[CA] 请以管理员身份运行本脚本, 或手工执行: certutil -delstore Root <指纹>' -ForegroundColor Yellow
} else {
  Write-Host ('[CA] 已清除全部 mitmproxy CA (' + $caFound.Count + ' 张)')
}

# 恢复吊销检查为系统默认(删除我们写入的值)
Remove-ItemProperty -Path $CUReg -Name CertificateRevocation -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $LMReg -Name CertificateRevocation -ErrorAction SilentlyContinue
Write-Host '[吊销] 已恢复系统默认吊销检查'

# 清除代理(显式代理 + PAC 都清)
Remove-ItemProperty -Path $CUReg -Name AutoConfigURL -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $CUReg -Name ProxyServer -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $CUReg -Name ProxyOverride -ErrorAction SilentlyContinue
Set-ItemProperty -Path $CUReg -Name ProxyEnable -Value 0 -Force
Write-Host '[代理] 已清除代理配置(恢复直连)'

Write-Host '=== 回滚完成 ==='
