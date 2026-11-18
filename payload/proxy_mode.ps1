# proxy_mode.ps1 - 代理配置【单点写入】核心 + 多服务器配置解析
#
# 双重用法:
#   1) 独立执行: powershell -File proxy_mode.ps1 -Mode Off -Reason "manual"
#   2) 被托盘/在线监测/CA刷新/verify dot-source: . proxy_mode.ps1 (只定义函数, 零写操作)
#
# 设计红线: 所有代理变更(开/关/例外)只能经本文件的 Set-ProxyState,
#           托盘只读状态文件、只发令, 严禁自己写注册表, 避免双写冲突。
# 多服务器: servers.conf 为唯一配置源, active_server.txt 指示当前服务器。
#           切换服务器后, 代理地址/端口/直连例外/网关探测/CA端点全部随之改变。
# 兼容: PowerShell 2.0 / Windows 7 (无 ConvertTo-Json、无 $PSScriptRoot、无 ::new)
#
param(
  [string]$Mode = '',
  [string]$Reason = ''
)

$script:PCDir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
if (-not $env:LOCALAPPDATA) { $script:PCDir = Join-Path $env:TEMP 'ProxyClient' }
$script:CUReg      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:ConfFile   = Join-Path $script:PCDir 'servers.conf'
$script:ActiveFile = Join-Path $script:PCDir 'active_server.txt'
$script:ModeFile   = Join-Path $script:PCDir 'proxy_mode.txt'
$script:StateFile  = Join-Path $script:PCDir 'proxy_state.txt'
$script:LogFile    = Join-Path $script:PCDir 'proxy_mode.log'
$script:SimFile    = Join-Path $script:PCDir 'simulate_unreachable.flag'
$script:DisableFile = Join-Path $script:PCDir 'tray_disabled.flag'
$script:DefaultBypass = '10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>;*.qq.com;*.qpic.cn;*.qlogo.cn;*.gtimg.cn;*.gtimg.com;*.wechat.com;*.weixin.com;*.tencent.com'

function Get-PCDir { return $script:PCDir }

function Write-ProxyLog([string]$msg) {
  try {
    if (-not (Test-Path $script:PCDir)) { New-Item -ItemType Directory -Path $script:PCDir -Force | Out-Null }
    [IO.File]::AppendAllText($script:LogFile, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $msg + "`r`n", [Text.Encoding]::UTF8)
  } catch { }
}

# ---------- multi-server config (single source of truth) ----------
function Read-ServerTable {
  $list = @()
  try {
    if (Test-Path $script:ConfFile) {
      $txt = [IO.File]::ReadAllText($script:ConfFile, [Text.Encoding]::UTF8)
      foreach ($l in ($txt -split "`r?`n")) {
        $line = $l.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $f = $line.Split('|')
        if ($f.Count -lt 10) { continue }
        $port = 0
        try { $port = [int]$f[3] } catch { $port = 0 }
        if ($port -le 0 -or $port -gt 65535) { continue }
        if ($f[2] -eq '' -or $f[0] -eq '') { continue }
        $mode = $f[4]
        if ($mode -notmatch '^(signed|static|none)$') { $mode = 'signed' }
        $list += @{
          ID = $f[0]; Name = $f[1]; Host = $f[2]; Port = $port; CaMode = $mode
          CaUrl = $f[5]; CaCert = $f[6]; PubKey = $f[7]
          Bypass = $f[8]; Enabled = $f[9]
        }
      }
    }
  } catch { }
  if (@($list).Count -eq 0) {
    $list += @{
      ID = '199'; Name = '主代理 10.0.50.199'; Host = '10.0.50.199'; Port = 15888
      CaMode = 'signed'; CaUrl = 'http://10.0.50.199:15889/ca.txt'; CaCert = ''
      PubKey = 'ca_sign_pub.xml'; Bypass = $script:DefaultBypass; Enabled = '1'
    }
  }
  return @($list)
}

