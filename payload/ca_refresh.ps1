# ca_refresh.ps1 - 跟随【当前服务器】的 MITM CA 轮换 / 切换
# Runs every 1 minute as scheduled task "ProxyClient_CARefresh".
# Installed to %LOCALAPPDATA%\ProxyClient\ together with servers.conf and per-server keys.
#
# Multi-server: the active server comes from servers.conf + active_server.txt
# (parsed by proxy_mode.ps1, the single config reader). Each server owns its own
# CA trust chain:
#   signed : fetch <caUrl> over plain intranet HTTP, verify RSA-SHA256 with that
#            server's <pubKey> XML, then import. EXACTLY the 199 behaviour.
#   static : import a local DER <caCert>, no signed endpoint (self-signed + not
#            expired is still enforced).
#   none   : this gateway does not intercept TLS, no CA needed.
# On a server switch, stale same-subject CAs from the previous gateway are
# removed best-effort, so the machine trusts only the active gateway's CA.
#
# SECURITY: signed payloads are RSA-SHA256 signed by the gateway's private key
# (never shipped to clients). Unsigned/tampered/stale/non-self-signed/wrong-subject
# responses are rejected. A hijacked HTTP endpoint cannot inject a rogue CA.
#
# Compatibility: Windows 7 / PowerShell 2.0 onward. No ConvertFrom-Json, no
# $PSScriptRoot, no -NoProxy, no Get-Content -Raw. Log kept pure ASCII.

param([switch]$CheckOnly)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogDir    = Join-Path $env:LOCALAPPDATA 'ProxyClient'
if (-not $env:LOCALAPPDATA) { $LogDir = $env:TEMP }
$LogPath   = Join-Path $LogDir 'ca_refresh.log'

# Reuse the one and only config parser (dot-source defines functions only; $Mode='').
. (Join-Path $ScriptDir 'proxy_mode.ps1')
$Srv = Get-ServerConfig

function Write-Log([string]$m){
  try {
    $m = $m -replace '[^\x20-\x7E]','?'
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Add-Content $LogPath ((Get-Date -Format s) + ' ' + $m) -Encoding ASCII
  } catch {}
}

# Explicitly bypass the system proxy: the CA endpoint is intranet, and a
# mis-set ProxyOverride must never break CA refresh.
function Fetch-Text([string]$u){
  $req = [Net.HttpWebRequest]::Create($u)
  $req.Proxy = $null
  $req.Timeout = 8000
  $req.ReadWriteTimeout = 8000
  $req.UserAgent = 'ProxyClient-CARefresh/2'
  $res = $req.GetResponse()
  try {
    $st = $res.GetResponseStream()
    $sr = New-Object IO.StreamReader($st, [Text.Encoding]::ASCII)
    return $sr.ReadToEnd()
  } finally { $res.Close() }
}

function Get-InstalledCa(){
  $out = @()
  foreach ($scope in @('CurrentUser','LocalMachine')) {
    try {
      $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', $scope)
      $st.Open('ReadOnly')
      foreach ($x in $st.Certificates) {
        if ($x.Subject -match 'mitmproxy') { $out += [string]$x.Thumbprint }
      }
      $st.Close()
    } catch {}
  }
  return @($out | Select-Object -Unique)
}

