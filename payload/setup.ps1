# setup.ps1 - 上网助手网关客户端配置(不安装上网助手软件, 仅下发CA信任+代理配置)
# 适用: Windows 7 / 10 / 11
$ErrorActionPreference = 'SilentlyContinue'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProxyPAC  = 'http://10.0.50.199:15889/proxy.pac'
$CACert    = Join-Path $ScriptRoot 'internet_assistant_ca.cer'
$CUReg     = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$LMReg     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'

function Is-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host '=== 上网助手网关客户端配置 - 安装 ==='

# 1) 安装 CA 到"受信任的根证书颁发机构"
#    上网助手(MITM)用它给被拦截站点签发假证书, 客户机必须信任它, 否则浏览器报证书错误
#    !!! 关键(2026-11-14 实证): IA 每次 GUI 重新登录/重启可能重新生成 CA 密钥对,
#        subject 恒为 O=mitmproxy, CN=mitmproxy 但指纹变化。若本机残留"同名不同钥"的旧 CA,
#        Windows 链引擎会挑错公钥 -> NotSignatureValid -> Chrome 报 ERR_CERT_AUTHORITY_INVALID。
#        故导入前必须按 Subject 清空所有旧 mitmproxy CA, 再导入包内这一代 CA。
if (Test-Path $CACert) {
  $expected = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
  $expected.Import($CACert)
  $CAThumb = $expected.Thumbprint

  $old = @()
  foreach ($s in @('Cert:\CurrentUser\Root','Cert:\LocalMachine\Root')) {
    Get-ChildItem $s -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'mitmproxy' -and $_.Thumbprint -ne $CAThumb } | ForEach-Object { $old += $_.Thumbprint }
  }
  $old = @($old | Select-Object -Unique)
  foreach ($t in $old) {
    certutil -delstore -user Root $t >$null 2>&1
    certutil -delstore Root $t >$null 2>&1
  }
  if ($old.Count -gt 0) { Write-Host ('[CA] 已清理 ' + $old.Count + ' 张过期/不匹配的旧 mitmproxy CA') }

  $okLM = $false
  if (Is-Admin) {
    certutil -addstore -f Root $CACert >$null 2>&1
    $okLM = $?
  }
  certutil -addstore -f -user Root $CACert >$null 2>&1

  # 导入后校验: 信任根里必须只剩这一代 CA
  $bad = @()
  foreach ($s in @('Cert:\CurrentUser\Root','Cert:\LocalMachine\Root')) {
    Get-ChildItem $s -ErrorAction SilentlyContinue | Where-Object { $_.Subject -match 'mitmproxy' -and $_.Thumbprint -ne $CAThumb } | ForEach-Object { $bad += ($s + ':' + $_.Thumbprint.Substring(0,16)) }
  }
  if ($bad.Count -gt 0) {
    Write-Host ('[CA] 警告: 仍残留旧 CA(需管理员清理): ' + ($bad -join ', ')) -ForegroundColor Yellow
  } else {
    Write-Host ('[CA] 已导入当前代 CA ' + $CAThumb + '  (本机级=' + $okLM + ', 用户级=已装, 旧CA已清)')
  }
} else {
  Write-Host '[CA] 未找到 internet_assistant_ca.cer, 请确认包完整' -ForegroundColor Red
}

# 2) 关闭证书吊销检查(关键!)
#    上网助手签发的站点证书不含有效的 CRL/OCSP, Windows 默认会因"吊销状态未知"掐断 TLS 握手
#    HKCU 对部分客户端有效; HKLM 才对 Schannel(Chrome / curl)真正生效(需管理员)
Set-ItemProperty -Path $CUReg -Name CertificateRevocation -Value 0 -Type DWord -Force
Write-Host '[吊销] HKCU CertificateRevocation=0'
if (Is-Admin) {
  Set-ItemProperty -Path $LMReg -Name CertificateRevocation -Value 0 -Type DWord -Force
  Write-Host '[吊销] HKLM CertificateRevocation=0 (已生效, 覆盖 Chrome/curl)'
} else {
  Write-Host '[吊销] HKLM 需管理员权限未设置 - 请以管理员运行本脚本以彻底生效' -ForegroundColor Yellow
}