function Get-ActiveServerId {
  $id = ''
  try { if (Test-Path $script:ActiveFile) { $id = ([IO.File]::ReadAllText($script:ActiveFile, [Text.Encoding]::UTF8)).Trim() } } catch { }
  if ($id -ne '') {
    foreach ($s in @(Read-ServerTable)) { if ($s.ID -eq $id) { return $id } }
  }
  foreach ($s in @(Read-ServerTable)) { if ($s.Enabled -eq '1') { return $s.ID } }
  return @(Read-ServerTable)[0].ID
}

function Get-ServerConfig {
  $id = Get-ActiveServerId
  foreach ($s in @(Read-ServerTable)) { if ($s.ID -eq $id) { return $s } }
  return @(Read-ServerTable)[0]
}

function Get-ProxyAddress([hashtable]$srv) { return ('http://' + $srv.Host + ':' + $srv.Port) }

$script:Srv         = Get-ServerConfig
$script:ProxyServer = Get-ProxyAddress $script:Srv
$script:ProxyBypass = $script:Srv.Bypass
if ($script:ProxyBypass -eq '') { $script:ProxyBypass = $script:DefaultBypass }

# ---------- state helpers ----------
function Get-ProxyMode {
  try {
    if (Test-Path $script:ModeFile) {
      $m = ([IO.File]::ReadAllText($script:ModeFile)).Trim()
      if ($m -match '^(Auto|On|Off)$') { return $m }
    }
  } catch { }
  return 'Auto'
}

# "proxy is ON and points at the CURRENT server with the CURRENT bypass list".
# Switching servers makes this false even while ProxyEnable is still 1, which
# forces Set-ProxyState($true) to rewrite all three values for the new gateway.
function Get-ProxyOn {
  $p = Get-ItemProperty $script:CUReg -ErrorAction SilentlyContinue
  if ($null -eq $p -or $p.ProxyEnable -ne 1) { return $false }
  if ($p.ProxyServer -ne $script:ProxyServer) { return $false }
  if ($p.ProxyOverride -ne $script:ProxyBypass) { return $false }
  return $true
}

# Used only by the OFF branch: ProxyEnable=1 with a mismatched server must still
# be cleared, otherwise a failed switch could leave a dead proxy configured.
function Get-ProxyEnabled {
  $p = Get-ItemProperty $script:CUReg -ErrorAction SilentlyContinue
  return ($null -ne $p -and $p.ProxyEnable -eq 1)
}

# 网关可达性探测, 目标随当前服务器变化。simulate_unreachable.flag 仅供金丝雀演练。
function Test-Gateway {
  if (Test-Path $script:SimFile) { return $false }
  try {
    $c   = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect($script:Srv.Host, $script:Srv.Port, $null, $null)
    $ok  = $iar.AsyncWaitHandle.WaitOne(1000, $false)
    if ($ok -and $c.Connected) { $c.Close(); return $true }
    $c.Close(); return $false
  } catch { return $false }
}

function Refresh-WinInet {
  try {
    if (-not ('PC.WIProxy' -as [type])) {
      $sig = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
      Add-Type -MemberDefinition $sig -Name WIProxy -Namespace PC -ErrorAction Stop | Out-Null
    }
    $t = [PC.WIProxy]
    $t::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    $t::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
  } catch { }
}