function Is-Admin(){
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Test-CertSanity([byte[]]$der, [string]$expectThumb, [bool]$requireMitm) {
  $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
  $c.Import($der)
  if ($expectThumb -ne '' -and $c.Thumbprint -ne $expectThumb) { throw 'THUMB_MISMATCH' }
  if ($c.Subject -ne $c.Issuer) { throw 'NOT_SELF_SIGNED' }
  if ($requireMitm -and $c.Subject -notmatch 'mitmproxy') { throw 'UNEXPECTED_SUBJECT' }
  if ([DateTime]::UtcNow -gt $c.NotAfter.ToUniversalTime()) { throw 'CA_EXPIRED' }
  return $c
}

try {
  Write-Log ('SERVER=' + $Srv.ID + ' MODE=' + $Srv.CaMode)
  if ($Srv.CaMode -eq 'none') {
    if ($CheckOnly) { Write-Host 'CA_NONE: active server does not intercept TLS' }
    Write-Log 'OK CA_NONE (no MITM for this server)'
    exit 0
  }

  $der = $null
  $thumb = ''

  if ($Srv.CaMode -eq 'static') {
    if ($Srv.CaCert -eq '') { Write-Log 'FATAL static mode needs caCert'; exit 2 }
    $certPath = Join-Path $ScriptDir $Srv.CaCert
    if (-not (Test-Path $certPath)) { Write-Log ('FATAL missing cert: ' + $Srv.CaCert); exit 2 }
    $der = [IO.File]::ReadAllBytes($certPath)
    $c = Test-CertSanity $der '' $false
    $thumb = $c.Thumbprint
    Write-Log ('STATIC_CERT=' + $Srv.CaCert + ' THUMB=' + $thumb)
  } else {
    $DistUrl = $Srv.CaUrl
    if ($DistUrl -eq '') { Write-Log 'FATAL missing caUrl'; exit 2 }

    # ---- Dynamic business public key (root-signed rotation chain) ----
    # The client pins ONLY the offline root public key (ca_root_pub.xml).
    # Per-node business public keys + root signatures are fetched from the
    # gateway's /bpub endpoint, verified, then used to verify the CA. This lets
    # a gateway rotate its signing key or CA at any time with no client update.
    # Fallback: if /bpub is unavailable (old gateway), use the local <pubKey>.
    $pubXml = ''
    $rootPath = Join-Path $ScriptDir 'ca_root_pub.xml'
    $bpubUrl  = $DistUrl -replace 'ca\.txt$', 'bpub'
    try {
      if (-not (Test-Path $rootPath)) { throw 'ROOT_PUB_MISSING' }
      $btxt = Fetch-Text $bpubUrl
      $bkv = @{}
      foreach ($l in ($btxt -split "`r?`n")) {
        if ($l -match '^([A-Z_]+)=(.*)$') { $bkv[$Matches[1]] = $Matches[2] }
      }
      if ($bkv['VER'] -ne '1' -or -not $bkv['PUB'] -or -not $bkv['BP_SIG']) { throw 'MALFORMED_BPUB' }
      $pubBytes = [Convert]::FromBase64String($bkv['PUB'])
      $pubXml   = [Text.Encoding]::UTF8.GetString($pubBytes)
      $rootRsa  = New-Object System.Security.Cryptography.RSACryptoServiceProvider
      $rootRsa.FromXmlString([IO.File]::ReadAllText($rootPath))
      $bpSig = [Convert]::FromBase64String($bkv['BP_SIG'])
      if (-not $rootRsa.VerifyData($pubBytes, 'SHA256', $bpSig)) { throw 'BPUB_SIGNATURE_INVALID' }
      Write-Log 'OK dynamic business pubkey verified by root'
    } catch {
      Write-Log ('WARN bpub unavailable (' + $_.Exception.Message + '), falling back to local pubkey')
      $PubPath = Join-Path $ScriptDir $Srv.PubKey
      if (-not (Test-Path $PubPath)) { Write-Log 'FATAL no usable public key'; exit 2 }
      $pubXml = [IO.File]::ReadAllText($PubPath)
    }

    $txt = Fetch-Text $DistUrl
    $kv = @{}
    foreach ($l in ($txt -split "`r?`n")) {
      if ($l -match '^([A-Z]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
    }
    if ($kv['VER'] -ne '1' -or -not $kv['THUMB'] -or -not $kv['TS'] -or -not $kv['CA'] -or -not $kv['SIG']) {
      Write-Log 'FATAL malformed /ca.txt'; exit 2
    }

    # 1) RSA-SHA256 signature over exactly the same string built on the gateway,
    #    verified with the (root-verified) business public key.
    $payload = 'VER=1|THUMB=' + $kv['THUMB'] + '|TS=' + $kv['TS'] + '|CA=' + $kv['CA']
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($pubXml)
    $sigBytes = [Convert]::FromBase64String($kv['SIG'])
    if (-not $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes($payload), 'SHA256', $sigBytes)) {
      Write-Log 'FATAL SIGNATURE_INVALID - refusing to install CA'; exit 3
    }

    # 2) freshness (loose window tolerates clock skew, still rejects ancient replays)
    $ts = [DateTime]::Parse($kv['TS'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    if ([Math]::Abs(([DateTime]::UtcNow - $ts).TotalHours) -gt 48) { Write-Log 'FATAL STALE_TIMESTAMP'; exit 3 }

    # 3) DER / self-signed / expected subject / not expired / thumb matches
    $der = [Convert]::FromBase64String($kv['CA'])
    $c = Test-CertSanity $der $kv['THUMB'] $true
    $thumb = $c.Thumbprint
  }

  # 4) Compare + state dedupe.
  # Proven on 2026-11-14: with BOTH an old and the new same-subject CA installed,
  # Windows chain engine picks the key that actually verifies. So the client is
  # healthy as soon as the CURRENT CA is present; removing stale same-name CAs is
  # best-effort (LocalMachine needs elevation) and must NOT gate success.
  $installed  = @(Get-InstalledCa)
  $hasCurrent = ($installed -contains $thumb)
  $statePath  = Join-Path $LogDir 'ca_state.txt'
  $stateKey   = $Srv.ID + '|' + $thumb + '|' + (($installed | Sort-Object) -join ',')
  $prev = ''
  if (Test-Path $statePath) { $prev = ([IO.File]::ReadAllText($statePath)).Trim() }

  if ($hasCurrent -and $prev -eq $stateKey) {
    if ($CheckOnly) { Write-Host ('OK current CA already installed: ' + $thumb) }
    exit 0
  }
  $msg = 'CA SYNC server=' + $Srv.ID + ' installed=[' + ($installed -join ',') + '] gateway=' + $thumb + ' hasCurrent=' + $hasCurrent
  Write-Log $msg
  if ($CheckOnly) { Write-Host ('WOULD_UPDATE ' + $msg); exit 0 }

  # 5) CA retention policy (1.3.0, changed for random rotation).
  #
  # OLD policy: delete every other mitmproxy CA, keep only the active node's.
  # That breaks random rotation: switching 199 -> 195 -> 199 would delete and
  # re-import a CA on every hop, so TLS dies for a few seconds each time and
  # the browser shows ERR_CERT_AUTHORITY_INVALID.
  #
  # NEW policy: KEEP every node CA that we have already verified and installed.
  # We only ever ADD a CA after it passed the root-signed /bpub chain and the
  # business-key signature check, so the trust store stays a set of legitimately
  # issued node CAs. Nothing is removed on a normal run.
  #
  # The trust store therefore contains one CA per distinct gateway CA:
  #   33EACD89... (195)  CF499E45... (196)  58FE1A55... (197/198/199)
  # All three are root-signed, so the client can rotate without any TLS gap.
  #
  # Only the bootstrap path (no CA installed at all) triggers a cleanup of
  # unknown mitmproxy CAs that were NOT issued by our node set.
  if ($installed.Count -eq 0) {
    Write-Log 'BOOTSTRAP: no mitmproxy CA present, importing first one'
  } else {
    Write-Log ('KEEP policy: retaining ' + $installed.Count + ' node CA(s): ' + ($installed -join ','))
  }

  # 6) import the current CA if missing (CurrentUser always; LocalMachine when elevated)
  if (-not $hasCurrent) {
    $tmp = Join-Path $env:TEMP 'proxyclient_ca_new.cer'
    [IO.File]::WriteAllBytes($tmp, $der)
    & certutil -addstore -f -user Root $tmp 2>&1 | Out-Null
    if (Is-Admin) { & certutil -addstore -f Root $tmp 2>&1 | Out-Null }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }

  # 7) post-check: SUCCESS = "current CA usable". Other node CAs are kept on
  # purpose (rotation must not create a TLS gap).
  $after       = @(Get-InstalledCa)
  $afterHas    = ($after -contains $thumb)
  $others      = @($after | Where-Object { $_ -ne $thumb })
  if ($afterHas) {
    Write-Log ('OK current CA usable: ' + $thumb + ' ; other node CAs kept=' + $others.Count)
    [IO.File]::WriteAllText($statePath, $Srv.ID + '|' + $thumb + '|' + (($after | Sort-Object) -join ','))
  } else {
    Write-Log ('FATAL current CA NOT installed after import attempt')
  }

  # 8) nudge WinINET so new TLS connections pick up the new trust root
  try {
    Add-Type -Namespace ProxyClient -Name WinInet -MemberDefinition '[DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);' -ErrorAction Stop
    [ProxyClient.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [ProxyClient.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    Write-Log 'OK WinINET settings refreshed'
  } catch { Write-Log 'WARN WinINET refresh unavailable (browser restart may be needed)' }

  # 9) PRE-INSTALL every other node's CA (1.3.0).
  # Random rotation moves between nodes that have DIFFERENT MITM CAs
  # (195/196 own theirs, 197/198/199 share one). If only the active node's CA
  # is trusted, every rotation hop causes a TLS failure until the CA refresh
  # catches up. Pre-installing all node CAs makes rotation seamless.
  # Each CA still goes through the full root-signed verification chain, so no
  # unverified CA ever enters the trust store.
  try {
    $servers = Read-ServerTable
    foreach ($sv in $servers) {
      if ($sv.CaMode -ne 'signed' -or $sv.CaUrl -eq '') { continue }
      if ($sv.ID -eq $Srv.ID) { continue }
      $u = $sv.CaUrl
      $bu = $u -replace 'ca\.txt$', 'bpub'
      try {
        $bt = Fetch-Text $bu
        $bk = @{}
        foreach ($l in ($bt -split "`r?`n")) { if ($l -match '^([A-Z_]+)=(.*)$') { $bk[$Matches[1]] = $Matches[2] } }
        if ($bk['VER'] -ne '1' -or -not $bk['PUB'] -or -not $bk['BP_SIG']) { continue }
        $pb = [Convert]::FromBase64String($bk['PUB'])
        $rr = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rr.FromXmlString([IO.File]::ReadAllText($rootPath))
        if (-not $rr.VerifyData($pb, 'SHA256', [Convert]::FromBase64String($bk['BP_SIG']))) { continue }
        $px = [Text.Encoding]::UTF8.GetString($pb)

        $ct = Fetch-Text $u
        $ck = @{}
        foreach ($l in ($ct -split "`r?`n")) { if ($l -match '^([A-Z]+)=(.*)$') { $ck[$Matches[1]] = $Matches[2] } }
        if ($ck['VER'] -ne '1' -or -not $ck['THUMB'] -or -not $ck['CA'] -or -not $ck['SIG']) { continue }
        $pl = 'VER=1|THUMB=' + $ck['THUMB'] + '|TS=' + $ck['TS'] + '|CA=' + $ck['CA']
        $rr2 = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rr2.FromXmlString($px)
        if (-not $rr2.VerifyData([Text.Encoding]::UTF8.GetBytes($pl), 'SHA256', [Convert]::FromBase64String($ck['SIG']))) { continue }
        $ts2 = [DateTime]::Parse($ck['TS'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        if ([Math]::Abs(([DateTime]::UtcNow - $ts2).TotalHours) -gt 48) { continue }

        $d2 = [Convert]::FromBase64String($ck['CA'])
        $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $c2.Import($d2)
        if ($c2.Subject -ne $c2.Issuer) { continue }
        if ($c2.Subject -notmatch 'mitmproxy') { continue }
        if ([DateTime]::UtcNow -gt $c2.NotAfter.ToUniversalTime()) { continue }

        $have = @(Get-InstalledCa)
        if ($have -notcontains $c2.Thumbprint) {
          $tp = Join-Path $env:TEMP ('proxyclient_ca_' + $sv.ID + '.cer')
          [IO.File]::WriteAllBytes($tp, $d2)
          & certutil -addstore -f -user Root $tp 2>&1 | Out-Null
          if (Is-Admin) { & certutil -addstore -f Root $tp 2>&1 | Out-Null }
          Remove-Item $tp -Force -ErrorAction SilentlyContinue
          Write-Log ('PRE-INSTALL node CA ' + $sv.ID + ' -> ' + $c2.Thumbprint)
        }
      } catch {
        Write-Log ('WARN pre-install ' + $sv.ID + ': ' + $_.Exception.Message)
      }
    }
  } catch {
    Write-Log ('WARN pre-install sweep: ' + $_.Exception.Message)
  }

  if ($afterHas) {
    Write-Host ('CA SYNCED -> ' + $thumb + ' (kept=' + $others.Count + ')')
    exit 0
  }
  Write-Host 'CA IMPORT FAILED'
  exit 1
} catch {
  Write-Log ('ERROR ' + $_.Exception.Message)
  if ($CheckOnly) { Write-Host ('ERROR ' + $_.Exception.Message) }
  exit 1
}