# 3) 设置系统代理为显式代理(外网经 199 MITM 网关), 并把内网 10.x 拆分直连
#    关键实测结论: 本环境 Chrome 不采纳 PAC(AutoConfigURL, 两种 ProxyEnable 取值均直连超时 ERR_CONNECTION_TIMED_OUT),
#    但采纳显式代理(ProxyServer)。故用显式代理最稳, 无头 Chrome 实证可上 google(251KB)。
#    !!! 必须同时设置 ProxyOverride 代理例外 !!!
#    原因: 仅设 ProxyServer 会让 ALL 流量(含内网 10.x)被强制经 199, 而 199(MITM 网关)不代理内网,
#          导致原本直连可达的 10 段服务器(10.0.80.1 / 10.0.102.1 / 10.0.103.x 等)无法访问。
#    做法: ProxyOverride 排除内网段, 浏览器/WinHTTP 对 10.* 直连, 其余仍走 199 管控。
#          <local> = 本地/同子网地址直连。已按 RFC1918 拆分全部私有段(10.*/172.16-31.*/192.168.*)直连,
#          仅公网流量走 199 管控(移动"一机一PIN"网关意图); 内网服务器恢复直连可达。
#    2026-11-14 追加: 微信/QQ 域名也必须直连。199 自身 proxy.pac 的分流逻辑是
#          "只有 domains 白名单(海外站)走 199, 其余一律 DIRECT", 而 mp.weixin.qq.com 等不在白名单;
#          实测强送 199 返回 502 错误网关, 微信内置浏览器表现为 ERR_CONNECTION_CLOSED。
#          补进 ProxyOverride 只是回到 199 既定的 DIRECT 策略, 不撤销管控:
#          海外域名(google 等)与其余公网域名仍经 199 MITM(实测 baidu 证书仍为 mitmproxy)。
#    注: 代理服务器 10.0.50.199 本身是 ProxyServer 固定入口, 不受 ProxyOverride 影响(浏览器始终直连它转发)。
$ProxyBypass = '10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>;*.qq.com;*.qpic.cn;*.qlogo.cn;*.gtimg.cn;*.gtimg.com;*.wechat.com;*.weixin.com;*.tencent.com'
Set-ItemProperty -Path $CUReg -Name ProxyEnable -Value 1 -Force
Set-ItemProperty -Path $CUReg -Name ProxyServer -Value 'http://10.0.50.199:15888' -Force
Set-ItemProperty -Path $CUReg -Name ProxyOverride -Value $ProxyBypass -Force
Remove-ItemProperty -Path $CUReg -Name AutoConfigURL -ErrorAction SilentlyContinue
Write-Host ('[代理] ProxyServer=http://10.0.50.199:15888  ProxyOverride=' + $ProxyBypass + '  (外网走199, 内网10.x直连)')

# 3.1) 刷新系统代理设置, 让浏览器/WinHTTP 立即生效(免重开浏览器)
try {
  $sig = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
  $t = Add-Type -MemberDefinition $sig -Name W -Namespace WI -PassThru -ErrorAction Stop
  $t::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)  # 39=INTERNET_OPTION_SETTINGS_CHANGED
  $t::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)  # 37=INTERNET_OPTION_REFRESH
  Write-Host '[代理] 已刷新系统代理设置(浏览器/WinHTTP 立即生效)'
} catch {
  Write-Host '[代理] 自动刷新失败, 请完全退出并重启浏览器以生效' -ForegroundColor Yellow
}

