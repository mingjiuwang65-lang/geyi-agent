# verify.ps1 - 验证上网助手网关客户端配置是否生效(浏览器等效) / 多服务器版
$ErrorActionPreference = 'SilentlyContinue'
$vScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $vScriptDir 'proxy_mode.ps1')
$Srv       = Get-ServerConfig
$ProxyAddr = Get-ProxyAddress $Srv
$GwHost    = $Srv.Host
$GwPort    = $Srv.Port
$ProxyPAC  = $Srv.CaUrl
# CA 会动态轮换, 不能再写死指纹: signed 模式优先从当前服务器的签名分发端点
# (明文内网 HTTP) 取当前指纹; static 模式读该服务器自带证书; none 模式无需 CA。
$CAThumb   = ''
$CACert    = Join-Path $vScriptDir $(if ($Srv.CaCert) { $Srv.CaCert } else { 'internet_assistant_ca.cer' })
$CaDistOk  = $false
if ($Srv.CaMode -eq 'signed') {
try {
  $req = [Net.HttpWebRequest]::Create($Srv.CaUrl)
  $req.Proxy = $null; $req.Timeout = 6000; $req.ReadWriteTimeout = 6000
  $rsp = $req.GetResponse()
  $sr = New-Object IO.StreamReader($rsp.GetResponseStream(), [Text.Encoding]::ASCII)
  $txt = $sr.ReadToEnd(); $rsp.Close()
  foreach ($l in ($txt -split "`r?`n")) { if ($l -match '^THUMB=([A-F0-9]{40})$') { $CAThumb = $Matches[1]; $CaDistOk = $true; break } }
} catch { }
}
if (-not $CAThumb -and (Test-Path $CACert)) {
  $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
  $c.Import($CACert); $CAThumb = $c.Thumbprint
  if ($Srv.CaMode -eq 'static') { $CaDistOk = $true }
}
$CUReg     = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$LMReg     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'

$out = New-Object System.Collections.ArrayList
$res = @{}
function Check([string]$name,[bool]$ok,[string]$detail){ [void]$out.Add(($(if($ok){'[PASS]'}else{'[FAIL]'}) + ' ' + $name + ' :: ' + $detail)); $res[$name] = $ok }

if ($Srv.CaMode -eq 'none') {
  Check 'CA(用户级)' $true ('当前服务器=' + $Srv.Name + ' 未启用 MITM, 无需根证书')
} else {
  $cu = Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Thumbprint -eq $CAThumb }
  Check 'CA(用户级)' ($cu -ne $null) ($(if($cu){$cu.Subject}else'未安装'))
}
$lm = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $CAThumb }
# 本机级 CA 属可选项: 非管理员运行 setup 时无法写 LocalMachine\Root, 但当前用户浏览器用 CU 级即可
[void]$out.Add('[INFO] CA(本机级/可选) :: ' + $(if($lm){'已安装'}else{'未安装(非管理员运行属正常; 当前用户浏览器用 CU 级即可)'}))

# CA 动态轮换自愈能力
Check 'CA源(当前服务器验签分发/本地证书)' $CaDistOk ("server=" + $Srv.ID + " mode=" + $Srv.CaMode + " 当前CA指纹=" + $CAThumb + "  端点走明文内网HTTP, 不受TLS/CA失效影响")
# 任务检查优先用 ScheduledTasks cmdlet(可同时取到 State/LastTaskResult), 避免某些环境把
# schtasks.exe 列入程序黑名单时误报"未安装"; Win7/PS2.0 无该 cmdlet 时自动回退 schtasks。
$taskOk = $false
$taskDetail = '未安装, 请重新运行 setup.bat'
try {
  $t  = Get-ScheduledTask -TaskName 'ProxyClient_CARefresh' -ErrorAction Stop
  $ti = Get-ScheduledTaskInfo -TaskName 'ProxyClient_CARefresh' -ErrorAction Stop
  $taskOk = ($t.State -ne 'Disabled')
  $taskDetail = 'ProxyClient_CARefresh State=' + $t.State + ' LastResult=' + $ti.LastTaskResult + ' LastRun=' + $ti.LastRunTime
} catch {
  $taskQ = & schtasks /Query /TN "ProxyClient_CARefresh" 2>&1
  $taskOk = ($LASTEXITCODE -eq 0)
  if ($taskOk) { $taskDetail = 'ProxyClient_CARefresh 已安装(schtasks)' }
}
Check 'CA自愈任务(每1分钟验签同步)' $taskOk $taskDetail
$refreshDir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
Check 'CA自愈组件(公钥+脚本+隐藏启动器)' ((Test-Path (Join-Path $refreshDir 'ca_sign_pub.xml')) -and (Test-Path (Join-Path $refreshDir 'ca_refresh.ps1')) -and (Test-Path (Join-Path $refreshDir 'ca_refresh.vbs'))) ($refreshDir)