# 唯一允许改代理配置的地方。幂等: 状态已一致则直接返回 $false, 不刷注册表/不写日志。
function Set-ProxyState([bool]$On, [string]$Reason = '') {
  try {
    if ($On) {
      if (Get-ProxyOn) { return $false }
      Set-ItemProperty -Path $script:CUReg -Name ProxyEnable  -Value 1 -Force
      Set-ItemProperty -Path $script:CUReg -Name ProxyServer  -Value $script:ProxyServer -Force
      Set-ItemProperty -Path $script:CUReg -Name ProxyOverride -Value $script:ProxyBypass -Force
      Remove-ItemProperty -Path $script:CUReg -Name AutoConfigURL -ErrorAction SilentlyContinue
    } else {
      $p = Get-ItemProperty $script:CUReg -ErrorAction SilentlyContinue
      $dirty = ($null -ne $p -and ($p.ProxyEnable -eq 1 -or $p.ProxyServer -or $p.ProxyOverride -or $p.AutoConfigURL))
      if (-not $dirty) { return $false }
      Set-ItemProperty -Path $script:CUReg -Name ProxyEnable -Value 0 -Force
      Remove-ItemProperty -Path $script:CUReg -Name ProxyServer     -ErrorAction SilentlyContinue
      Remove-ItemProperty -Path $script:CUReg -Name ProxyOverride   -ErrorAction SilentlyContinue
      Remove-ItemProperty -Path $script:CUReg -Name AutoConfigURL   -ErrorAction SilentlyContinue
      foreach ($n in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy')) {
        try { [Environment]::SetEnvironmentVariable($n, $null, 'User') } catch { }
      }
    }
    Refresh-WinInet
    Write-ProxyLog ('SET ' + $(if($On){'ON'}else{'OFF'}) + '  server=' + $script:Srv.ID + '  addr=' + $script:ProxyServer + '  reason=' + $Reason)
    return $true
  } catch {
    Write-ProxyLog ('SET FAILED ' + $_.Exception.Message)
    return $false
  }
}

# 菜单/命令行入口: 持久化模式并立即应用一次
function Set-ProxyMode([string]$Mode, [string]$Reason = '') {
  if ($Mode -notmatch '^(Auto|On|Off)$') { return }
  try { [IO.File]::WriteAllText($script:ModeFile, $Mode, [Text.Encoding]::ASCII) } catch { }
  if ($Mode -eq 'On') {
    [void](Set-ProxyState $true $Reason)
  } elseif ($Mode -eq 'Off') {
    [void](Set-ProxyState $false $Reason)
  } else {
    $reach = Test-Gateway
    [void](Set-ProxyState $reach ('Auto/' + $Reason))
  }
  Write-ProxyLog ('MODE=' + $Mode + '  ' + $Reason)
  $r2 = Test-Gateway
  $o2 = Get-ProxyOn
  $c2 = 'yellow'
  if ($o2 -and $r2) { $c2 = 'green' } elseif ($o2 -and -not $r2) { $c2 = 'red' }
  Write-ProxyState $Mode $o2 $r2 $c2 ('mode/' + $Reason) 0
}

function Write-ProxyState([string]$mode,[bool]$proxyOn,[bool]$reach,[string]$color,[string]$reason,[int]$failStreak) {
  try {
    $s = 'MODE=' + $mode + "`r`n" +
         'PROXY=' + $(if($proxyOn){'On'}else{'Off'}) + "`r`n" +
         'GATEWAY=' + $(if($reach){'Reachable'}else{'Unreachable'}) + "`r`n" +
         'COLOR=' + $color + "`r`n" +
         'SERVER=' + $script:Srv.ID + '|' + $script:Srv.Name + "`r`n" +
         'REASON=' + $reason + "`r`n" +
         'FAILSTREAK=' + $failStreak + "`r`n" +
         'TS=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n"
    [IO.File]::WriteAllText($script:StateFile, $s, (New-Object System.Text.UTF8Encoding($true)))
  } catch { }
}

function Read-ProxyState {
  $h = @{}
  try {
    foreach ($l in ([IO.File]::ReadAllText($script:StateFile) -split "`r?`n")) {
      if ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] }
    }
  } catch { }
  return $h
}

# 只有独立执行(带 -Mode)时才动作; dot-source 时 $Mode='' 仅定义函数, 零副作用。
if ($Mode -ne '') { Set-ProxyMode -Mode $Mode -Reason $Reason }