# 4) 安装 CA 自动刷新任务(动态轮换 CA 自愈, 免重装包)
#    问题: IA 崩溃后人工 GUI 重新登录可能重新生成 mitmproxy CA 密钥对。老包客户机装的是旧 CA,
#          会集体报 ERR_CERT_AUTHORITY_INVALID, 且 HTTPS 本身验不过 -> 无法用 HTTPS 远程更新 CA。
#    机制: 199:15889/ca.txt 走明文内网 HTTP(10.* 直连, 不经 MITM)发布"当前 CA(DER) + RSA-SHA256 签名";
#          客户端每 1 分钟用包内固定公钥验签, 自动同步新 CA。签名私钥只在 199, 不随 CA 轮换。
#          验签失败/证书非自签名/subject 不符一律拒绝, 防止伪造 CA 被植入。
$InstallDir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
if (-not $env:LOCALAPPDATA) { $InstallDir = Join-Path $env:TEMP 'ProxyClient' }
try {
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  Copy-Item (Join-Path $ScriptRoot 'ca_refresh.ps1')   (Join-Path $InstallDir 'ca_refresh.ps1') -Force
  Copy-Item (Join-Path $ScriptRoot 'ca_refresh.vbs')  (Join-Path $InstallDir 'ca_refresh.vbs') -Force
  Copy-Item (Join-Path $ScriptRoot 'ca_sign_pub.xml') (Join-Path $InstallDir 'ca_sign_pub.xml') -Force
  # 【无窗口关键】计划任务的宿主必须是 GUI 子系统程序, 否则任务计划程序每轮都会分配
  # 控制台窗口: 执行 .bat -> 闪 CMD 黑框; 直接执行 powershell.exe -> -WindowStyle Hidden
  # 是"先开窗再隐藏", 仍闪 PowerShell 蓝框(2026-11-14 本机 20s 高频采样实测可见窗口=2)。
  # wscript.exe 是系统自带 GUI 宿主, 从不分配控制台; VBS 用 Run(cmd,0,True) 以 SW_HIDE
  # 启动 PowerShell 并等待, 子进程从创建起就是隐藏的 -> 黑框/蓝框都为 0。
  # ca_refresh.bat 仅保留供人工手动运行, 计划任务【绝不】指向它。
  $bat = Join-Path $InstallDir 'ca_refresh.bat'
  [IO.File]::WriteAllText($bat, '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ca_refresh.ps1"' + "`r`n", [Text.Encoding]::ASCII)
  $ps1 = Join-Path $InstallDir 'ca_refresh.ps1'
  $vbs = Join-Path $InstallDir 'ca_refresh.vbs'
  $ws  = Join-Path $env:WINDIR 'System32\wscript.exe'
  if (-not (Test-Path $ws)) { $ws = 'wscript.exe' }
  $wsArg = '//B //Nologo "' + $vbs + '"'

  $created = $false
  try {
    $act = New-ScheduledTaskAction -Execute $ws -Argument $wsArg
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $lvl = 'Limited'
    if (Is-Admin) { $lvl = 'Highest' }
    Register-ScheduledTask -TaskName 'ProxyClient_CARefresh' -Action $act -Trigger $trg -Settings $set -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel $lvl -Force -ErrorAction Stop | Out-Null
    $created = $true
  } catch { }
  if (-not $created) {
    # Windows 7 / PowerShell 2.0 fallback: /TR 同样指向 wscript GUI 宿主
    $trVal = '\"' + $ws + '\" //B //Nologo \"' + $vbs + '\"'
    $line = '/Create /TN "ProxyClient_CARefresh" /TR "' + $trVal + '" /SC MINUTE /MO 1 /F'
    & cmd.exe /c ('schtasks ' + $line) >$null 2>&1
    $created = ($LASTEXITCODE -eq 0)
  }
  if ($created) {
    Write-Host '[CA自愈] 已安装计划任务 ProxyClient_CARefresh (每1分钟验签同步当前CA)'
    # 立即跑一次, 保证装完就是当代 CA
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'ca_refresh.ps1') 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
  } else {
    Write-Host '[CA自愈] 警告: 计划任务创建失败, 请手动运行 ca_refresh.bat 或检查权限' -ForegroundColor Yellow
  }
} catch {
  Write-Host ('[CA自愈] 警告: ' + $_.Exception.Message) -ForegroundColor Yellow
}