$hkcuRev = (Get-ItemProperty $CUReg -Name CertificateRevocation -ErrorAction SilentlyContinue).CertificateRevocation
Check '吊销检查-HKCU' ($hkcuRev -eq 0) ("CertificateRevocation=$hkcuRev")
$hklmRev = (Get-ItemProperty $LMReg -Name CertificateRevocation -ErrorAction SilentlyContinue).CertificateRevocation
# HKLM 吊销需管理员; 本地信任根对吊销豁免, 实测浏览器等效链路不受影响, 故降级为 INFO 而非 FAIL
[void]$out.Add('[INFO] 吊销检查-HKLM(可选/需管理员) :: ' + $(if($hklmRev -eq 0){'已关闭'}else{'未设置(需管理员运行 setup.bat; 本地信任根豁免吊销, 浏览器等效链路实测仍通)'}))

$ps = (Get-ItemProperty $CUReg -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
$pe = (Get-ItemProperty $CUReg -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable

# fail-open 一致性: 按 MODE/GATEWAY 推导"此刻代理本应开还是关", 而不是一律要求 ProxyEnable=1。
# 离开公司(199不可达)或用户手动 Off 时, 直连态就是正确结果, 不应误报 FAIL。
$vdir0  = Join-Path $env:LOCALAPPDATA 'ProxyClient'
$stPath = Join-Path $vdir0 'proxy_state.txt'
$st = @{}
if (Test-Path $stPath) {
  foreach ($l in ([IO.File]::ReadAllText($stPath) -split "`r?`n")) { if ($l -match '^([^=]+)=(.*)$') { $st[$Matches[1]] = $Matches[2] } }
}
# MODE 以 proxy_mode.txt(用户最新意图)为准, 网关以实时 TCP 探测为准。
# 不能只信 proxy_state.txt 快照: Guard 每分钟异步写, 用户刚切过模式时快照可能是上一态。
$modeFile = Join-Path $vdir0 'proxy_mode.txt'
$md = 'Auto'
if (Test-Path $modeFile) {
  $m = ([IO.File]::ReadAllText($modeFile)).Trim()
  if ($m -match '^(Auto|On|Off)$') { $md = $m }
}
$gwLive = $false
try {
  $c = New-Object Net.Sockets.TcpClient
  $iar = $c.BeginConnect($GwHost, $GwPort, $null, $null)
  if ($iar.AsyncWaitHandle.WaitOne(1000, $false) -and $c.Connected) { $gwLive = $true }
  $c.Close()
} catch { }
$gw = $st['GATEWAY']
$expectOn = $true
if ($md -eq 'Off') { $expectOn = $false }
elseif ($md -eq 'On') { $expectOn = $true }
elseif (-not $gwLive) { $expectOn = $false }
$actuallyOn = ($pe -eq 1)
Check '代理状态与fail-open一致' ($actuallyOn -eq $expectOn) ("ProxyEnable=$pe  MODE=$md  实时" + $Srv.ID + "(" + $GwHost + ":" + $GwPort + ")=" + $(if($gwLive){'Reachable'}else{'Unreachable'}) + "  快照GATEWAY=$gw  期望=" + $(if($expectOn){'On'}else{'Off'}))

$pov = (Get-ItemProperty $CUReg -Name ProxyOverride -ErrorAction SilentlyContinue).ProxyOverride
if ($expectOn) {
  Check '显式代理配置(ProxyServer)' ($ps -eq $ProxyAddr) ("server=" + $Srv.ID + "  ProxyServer=$ps  期望=$ProxyAddr")
  Check '内网拆分(ProxyOverride含全部私有段)' ($pov -match '10\.\*' -and $pov -match '172\.' -and $pov -match '192\.168\.\*') ("ProxyOverride=[$pov]  私有段(10/172/192)需直连绕过代理, 否则无法访问内网服务器")
  Check '国内域名直连(微信/QQ例外)' ($pov -match 'qq\.com') ('微信域名经199返回502/ERR_CONNECTION_CLOSED, 须按199自身PAC白名单回归直连; 命中=' + ($pov -match 'qq\.com'))
} else {
  [void]$out.Add('[INFO] 显式代理配置/内网拆分 :: fail-open 直连态下代理项已清空, 属预期; 199 恢复后自动开回')
}

# exe 正式版组件: 主程序 + 单点写入 + Guard + CA 自愈
$trayDir   = Join-Path $env:LOCALAPPDATA 'ProxyClient'
$trayFiles = @('格一代理.exe','proxy_mode.ps1','proxy_tray_guard.ps1','proxy_tray_guard.vbs','ca_refresh.ps1','ca_refresh.vbs')
$trayOk = $true
foreach ($f in $trayFiles) { if (-not (Test-Path (Join-Path $trayDir $f))) { $trayOk = $false } }
Check '格一代理.exe + fail-open组件' $trayOk ($trayDir)

$cfgFiles = @('servers.conf','active_server.txt','app_version.txt','update.conf','update_check.ps1','geyi.ico','geyi_logo.png')
$cfgOk = $true
foreach ($f in $cfgFiles) { if (-not (Test-Path (Join-Path $trayDir $f))) { $cfgOk = $false } }
Check '多服务器/版本/升级/图标组件' $cfgOk ($trayDir + '  [' + ($cfgFiles -join ',') + ']')
$verInfo = @{}
$vp = Join-Path $trayDir 'app_version.txt'
if (Test-Path $vp) {
  foreach ($l in ([IO.File]::ReadAllText($vp, [Text.Encoding]::UTF8) -split "`r?`n")) {
    if ($l -match '^([A-Z]+)=(.*)$') { $verInfo[$Matches[1]] = $Matches[2] }
  }
}
Check '版本号文件(app_version.txt)' ($verInfo['VER'] -match '^\d+\.\d+\.\d+$') ('VER=' + $verInfo['VER'] + ' BUILD=' + $verInfo['BUILD'] + ' CFGVER=' + $verInfo['CFGVER'])
$srvList = @(Read-ServerTable)
Check '服务器配置可解析(servers.conf)' ($srvList.Count -ge 1) ('服务器数=' + $srvList.Count + ' 当前=' + $Srv.ID + '(' + $Srv.Name + ')  CA模式=' + $Srv.CaMode)
$updState = @{}
$usp = Join-Path $trayDir 'update_state.txt'
if (Test-Path $usp) {
  foreach ($l in ([IO.File]::ReadAllText($usp, [Text.Encoding]::UTF8) -split "`r?`n")) {
    if ($l -match '^([A-Z_]+)=(.*)$') { $updState[$Matches[1]] = $Matches[2] }
  }
}
[void]$out.Add('[INFO] 自动升级状态 :: STATUS=' + $(if($updState['STATUS']){$updState['STATUS']}else{'未检查'}) + ' PHASE=' + $updState['PHASE'] + ' 新版本=' + $updState['NEW_VER'] + '/' + $updState['NEW_BUILD'])

$gOk = $false; $gDetail = '未安装, 请重新运行 setup.bat'
try {
  $gt = Get-ScheduledTask -TaskName 'ProxyClient_TrayGuard' -ErrorAction Stop
  $gi = Get-ScheduledTaskInfo -TaskName 'ProxyClient_TrayGuard' -ErrorAction Stop
  $gOk = ($gt.State -ne 'Disabled')
  $gDetail = 'ProxyClient_TrayGuard State=' + $gt.State + ' LastResult=' + $gi.LastTaskResult
} catch { }
Check '保活任务(每1分钟)' $gOk $gDetail
try {
  $ga = (Get-ScheduledTask -TaskName 'ProxyClient_TrayGuard' -ErrorAction Stop).Actions[0].Execute
  Check '保活任务零窗口(GUI宿主)' ($ga -match 'wscript\.exe$') ('Action=' + $ga)
} catch { }

$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runVal = (Get-ItemProperty $runKey -Name ProxyClientTray -ErrorAction SilentlyContinue).ProxyClientTray
Check '用户级启动项(登录常驻)' ($runVal -match 'ProxyClient') ("$runVal")
Check '启动项指向exe托盘' ($runVal -match '格一代理\.exe' -and $runVal -match '/tray') ("$runVal")
$uKey = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\GeYiProxy' -ErrorAction SilentlyContinue
Check '卸载注册项(程序和功能)' ($null -ne $uKey -and $uKey.DisplayName -eq '格一代理' -and $uKey.UninstallString -match '/uninstall') ("DisplayName=$($uKey.DisplayName)  UninstallString=$($uKey.UninstallString)")
Check '卸载入口可执行(QuietUninstallString)' ($null -ne $uKey -and $uKey.QuietUninstallString -match '/uninstall') ("QuietUninstallString=$($uKey.QuietUninstallString)")

$hbOk = $false; $hbDetail = 'proxy_state.txt 不存在'
if ($st.ContainsKey('TS')) {
  try {
    $prev = [DateTime]::ParseExact($st['TS'], 'yyyy-MM-dd HH:mm:ss', $null)
    $age  = [Math]::Round(((Get-Date) - $prev).TotalSeconds, 0)
    $hbOk = ($age -lt 90)
    $hbDetail = '心跳=' + $age + '秒前'
  } catch { $hbDetail = 'TS 解析失败' }
}
Check '在线监测心跳(90秒内)' $hbOk ($hbDetail + '  MODE=' + $md + '  PROXY=' + $st['PROXY'] + '  COLOR=' + $st['COLOR'])
$uiAlive = 0
try { $uiAlive = @(Get-Process -Name '格一代理' -ErrorAction SilentlyContinue).Count } catch { }
[void]$out.Add('[INFO] 托盘UI进程(exe,可选) :: ' + $(if($uiAlive -gt 0){'运行中(' + $uiAlive + ')'}else{'未运行; 由 PT1M 在线监测任务独立保障, 不影响上网'}))
try {
  $t0 = Get-ScheduledTask -TaskName 'ProxyClient_CARefresh' -ErrorAction Stop
  $ta = $t0.Actions[0].Execute
  # 零窗口硬条件: 任务宿主必须是 GUI 子系统(wscript.exe)。
  # .bat -> 闪CMD黑框; powershell.exe -WindowStyle Hidden -> 仍闪PS蓝框(实测可见窗口采样>0)。
  $guiHost = ($ta -match 'wscript\.exe$')
  Check '自愈任务零窗口(GUI宿主wscript)' ($guiHost -and $ta -notmatch '\.bat$|cmd\.exe|powershell\.exe') ('Action=' + $ta + '  (GUI子系统宿主不分配控制台, CMD黑框/PS蓝框均为0)')
} catch { }

# 浏览器等效连通性: 浏览器读注册表 ProxyServer(=199:15888)+ProxyOverride, 不走 curl 的 --proxy 标志,
# 也不吃 https_proxy 等 env(沙箱/其他代理会干扰实测), 故先清 env, 再让 curl 走注册表系统代理。
$env:http_proxy = $null; $env:https_proxy = $null; $env:HTTP_PROXY = $null; $env:HTTPS_PROXY = $null

# 外网: 应经 199 代理(注册表 ProxyServer); --ssl-no-revoke 模拟 Chrome 对本地信任根豁免吊销
$live = & curl.exe --ssl-no-revoke https://www.baidu.com -o /dev/null -w "%{http_code}" --connect-timeout 12 2>$null
if ($live -match '^(200|301|302|303|307|308)$') {
  Check '外网连通(经当前代理, 浏览器等效)' $true ("HTTP=$live  代理+CA+证书链均正常")
} else {
  Check '外网连通(经当前代理, 浏览器等效)' $false ('curl 返回=[' + $live + ']  检查199代理是否在线/CA是否信任(先清掉 https_proxy env 后重试)')
}

# 内网: 应直连(ProxyOverride 含 10.*/172.*/192.168.*, 绕过代理) —— 本更新包的核心修复点
$internal = & curl.exe --ssl-no-revoke http://10.0.80.1:8092/ -o /dev/null -w "%{http_code}" --connect-timeout 8 2>$null
if ($internal -match '^(200|301|302|303|307|308)$') {
  Check '内网直连(ProxyOverride拆分生效)' $true ("HTTP=$internal  10.x 直连成功, 未被199劫持")
} else {
  Check '内网直连(ProxyOverride拆分生效)' $false ('curl 返回=[' + $internal + ']  检查 ProxyOverride 是否含 10.*')
}

$out | ForEach-Object { Write-Host $_ }

# 结果判定: 浏览器可用 = CA(用户级) + 显式代理 + 浏览器等效连通性 三项通过即 PASS
$essential = $res['CA(用户级)'] -and $res['代理状态与fail-open一致'] -and $res['外网连通(经当前代理, 浏览器等效)'] -and $res['在线监测心跳(90秒内)'] -and $res['保活任务(每1分钟)'] -and $res['格一代理.exe + fail-open组件'] -and $res['卸载注册项(程序和功能)'] -and $res['启动项指向exe托盘'] -and $res['多服务器/版本/升级/图标组件'] -and $res['版本号文件(app_version.txt)'] -and $res['服务器配置可解析(servers.conf)']
$result = $(if($essential){'PASS'}else{'PARTIAL/FAIL'})
$vdir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
if (-not (Test-Path $vdir)) { New-Item -ItemType Directory -Path $vdir -Force | Out-Null }
$vfile = Join-Path $vdir 'verify_result.txt'
$out -join "`n" | Out-File $vfile -Encoding utf8 -Force
Write-Host ("`nRESULT=" + $result + "  (详见 " + $vfile + ")")
Write-Host "注: plain curl 仍可能报 000(受 SCHANNEL 自身吊销检查影响, 属正常); Chrome 对本地信任根豁免吊销, 以浏览器实测为准。"
