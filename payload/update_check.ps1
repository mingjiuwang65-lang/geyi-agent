# update_check.ps1 - 版本清单检查 / 下载 / 校验 / 灰度放行
# Called by ProxyClient_TrayGuard (throttled to CHECK_INTERVAL_MIN, default 60min),
# by the tray menu "检查更新" (-Force), and by manual approval (-Approve).
#
# Rollout safety (canary-first rule, hard-coded, cannot be bypassed by the manifest):
#   PHASE=canary  -> only COMPUTERNAME listed in CANARY_HOSTS may auto-install
#   PHASE=all     -> every host may auto-install
#   PHASE=hold    -> nobody installs, notify only
#   AUTO_UPDATE=0 -> nobody auto-installs; a human must click "安装更新" (-Approve)
# The manifest MUST carry SHA256 + SIZE. A mismatch deletes the download and
# refuses the upgrade. User configuration (servers.conf, active_server.txt,
# per-server keys/certs, update.conf) is NEVER overwritten by an upgrade.
#
# Compatibility: Windows 7 / PowerShell 2.0. No ConvertFrom-Json, no Invoke-WebRequest.

param([switch]$Force, [switch]$Approve)

$ErrorActionPreference = 'Continue'
$dir = Join-Path $env:LOCALAPPDATA 'ProxyClient'
if (-not $env:LOCALAPPDATA) { $dir = Join-Path $env:TEMP 'ProxyClient' }
$confPath   = Join-Path $dir 'update.conf'
$verPath    = Join-Path $dir 'app_version.txt'
$statePath  = Join-Path $dir 'update_state.txt'
$stampPath  = Join-Path $dir 'update_last_check.txt'
$pending    = Join-Path $dir 'pending_update.flag'
$logPath    = Join-Path $dir 'update.log'
$dlDir      = Join-Path $dir 'downloads'

function ULog([string]$m) {
  try {
    $m = $m -replace '[^\x20-\x7E]','?'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::AppendAllText($logPath, (Get-Date -Format s) + ' ' + $m + "`r`n", [Text.Encoding]::ASCII)
  } catch { }
}

function Read-KV([string]$path) {
  $h = @{}
  try {
    if (-not (Test-Path $path)) { return $h }
    foreach ($l in ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) -split "`r?`n")) {
      $line = $l.Trim()
      if ($line -eq '' -or $line.StartsWith('#')) { continue }
      $i = $line.IndexOf('=')
      if ($i -gt 0) { $h[$line.Substring(0,$i).Trim()] = $line.Substring($i+1).Trim() }
    }
  } catch { }
  return $h
}

function Write-State([hashtable]$h) {
  try {
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in @('STATUS','CUR_VER','CUR_BUILD','NEW_VER','NEW_BUILD','PHASE','ALLOWED','NOTE','TS','ERROR')) {
      if ($h.ContainsKey($k)) { [void]$sb.AppendLine($k + '=' + $h[$k]) }
    }
    [IO.File]::WriteAllText($statePath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
  } catch { }
}

function Compare-Ver([string]$a, [string]$b) {
  $pa = $a.Split('.'); $pb = $b.Split('.')
  $n = [Math]::Max($pa.Count, $pb.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $va = 0; $vb = 0
    if ($i -lt $pa.Count) { try { $va = [int]$pa[$i] } catch { $va = 0 } }
    if ($i -lt $pb.Count) { try { $vb = [int]$pb[$i] } catch { $vb = 0 } }
    if ($va -gt $vb) { return 1 }
    if ($va -lt $vb) { return -1 }
  }
  return 0
}

function Is-Newer([string]$nv,[string]$nb,[string]$cv,[string]$cb) {
  $c = Compare-Ver $nv $cv
  if ($c -gt 0) { return $true }
  if ($c -lt 0) { return $false }
  return ([string]::Compare($nb, $cb, $true) -gt 0)
}