# 5) exe 版托盘 + fail-open 在线监测 (2026-11-14 正式交付)
#    本文件只用于「本机手工重跑 / 管理员补 HKLM 吊销 + 本机级 CA」。
#    正式安装入口是 格一代理.exe(双击或 /install), 它用原生代码完成安装并注册卸载项。
#    本脚本绝不拉起 PowerShell 版托盘, 避免与 exe 托盘双实例。
try {
  foreach ($f in @('proxy_mode.ps1','proxy_tray_guard.ps1','proxy_tray_guard.vbs')) {
    Copy-Item (Join-Path $ScriptRoot $f) (Join-Path $InstallDir $f) -Force
  }
  $modeFile = Join-Path $InstallDir 'proxy_mode.txt'
  if (-not (Test-Path $modeFile)) { [IO.File]::WriteAllText($modeFile, 'Auto', [Text.Encoding]::ASCII) }

  $ws2 = Join-Path $env:WINDIR 'System32\wscript.exe'
  if (-not (Test-Path $ws2)) { $ws2 = 'wscript.exe' }
  $guardVbs = Join-Path $InstallDir 'proxy_tray_guard.vbs'
  $appExe   = Join-Path $InstallDir '格一代理.exe'

  # 用户级启动项直接指向 exe 托盘(GUI 子系统, 不分配控制台)
  $runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
  if (Test-Path $appExe) {
    $runVal = '"' + $appExe + '" /tray'
    New-ItemProperty -Path $runKey -Name 'ProxyClientTray' -Value $runVal -PropertyType String -Force | Out-Null
    Write-Host '[托盘] 已注册用户级启动项 ProxyClientTray -> 格一代理.exe /tray'
  } else {
    Write-Host '[托盘] 警告: 未找到 格一代理.exe, 请先双击运行 exe 完成安装' -ForegroundColor Yellow
  }

  # PT1M 保活 + fail-open 兜底任务, 仍用 GUI 子系统宿主 => 零 CMD 黑框 / 零 PS 蓝框
  $gCreated = $false
  try {
    $gAct = New-ScheduledTaskAction -Execute $ws2 -Argument ('//B //Nologo "' + $guardVbs + '"')
    $gTrg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $gSet = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $gLvl = 'Limited'
    if (Is-Admin) { $gLvl = 'Highest' }
    Register-ScheduledTask -TaskName 'ProxyClient_TrayGuard' -Action $gAct -Trigger $gTrg -Settings $gSet -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel $gLvl -Force -ErrorAction Stop | Out-Null
    $gCreated = $true
  } catch { }
  if (-not $gCreated) {
    $gVal = '\"' + $ws2 + '\" //B //Nologo \"' + $guardVbs + '\"'
    & cmd.exe /c ('schtasks /Create /TN "ProxyClient_TrayGuard" /TR "' + $gVal + '" /SC MINUTE /MO 1 /F') >$null 2>&1
    $gCreated = ($LASTEXITCODE -eq 0)
  }
  Write-Host ('[托盘] 保活任务 ProxyClient_TrayGuard = ' + $(if($gCreated){'已安装(每1分钟)'}else{'创建失败, 请检查任务计划程序权限'}))

  # 安装即按网关实况决策一次(在家里重跑不会把代理强开成断网态)
  . (Join-Path $InstallDir 'proxy_mode.ps1')
  Set-ProxyMode 'Auto' 'setup'
  Write-Host ('[托盘] 初始模式=Auto  代理=' + $(if(Get-ProxyOn){'On'}else{'Off'}) + '  网关=' + $(if(Test-Gateway){'Reachable'}else{'Unreachable'}))

  if (Test-Path $appExe) {
    Start-Process -FilePath $appExe -ArgumentList '/tray' -WindowStyle Hidden | Out-Null
    Write-Host '[托盘] 已启动 格一代理.exe 任务栏图标(绿=199生效 / 红=199不可达 / 黄=直连)'
  }
} catch {
  Write-Host ('[托盘] 警告: ' + $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host '=== 完成. 请完全退出并重启浏览器, 再访问外网测试 ==='
if (-not (Is-Admin)) {
  Write-Host '提示: 本次为非管理员运行, HKLM 吊销检查未关, Chrome/curl 可能仍报证书错误。' -ForegroundColor Yellow
  Write-Host '      解决: 右键 setup.bat -> 以管理员身份运行, 重新执行一次即可。' -ForegroundColor Yellow
}
