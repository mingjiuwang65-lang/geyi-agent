#!/usr/bin/env bash
# ==============================================================================
# geYiProxy Linux Client - one-shot installer
#
# Installs the overseas proxy client on a Linux server so that
# curl / wget / apt / pip / git automatically use the overseas exit.
#
# Features:
#   - Self-verifying CA: node CA is validated through the 199 /bpub root-signed
#     chain. Only a CA that passes the full chain is installed.
#   - Multi node + random rotation: rotates between healthy nodes so a single
#     overseas exit IP is not used forever (avoids IP level blocking).
#   - Rotate only when idle: defers the switch while proxy connections are
#     active, so running downloads are never interrupted.
#   - Full rollback: uninstall.sh removes everything it created.
#
# Usage:
#   sudo ./install.sh                 # install (default rotation 30 min)
#   sudo ./install.sh --minutes 60    # install with a custom rotation interval
#   sudo ./uninstall.sh               # full uninstall / rollback
#
# Requirements: curl, openssl (or gnutls), tar, coreutils
# Supported  : Ubuntu/Debian (apt), RHEL/CentOS/Rocky (yum/dnf)
# ==============================================================================
set -uo pipefail

APP_NAME="geYiProxy"
APP_DIR="/opt/geYiProxy"
CONF_DIR="${APP_DIR}/conf"
BIN_DIR="${APP_DIR}/bin"
STATE_DIR="${APP_DIR}/state"
LOG_DIR="/var/log/geYiProxy"
CA_DIR="/usr/local/share/ca-certificates"

# Directory of pre-generated PEM public keys shipped alongside this script.
# At runtime the script resolves its own location so it works from any path.
_self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PKG_PEM_DIR="${_self_dir}"

# Distribution source (199 gateway, plain intranet HTTP)
GW_BASE="http://10.0.50.199:15889"
ROOT_PUB_PEM_URL="${GW_BASE}/ca_root_pub.pem"
ROOT_PUB_XML_URL="${GW_BASE}/ca_root_pub.xml"

# Proxy nodes
NODES=(195 196 197 198 199)
PROXY_PORT=15888
HEALTH_PORT=15889

ROTATE_MINUTES=30
SERVICE_NAME="geyiproxy-rotate"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"
PROFILE_D="/etc/profile.d/geYiProxy.sh"

# ---------------------------------------------------------------------------
# logging (ASCII only - the target host may not have a UTF-8 locale)
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ok()   { printf '[%s] OK   %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] FAIL %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --minutes)
        ROTATE_MINUTES="${2:-30}"
        case "${ROTATE_MINUTES}" in
          ''|*[!0-9]*) die "--minutes needs a number" ;;
        esac
        [ "${ROTATE_MINUTES}" -ge 5 ] || die "--minutes must be >= 5"
        [ "${ROTATE_MINUTES}" -le 720 ] || die "--minutes must be <= 720"
        shift 2 ;;
      --minutes=*)
        ROTATE_MINUTES="${1#*=}"
        shift ;;
      *) shift ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------
detect_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID="unknown"; OS_LIKE=""
  fi
  case "${OS_ID}" in
    debian|ubuntu|linuxmint|kali) PKG_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol|fedora) PKG_FAMILY="rhel" ;;
    *)
      case "${OS_LIKE}" in
        *debian*) PKG_FAMILY="debian" ;;
        *rhel*|*fedora*) PKG_FAMILY="rhel" ;;
        *) PKG_FAMILY="unknown" ;;
      esac ;;
  esac
}