function Fetch-Text([string]$u) {
  if ($u -match '^https?://') {
    $req = [Net.HttpWebRequest]::Create($u)
    $req.Proxy = $null; $req.Timeout = 8000; $req.ReadWriteTimeout = 8000
    $req.UserAgent = 'GeYiProxy-Updater/2'
    $res = $req.GetResponse()
    try {
      $sr = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
      return $sr.ReadToEnd()
    } finally { $res.Close() }
  }
  return [IO.File]::ReadAllText($u, [Text.Encoding]::UTF8)
}

function Fetch-File([string]$u, [string]$dst) {
  if ($u -match '^https?://') {
    $req = [Net.HttpWebRequest]::Create($u)
    $req.Proxy = $null; $req.Timeout = 20000; $req.ReadWriteTimeout = 20000
    $req.UserAgent = 'GeYiProxy-Updater/2'
    $res = $req.GetResponse()
    $st = $res.GetResponseStream()
    $fs = [IO.File]::Create($dst)
    try {
      $buf = New-Object byte[] 65536
      $n = $st.Read($buf, 0, $buf.Length)
      while ($n -gt 0) { $fs.Write($buf, 0, $n); $n = $st.Read($buf, 0, $buf.Length) }
    } finally { $fs.Close(); $st.Close(); $res.Close() }
  } else {
    Copy-Item -Path $u -Destination $dst -Force
  }
}