check_deps() {
  local missing=()
  have_cmd curl || missing+=("curl")
  have_cmd tar  || missing+=("tar")
  if ! have_cmd openssl && ! have_cmd gnutls-cli; then missing+=("openssl"); fi
  if [ ${#missing[@]} -gt 0 ]; then
    err "missing dependencies: ${missing[*]}"
    err "Debian: apt-get install -y curl openssl ca-certificates"
    err "RHEL  : yum install -y curl openssl ca-certificates"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# root public key - the only trust anchor shipped to the client.
# It is NEVER distributed to a gateway node.
#
# The key ships in PEM (SubjectPublicKeyInfo) because openssl can verify with
# it directly (-pubin). The .NET XML form is kept only for reference and for
# cross-checking the shipped PEM.
# ---------------------------------------------------------------------------
ROOT_PUB_PEM="${CONF_DIR}/ca_root_pub.pem"
ROOT_PUB_XML="${CONF_DIR}/ca_root_pub.xml"

install_root_pub() {
  mkdir -p "${CONF_DIR}"
  local self_dir pkg_pem pkg_xml
  self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  pkg_pem="${self_dir}/ca_root_pub.pem"
  pkg_xml="${self_dir}/ca_root_pub.xml"

  if [ -f "${pkg_pem}" ]; then
    cp -f "${pkg_pem}" "${ROOT_PUB_PEM}"
    ok "root public key (PEM) installed from package"
  elif [ -f "${APP_DIR}/ca_root_pub.pem" ]; then
    cp -f "${APP_DIR}/ca_root_pub.pem" "${ROOT_PUB_PEM}"
    ok "root public key (PEM) installed from ${APP_DIR}"
  elif curl -fsS --max-time 10 "${ROOT_PUB_PEM_URL}" -o "${ROOT_PUB_PEM}.tmp" 2>/dev/null; then
    mv -f "${ROOT_PUB_PEM}.tmp" "${ROOT_PUB_PEM}"
    ok "root public key (PEM) downloaded from 199"
  else
    die "ca_root_pub.pem not found. Put it next to this script (it ships with geYiProxy-linux-client.tar.gz) or download it from ${ROOT_PUB_PEM_URL}"
  fi

  # keep the XML form for reference / cross-check
  if [ -f "${pkg_xml}" ]; then
    cp -f "${pkg_xml}" "${ROOT_PUB_XML}"
  elif [ -f "${APP_DIR}/ca_root_pub.xml" ]; then
    cp -f "${APP_DIR}/ca_root_pub.xml" "${ROOT_PUB_XML}"
  fi

  # sanity: openssl must be able to read the key
  if ! openssl pkey -pubin -in "${ROOT_PUB_PEM}" -noout >/dev/null 2>&1; then
    die "root public key (PEM) is not readable by openssl - aborting"
  fi
  ok "root public key validated by openssl"
}

# ---------------------------------------------------------------------------
# CA verification chain
#   1) /bpub gives the business public key (PUB) + root signature (BP_SIG)
#   2) local root public key verifies BP_SIG  -> business key is trusted
#   3) /ca.txt gives the CA certificate + business signature (SIG)
#   4) business key verifies SIG             -> CA is trusted
#   5) freshness + self-signed + subject + expiry + thumbprint match
# Only a CA that passes every step is installed.
# ---------------------------------------------------------------------------
# Fallback: derive the business public key PEM from the live bpub XML at runtime.
# Needs python3. The .NET XML -> SPKI PEM conversion is the only portable way;
# openssl 3.x cannot build a public key from modulus+exponent directly.
derive_biz_pem() {
  local node="$1" tmp="$2"
  command -v python3 >/dev/null 2>&1 || { warn "node ${node}: python3 required to derive key"; return 1; }
  local pub
  pub="$(grep -E '^PUB=' "${tmp}/bpub.txt" | head -1 | cut -d= -f2- | tr -d '\r')"
  printf '%s' "${pub}" | base64 -d > "${tmp}/biz_pub_${node}.xml" 2>/dev/null || return 1
  python3 - "${tmp}/biz_pub_${node}.xml" "${tmp}/biz_pub_${node}.pem" <<'PYEOF' 2>/dev/null || return 1
import sys, base64, re
def L(n):
    if n < 0x80: return bytes([n])
    b = n.to_bytes((n.bit_length()+7)//8, 'big'); return bytes([0x80|len(b)]) + b
def I(b):
    if b[0] & 0x80: b = b'\x00' + b
    return b'\x02' + L(len(b)) + b
def S(b): return b'\x30' + L(len(b)) + b
xml = open(sys.argv[1]).read()
mod = base64.b64decode(re.search(r'<Modulus>([^<]*)</Modulus>', xml).group(1))
exp = base64.b64decode(re.search(r'<Exponent>([^<]*)</Exponent>', xml).group(1))
rsa = S(I((b'\x00'+mod) if mod[0]&0x80 else mod) + I((b'\x00'+exp) if exp[0]&0x80 else exp))
alg = S(b'\x06\x09' + bytes.fromhex('2a864886f70d010101') + b'\x05\x00')
bs  = b'\x03' + L(len(rsa)+1) + b'\x00' + rsa
spki = S(alg + bs)
pem = '-----BEGIN PUBLIC KEY-----\n'
b64 = base64.b64encode(spki).decode()
for i in range(0, len(b64), 64): pem += b64[i:i+64] + '\n'
pem += '-----END PUBLIC KEY-----\n'
open(sys.argv[2], 'w').write(pem)
PYEOF
}

verify_and_fetch_ca() {
  local node="$1"
  local ca_url="http://10.0.50.${node}:${HEALTH_PORT}/ca.txt"
  local bpub_url="http://10.0.50.${node}:${HEALTH_PORT}/bpub"
  local tmp; tmp="$(mktemp -d)" || return 1

  curl -fsS --max-time 10 "${bpub_url}" -o "${tmp}/bpub.txt" 2>/dev/null || { rm -rf "${tmp}"; return 1; }
  curl -fsS --max-time 10 "${ca_url}"   -o "${tmp}/ca.txt"   2>/dev/null || { rm -rf "${tmp}"; return 1; }

  local PUB BP_SIG CA_B64 SIG_B64 CA_THUMB TS VER
  # The gateway serves CRLF text; strip CR so the values compare correctly.
  PUB=$(grep -E '^PUB='      "${tmp}/bpub.txt" | head -1 | cut -d= -f2- | tr -d '\r')
  BP_SIG=$(grep -E '^BP_SIG=' "${tmp}/bpub.txt" | head -1 | cut -d= -f2- | tr -d '\r')
  CA_B64=$(grep -E '^CA='      "${tmp}/ca.txt"   | head -1 | cut -d= -f2- | tr -d '\r')
  SIG_B64=$(grep -E '^SIG='    "${tmp}/ca.txt"   | head -1 | cut -d= -f2- | tr -d '\r')
  CA_THUMB=$(grep -E '^THUMB=' "${tmp}/ca.txt"   | head -1 | cut -d= -f2- | tr -d '\r')
  TS=$(grep -E '^TS='        "${tmp}/ca.txt"   | head -1 | cut -d= -f2- | tr -d '\r')
  VER=$(grep -E '^VER='      "${tmp}/ca.txt"   | head -1 | cut -d= -f2- | tr -d '\r')

  if [ -z "${PUB}" ] || [ -z "${BP_SIG}" ] || [ -z "${CA_B64}" ] || [ -z "${SIG_B64}" ] \
     || [ -z "${CA_THUMB}" ] || [ -z "${TS}" ]; then
    warn "node ${node}: malformed bpub/ca payload"
    rm -rf "${tmp}"; return 1
  fi
  [ "${VER}" = "1" ] || { warn "node ${node}: bad ca.txt VER"; rm -rf "${tmp}"; return 1; }

  # Decode base64 payloads robustly. GNU base64 -d is strict about padding; the
  # gateway may serve base64 without '=' padding, so pad to a multiple of 4.
  pad() {  # pad base64 arg to a multiple of 4, then decode
    local s="${1//[!A-Za-z0-9+/]/}"   # keep only base64 chars
    while [ ${#s} % 4 -ne 0 ]; do s="${s}="; done
    printf '%s' "${s}" | base64 -d 2>/dev/null
  }
  pad "${PUB}"     > "${tmp}/biz_pub.xml" 2>/dev/null || { rm -rf "${tmp}"; return 1; }
  pad "${BP_SIG}"  > "${tmp}/bp_sig.bin"  2>/dev/null || { rm -rf "${tmp}"; return 1; }
  pad "${CA_B64}"  > "${tmp}/ca.der"      2>/dev/null || { rm -rf "${tmp}"; return 1; }
  pad "${SIG_B64}" > "${tmp}/sig.bin"     2>/dev/null || { rm -rf "${tmp}"; return 1; }
  [ -s "${tmp}/ca.der" ] || { warn "node ${node}: CA decode produced empty DER"; rm -rf "${tmp}"; return 1; }

  # step 1: root public key verifies the root signature over the business key XML
  # NOTE: openssl dgst -verify reads a PEM public key directly; do NOT pass
  # -pubin (that option belongs to "openssl pkey", not to "dgst").
  if ! openssl dgst -sha256 -verify "${ROOT_PUB_PEM}" \
        -signature "${tmp}/bp_sig.bin" "${tmp}/biz_pub.xml" >/dev/null 2>&1; then
    warn "node ${node}: root signature verification FAILED"
    rm -rf "${tmp}"; return 1
  fi

  # step 2: business public key verifies the CA payload signature.
  # The business public key is shipped pre-generated as PEM (biz_pub_<node>.pem).
  # At runtime we re-verify the live bpub against the shipped root key (step 1),
  # so a rotated key is caught: if the live PUB differs from the shipped PEM,
  # step 1 (root over live XML) still proves authenticity, and we then use the
  # live-derived key. For the common case the shipped PEM matches the live key.
  local biz_pem="${PKG_PEM_DIR}/biz_pub_${node}.pem"
  local biz_key="${biz_pem}"
  if [ -f "${biz_pem}" ]; then
    biz_key="${biz_pem}"
  else
    # no shipped PEM: derive it from the live XML at runtime (needs python3)
    warn "node ${node}: no shipped biz_pub_${node}.pem, deriving from live XML"
    derive_biz_pem "${node}" "${tmp}" || { rm -rf "${tmp}"; return 1; }
    biz_key="${tmp}/biz_pub_${node}.pem"
  fi
  local payload="${tmp}/payload.txt"
  printf 'VER=1|THUMB=%s|TS=%s|CA=%s' "${CA_THUMB}" "${TS}" "${CA_B64}" > "${payload}"
  if ! openssl dgst -sha256 -verify "${biz_key}" \
        -signature "${tmp}/sig.bin" "${payload}" >/dev/null 2>&1; then
    warn "node ${node}: CA signature verification FAILED"
    rm -rf "${tmp}"; return 1
  fi

  # step 3: timestamp freshness (max 48h)
  local ts_epoch now_epoch age_h
  ts_epoch=$(date -d "${TS}" +%s 2>/dev/null \
          || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${TS}" +%s 2>/dev/null \
          || echo 0)
  [ "${ts_epoch}" -eq 0 ] && { warn "node ${node}: cannot parse timestamp"; rm -rf "${tmp}"; return 1; }
  now_epoch=$(date +%s)
  age_h=$(( (now_epoch - ts_epoch) / 3600 ))
  [ "${age_h}" -lt 0 ] && age_h=$(( -age_h ))
  [ "${age_h}" -gt 48 ] && { warn "node ${node}: timestamp too old (${age_h}h)"; rm -rf "${tmp}"; return 1; }

  # step 4: certificate sanity
  if ! openssl x509 -inform DER -in "${tmp}/ca.der" -noout -subject >/dev/null 2>&1; then
    warn "node ${node}: cannot parse CA certificate"
    rm -rf "${tmp}"; return 1
  fi
  local subject issuer
  subject=$(openssl x509 -inform DER -in "${tmp}/ca.der" -noout -subject 2>/dev/null | sed 's/^subject=//')
  issuer=$(openssl x509 -inform DER -in "${tmp}/ca.der" -noout -issuer  2>/dev/null | sed 's/^issuer=//')
  printf '%s' "${subject}" | grep -qi "mitmproxy" || { warn "node ${node}: unexpected CA subject"; rm -rf "${tmp}"; return 1; }
  [ "${subject}" = "${issuer}" ] || { warn "node ${node}: CA is not self-signed (subj='${subject}' iss='${issuer}')"; rm -rf "${tmp}"; return 1; }
  openssl x509 -inform DER -in "${tmp}/ca.der" -noout -checkend 0 >/dev/null 2>&1 \
    || { warn "node ${node}: CA certificate expired"; rm -rf "${tmp}"; return 1; }

  # step 5: thumbprint consistency (SHA1 of the DER == declared thumbprint)
  local calc_thumb
  calc_thumb=$(openssl x509 -inform DER -in "${tmp}/ca.der" -noout -fingerprint -sha1 2>/dev/null \
               | cut -d= -f2 | tr -d ':' | tr 'a-f' 'A-F')
  if [ "${calc_thumb}" != "${CA_THUMB}" ]; then
    warn "node ${node}: thumbprint mismatch (calc=${calc_thumb} declared=${CA_THUMB})"
    rm -rf "${tmp}"; return 1
  fi

  openssl x509 -inform DER -in "${tmp}/ca.der" -out "${tmp}/ca.pem" 2>/dev/null \
    || { rm -rf "${tmp}"; return 1; }
  cp -f "${tmp}/ca.pem" "${STATE_DIR}/ca_${node}.pem"
  printf '%s' "${CA_THUMB}" > "${STATE_DIR}/ca_${node}.thumb"
  rm -rf "${tmp}"
  return 0
}

# ---------------------------------------------------------------------------
# CA installation into the system trust store
# ---------------------------------------------------------------------------
update_ca_store() {
  case "${PKG_FAMILY}" in
    debian)
      have_cmd update-ca-certificates && update-ca-certificates >/dev/null 2>&1 ;;
    rhel)
      if have_cmd update-ca-trust; then
        update-ca-trust extract >/dev/null 2>&1 || true
        update-ca-trust >/dev/null 2>&1 || true
      fi ;;
    *)
      warn "unknown package manager: import ${CA_DIR}/geYiProxy_*.crt manually" ;;
  esac
}

install_ca_systemwide() {
  local thumb="$1" pem="$2" node="$3"
  local target="${CA_DIR}/geYiProxy_${node}.crt"
  mkdir -p "${CA_DIR}"
  local f old_thumb
  for f in "${CA_DIR}"/geYiProxy_*.crt; do
    [ -e "$f" ] || continue
    old_thumb=$(openssl x509 -in "$f" -noout -fingerprint -sha1 2>/dev/null \
                | cut -d= -f2 | tr -d ':' | tr 'a-f' 'A-F')
    [ "${old_thumb}" = "${thumb}" ] && rm -f "$f"
  done
  cp -f "${pem}" "${target}"
  chmod 644 "${target}"
  update_ca_store
  ok "node ${node}: CA ${thumb} installed into system trust store"
}

# ---------------------------------------------------------------------------
# node health / proxy probes
# ---------------------------------------------------------------------------
node_healthy() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://10.0.50.${1}:${HEALTH_PORT}/health" 2>/dev/null)
  [ "${code}" = "200" ]
}

node_proxy_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 6 \
        --proxy "http://10.0.50.${1}:${PROXY_PORT}" https://www.google.com 2>/dev/null)
  case "${code}" in 200|301|302|303|307|308) return 0 ;; *) return 1 ;; esac
}

proxy_busy() {
  local n
  if have_cmd ss; then
    n=$(ss -tn state established 2>/dev/null | awk -v p=":${PROXY_PORT}\$" '$0 ~ p {c++} END{print c+0}')
    [ "${n}" -gt 0 ] && return 0
  elif have_cmd netstat; then
    n=$(netstat -tn 2>/dev/null | grep -c "ESTABLISHED.*:${PROXY_PORT}[[:space:]]")
    [ "${n}" -gt 0 ] && return 0
  fi
  return 1
}

current_node() { cat "${STATE_DIR}/active_node" 2>/dev/null || echo ""; }
set_current_node() { echo "$1" > "${STATE_DIR}/active_node"; }

pick_random_node() {
  local exclude="$1" healthy=() n
  for n in "${NODES[@]}"; do
    [ "$n" = "${exclude}" ] && continue
    node_healthy "$n" && healthy+=("$n")
  done
  [ ${#healthy[@]} -eq 0 ] && return 1
  echo "${healthy[$(( RANDOM % ${#healthy[@]} ))]}"
}

# ---------------------------------------------------------------------------
# proxy environment
# ---------------------------------------------------------------------------
write_proxy_env() {
  local node; node=$(current_node)
  [ -n "${node}" ] || node="${NODES[0]}"
  local proxy="http://10.0.50.${node}:${PROXY_PORT}"
  local noproxy="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  mkdir -p "${CONF_DIR}/curl"

  cat > "${PROFILE_D}" <<EOF
# GeYiProxy overseas proxy (generated by install.sh; removed by uninstall.sh)
export http_proxy="${proxy}"
export https_proxy="${proxy}"
export HTTP_PROXY="${proxy}"
export HTTPS_PROXY="${proxy}"
export no_proxy="${noproxy}"
export NO_PROXY="${noproxy}"
EOF
  chmod 644 "${PROFILE_D}"

  if [ -f /etc/environment ]; then
    cp -f /etc/environment "${STATE_DIR}/environment.bak" 2>/dev/null || true
    grep -v -E '^(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY)=' /etc/environment \
      > "${STATE_DIR}/environment.new" 2>/dev/null || true
    cat >> "${STATE_DIR}/environment.new" <<EOF
http_proxy="${proxy}"
https_proxy="${proxy}"
HTTP_PROXY="${proxy}"
HTTPS_PROXY="${proxy}"
no_proxy="${noproxy}"
NO_PROXY="${noproxy}"
EOF
    cp -f "${STATE_DIR}/environment.new" /etc/environment
    chmod 644 /etc/environment
  fi

  cat > "${CONF_DIR}/curl/curlrc" <<EOF
proxy = "${proxy}"
noproxy = "${noproxy}"
EOF
  cat > "${CONF_DIR}/gitconfig" <<EOF
[http]
    proxy = ${proxy}
[https]
    proxy = ${proxy}
EOF
  ok "proxy environment written (node ${node}, ${proxy})"
}

# ---------------------------------------------------------------------------
# shared library written to disk (used by the rotation timer and the CLI)
# ---------------------------------------------------------------------------
write_lib() {
  mkdir -p "${BIN_DIR}"
  cat > "${BIN_DIR}/lib.sh" <<LIBEOF
# GeYiProxy shared library (generated by install.sh)
NODES=(${NODES[*]})
PROXY_PORT="${PROXY_PORT}"
HEALTH_PORT="${HEALTH_PORT}"
ROTATE_MINUTES="${ROTATE_MINUTES}"
STATE_DIR="${STATE_DIR}"
CONF_DIR="${CONF_DIR}"
BIN_DIR="${BIN_DIR}"
LOG_DIR="${LOG_DIR}"

node_healthy() {
  local code
  code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \\
        "http://10.0.50.\${1}:\${HEALTH_PORT}/health" 2>/dev/null)
  [ "\${code}" = "200" ]
}

pick_random_node() {
  local exclude="\$1" healthy=() n
  for n in "\${NODES[@]}"; do
    [ "\$n" = "\${exclude}" ] && continue
    node_healthy "\$n" && healthy+=("\$n")
  done
  [ \${#healthy[@]} -eq 0 ] && return 1
  echo "\${healthy[\$(( RANDOM % \${#healthy[@]} ))]}"
}

proxy_busy() {
  local n
  if command -v ss >/dev/null 2>&1; then
    n=\$(ss -tn state established 2>/dev/null | awk -v p=":\${PROXY_PORT}\$" '\$0 ~ p {c++} END{print c+0}')
    [ "\${n}" -gt 0 ] && return 0
  elif command -v netstat >/dev/null 2>&1; then
    n=\$(netstat -tn 2>/dev/null | grep -c "ESTABLISHED.*:\${PROXY_PORT}[[:space:]]")
    [ "\${n}" -gt 0 ] && return 0
  fi
  return 1
}

current_node() { cat "\${STATE_DIR}/active_node" 2>/dev/null || echo ""; }
set_current_node() { echo "\$1" > "\${STATE_DIR}/active_node"; }

rotate_tick() {
  local last_ts cur now elapsed target
  cur=\$(current_node)
  if [ -z "\${cur}" ]; then
    target=\$(pick_random_node "") || return 0
    set_current_node "\${target}"
    date +%s > "\${STATE_DIR}/last_rotate_ts"
    return 0
  fi
  last_ts=\$(cat "\${STATE_DIR}/last_rotate_ts" 2>/dev/null || echo 0)
  now=\$(date +%s)
  elapsed=\$(( (now - last_ts) / 60 ))
  [ "\${elapsed}" -lt "\${ROTATE_MINUTES}" ] && return 0
  if proxy_busy; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') rotation deferred: proxy connections in use" >> "\${LOG_DIR}/rotate.log" 2>/dev/null || true
    return 0
  fi
  target=\$(pick_random_node "\${cur}") || { date +%s > "\${STATE_DIR}/last_rotate_ts"; return 0; }
  if [ -n "\${target}" ] && [ "\${target}" != "\${cur}" ]; then
    set_current_node "\${target}"
    echo "\$(date '+%Y-%m-%d %H:%M:%S') rotate \${cur} -> \${target}" >> "\${LOG_DIR}/rotate.log" 2>/dev/null || true
  fi
  date +%s > "\${STATE_DIR}/last_rotate_ts"
}

write_proxy_env() {
  local node proxy
  node=\$(current_node)
  [ -n "\${node}" ] || node="\${NODES[0]}"
  proxy="http://10.0.50.\${node}:\${PROXY_PORT}"
  if [ -f /etc/profile.d/geYiProxy.sh ]; then
    sed -i "s#^export http_proxy=.*#export http_proxy=\"\${proxy}\"#" /etc/profile.d/geYiProxy.sh
    sed -i "s#^export https_proxy=.*#export https_proxy=\"\${proxy}\"#" /etc/profile.d/geYiProxy.sh
    sed -i "s#^export HTTP_PROXY=.*#export HTTP_PROXY=\"\${proxy}\"#" /etc/profile.d/geYiProxy.sh
    sed -i "s#^export HTTPS_PROXY=.*#export HTTPS_PROXY=\"\${proxy}\"#" /etc/profile.d/geYiProxy.sh
  fi
  if [ -f "\${CONF_DIR}/curl/curlrc" ]; then
    sed -i "s#^proxy = .*#proxy = \"\${proxy}\"#" "\${CONF_DIR}/curl/curlrc"
  fi
  if [ -f "\${CONF_DIR}/gitconfig" ]; then
    sed -i "s#    proxy = .*#    proxy = \${proxy}#" "\${CONF_DIR}/gitconfig"
  fi
  if [ -f /etc/environment ]; then
    sed -i "s#^http_proxy=.*#http_proxy=\"\${proxy}\"#" /etc/environment
    sed -i "s#^https_proxy=.*#https_proxy=\"\${proxy}\"#" /etc/environment
    sed -i "s#^HTTP_PROXY=.*#HTTP_PROXY=\"\${proxy}\"#" /etc/environment
    sed -i "s#^HTTPS_PROXY=.*#HTTPS_PROXY=\"\${proxy}\"#" /etc/environment
  fi
}
LIBEOF
  chmod 644 "${BIN_DIR}/lib.sh"
}

# ---------------------------------------------------------------------------
# rotation timer
# ---------------------------------------------------------------------------
write_rotate_script() {
  mkdir -p "${BIN_DIR}"
  cat > "${BIN_DIR}/rotate.sh" <<EOF
#!/usr/bin/env bash
# GeYiProxy rotation daemon (generated by install.sh)
set -uo pipefail
. "${BIN_DIR}/lib.sh"
rotate_tick
write_proxy_env
EOF
  chmod 755 "${BIN_DIR}/rotate.sh"
}

install_systemd() {
  if ! have_cmd systemctl; then
    warn "no systemd, skip rotation service (run ${BIN_DIR}/rotate.sh manually)"
    return 0
  fi
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=GeYiProxy node rotation (random overseas exit rotation)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/rotate.sh
User=root

[Install]
WantedBy=multi-user.target
EOF
  cat > "${TIMER_FILE}" <<EOF
[Unit]
Description=GeYiProxy rotation timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.timer" >/dev/null 2>&1
  systemctl start "${SERVICE_NAME}.timer" >/dev/null 2>&1
  ok "rotation service installed (systemd timer, checks every 5 min)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
install_main() {
  log "===== GeYiProxy Linux client install: START ====="
  detect_os
  log "OS: ${OS_ID} (${OS_LIKE:-n/a}) pkg-family: ${PKG_FAMILY}"
  check_deps

  mkdir -p "${APP_DIR}" "${CONF_DIR}" "${BIN_DIR}" "${STATE_DIR}" "${LOG_DIR}"
  chmod 755 "${APP_DIR}" "${BIN_DIR}"
  chmod 750 "${STATE_DIR}"

  # 1) root public key
  install_root_pub

  # 2) verify and install every node CA
  local node installed=0
  for node in "${NODES[@]}"; do
    if verify_and_fetch_ca "${node}"; then
      install_ca_systemwide "$(cat "${STATE_DIR}/ca_${node}.thumb")" "${STATE_DIR}/ca_${node}.pem" "${node}"
      installed=$((installed + 1))
    else
      warn "node ${node}: CA verification failed, skipping this node"
    fi
  done
  [ "${installed}" -eq 0 ] && die "no node CA passed verification, aborting"

  # 3) pick the initial node (prefer one that really proxies)
  local cur="" n
  for n in "${NODES[@]}"; do
    if node_healthy "${n}" && node_proxy_ok "${n}"; then cur="${n}"; break; fi
  done
  if [ -z "${cur}" ]; then
    cur=$(pick_random_node "") || cur="${NODES[0]}"
    warn "no immediately usable node, using node ${cur} for now"
  else
    ok "initial node: ${cur} (health OK + proxy verified)"
  fi
  set_current_node "${cur}"
  date +%s > "${STATE_DIR}/last_rotate_ts"

  # 4) scripts and proxy environment
  write_lib
  write_rotate_script
  write_proxy_env

  # 5) rotation service
  install_systemd

  # 6) management command + uninstall script
  local self_dir
  self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  if [ -f "${self_dir}/geYiProxy" ]; then
    install -m 755 "${self_dir}/geYiProxy" /usr/local/bin/geYiProxy
    ok "management command installed: geYiProxy status|rotate|uninstall"
  fi
  if [ -f "${self_dir}/uninstall.sh" ]; then
    install -m 755 "${self_dir}/uninstall.sh" "${APP_DIR}/uninstall.sh"
    ok "uninstall script installed: ${APP_DIR}/uninstall.sh"
  fi
  cp -f "${ROOT_PUB_PEM}" "${APP_DIR}/ca_root_pub.pem" 2>/dev/null || true
  cp -f "${ROOT_PUB_XML}" "${APP_DIR}/ca_root_pub.xml" 2>/dev/null || true

  # 7) readme
  cat > "${APP_DIR}/README.txt" <<EOF
GeYiProxy overseas proxy - Linux client
installed : $(date '+%Y-%m-%d %H:%M:%S')
node      : ${cur}  ->  http://10.0.50.${cur}:${PROXY_PORT}
rotation  : every ${ROTATE_MINUTES} min (random, only when idle)
ca trust  : ${installed} node CA(s) installed

Usage:
  source /etc/profile.d/geYiProxy.sh   # activate in the current shell
  curl -x http://10.0.50.${cur}:${PROXY_PORT} https://www.google.com
  geYiProxy status                      # show state
  geYiProxy rotate                      # rotate now
  geYiProxy uninstall                   # full rollback
EOF

  ok "===== GeYiProxy Linux client install: DONE ====="
  log ""
  log "activate now : source /etc/profile.d/geYiProxy.sh"
  log "auto         : new shells pick it up via /etc/profile.d and /etc/environment"
  log "current exit : http://10.0.50.${cur}:${PROXY_PORT}"
}

case "${1:-install}" in
  install)   need_root; parse_args "${@:2}"; install_main ;;
  uninstall) need_root; bash "${APP_DIR}/uninstall.sh" ;;
  *) echo "usage: $0 [install|uninstall]"; exit 1 ;;
esac