function Resolve-Url([string]$manifestUrl, [string]$raw) {
  if ($raw -match '^(https?://|\\\\)' -or $raw -match '^[A-Za-z]:\\') { return $raw }
  $raw = $raw.Replace('/', '\')
  if ($manifestUrl -match '^https?://') {
    $base = $manifestUrl.Substring(0, $manifestUrl.LastIndexOf('/') + 1)
    return ($base + $raw.Replace('\', '/'))
  }
  return (Join-Path (Split-Path -Parent $manifestUrl) $raw)
}

function Get-Sha256([string]$p) {
  $sha = New-Object System.Security.Cryptography.SHA256Managed
  try {
    $b = $sha.ComputeHash([IO.File]::ReadAllBytes($p))
    return (($b | ForEach-Object { $_.ToString('X2') }) -join '')
  } finally { $sha.Dispose() }
}

$st = Read-KV $verPath
$curVer = $st['VER']; if (-not $curVer) { $curVer = '0.0.0' }
$curBuild = $st['BUILD']; if (-not $curBuild) { $curBuild = '0' }
$cfg = Read-KV $confPath
$manifestUrl = $cfg['UPDATE_URL']
if (-not $manifestUrl) { $manifestUrl = 'http://10.0.50.199:15889/geyi/update.manifest' }
$auto = ($cfg['AUTO_UPDATE'] -ne '0')
$interval = 60
try { $interval = [int]$cfg['CHECK_INTERVAL_MIN'] } catch { }
if ($interval -lt 1) { $interval = 60 }

$state = @{
  STATUS='idle'; CUR_VER=$curVer; CUR_BUILD=$curBuild; NEW_VER=''; NEW_BUILD=''
  PHASE=''; ALLOWED='0'; NOTE=''; TS=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); ERROR=''
}

# throttle (Guard runs every minute; we only hit the manifest once per interval)
if (-not $Force -and -not $Approve -and (Test-Path $stampPath)) {
  try {
    $last = [DateTime]::ParseExact(([IO.File]::ReadAllText($stampPath)).Trim(), 'yyyy-MM-dd HH:mm:ss', $null)
    if (((Get-Date) - $last).TotalMinutes -lt $interval) { Write-Output 'SKIP throttled'; exit 0 }
  } catch { }
}
try { [IO.File]::WriteAllText($stampPath, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [Text.Encoding]::ASCII) } catch { }

try {
  $mtext = Fetch-Text $manifestUrl
  $m = @{}
  foreach ($l in ($mtext -split "`r?`n")) {
    $line = $l.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $i = $line.IndexOf('=')
    if ($i -gt 0) { $m[$line.Substring(0,$i).Trim()] = $line.Substring($i+1).Trim() }
  }
  $nv = $m['VER']; $nb = $m['BUILD']; $url = $m['URL']
  $hash = $m['SHA256']; $size = [string]$m['SIZE']
  $phase = $m['PHASE']; if (-not $phase) { $phase = 'canary' }
  $canary = [string]$m['CANARY_HOSTS']
  $state['NEW_VER'] = $nv; $state['NEW_BUILD'] = $nb
  $state['PHASE'] = $phase; $state['NOTE'] = [string]$m['NOTE']

  if (-not $nv -or -not $url -or -not $hash -or -not $size) {
    $state['STATUS'] = 'bad-manifest'; $state['ERROR'] = 'VER/URL/SHA256/SIZE required'
    ULog ('BAD_MANIFEST ' + $manifestUrl)
    Write-State $state; Write-Output $state['STATUS']; exit 0
  }
  if (-not (Is-Newer $nv $nb $curVer $curBuild)) {
    $state['STATUS'] = 'up-to-date'
    ULog ('UP_TO_DATE ' + $curVer + '/' + $curBuild)
    Write-State $state; Write-Output $state['STATUS']; exit 0
  }

  $exeUrl = Resolve-Url $manifestUrl $url
  if (-not (Test-Path $dlDir)) { New-Item -ItemType Directory -Path $dlDir -Force | Out-Null }
  $safe = ($nv + '_' + $nb) -replace '[^A-Za-z0-9_.-]','_'
  $dst = Join-Path $dlDir ('geyi_' + $safe + '.exe')
  ULog ('DOWNLOAD ' + $exeUrl)
  Fetch-File $exeUrl $dst

  $realHash = Get-Sha256 $dst
  $realSize = ([IO.FileInfo]$dst).Length
  if ($realHash -ne $hash.ToUpperInvariant() -or [string]$realSize -ne $size) {
    try { Remove-Item $dst -Force } catch { }
    $state['STATUS'] = 'hash-mismatch'
    $state['ERROR'] = ('got ' + $realHash + '/' + $realSize + ' want ' + $hash + '/' + $size)
    ULog ('HASH_MISMATCH ' + $state['ERROR'])
    Write-State $state; Write-Output $state['STATUS']; exit 0
  }

  $machine = [string]$env:COMPUTERNAME
  $inCanary = $false
  foreach ($h in $canary.Split(',')) { if ($h.Trim() -ne '' -and $h.Trim() -eq $machine) { $inCanary = $true } }
  $allowed = $false
  if ($phase -eq 'all') { $allowed = $true }
  elseif ($phase -eq 'canary' -and $inCanary) { $allowed = $true }
  if ($Approve) { $allowed = $true }
  $state['ALLOWED'] = $(if($allowed){'1'}else{'0'})

  if ($phase -eq 'hold') {
    $state['STATUS'] = 'hold'; ULog 'PHASE=hold'; Write-State $state; Write-Output 'hold'; exit 0
  }
  if ($allowed -and $auto) {
    $pf = 'VER=' + $nv + "`r`n" +
          'BUILD=' + $nb + "`r`n" +
          'PATH=' + $dst + "`r`n" +
          'SHA256=' + $realHash + "`r`n" +
          'SIZE=' + $realSize + "`r`n" +
          'NOTE=' + [string]$m['NOTE'] + "`r`n" +
          'APPROVED=' + $(if($Approve){'manual'}else{'auto'}) + "`r`n" +
          'TS=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n"
    [IO.File]::WriteAllText($pending, $pf, (New-Object System.Text.UTF8Encoding($true)))
    $state['STATUS'] = 'pending-install'
    ULog ('PENDING_INSTALL ' + $nv + '/' + $nb + ' host=' + $machine + ' phase=' + $phase)
  } else {
    $state['STATUS'] = 'pending-approval'
    $state['ERROR'] = ('host=' + $machine + ' phase=' + $phase + ' auto=' + $auto + ' canary=' + $inCanary)
    ULog ('PENDING_APPROVAL ' + $state['ERROR'])
  }
  Write-State $state
  Write-Output $state['STATUS']
} catch {
  $state['STATUS'] = 'unreachable'
  $state['ERROR'] = $_.Exception.Message
  ULog ('ERROR ' + $state['ERROR'])
  Write-State $state
  Write-Output 'unreachable'
}
