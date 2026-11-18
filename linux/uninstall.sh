#!/usr/bin/env bash
# ==============================================================================
# geYiProxy Linux Client - full uninstall / rollback script
#
# Removes everything the installer created (no leftovers):
#   - systemd rotation service + timer
#   - /etc/profile.d/geYiProxy.sh
#   - proxy variables in /etc/environment (restored from the pre-install backup)
#   - geYiProxy CA certificates from the system trust store (+ refresh)
#   - /opt/geYiProxy directory
#   - /usr/local/bin/geYiProxy command
#   - /var/log/geYiProxy log directory
#   - apt/yum/dnf proxy settings that point at a geYiProxy node
#
# Usage:
#   sudo ./uninstall.sh            # full uninstall
#   sudo ./uninstall.sh --keep-ca  # keep the CA certs, only clear proxy config
# ==============================================================================
set -uo pipefail

APP_DIR="/opt/geYiProxy"
STATE_DIR="${APP_DIR}/state"
LOG_DIR="/var/log/geYiProxy"
CA_DIR="/usr/local/share/ca-certificates"
SERVICE_NAME="geyiproxy-rotate"
PROFILE_D="/etc/profile.d/geYiProxy.sh"
KEEP_CA=0

[ "${1:-}" = "--keep-ca" ] && KEEP_CA=1

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ok()   { printf '[%s] OK   %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] FAIL %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "run as root: sudo $0"
  exit 1
fi

log "===== GeYiProxy Linux client uninstall: START ====="

# ---------------------------------------------------------------------------
# 1) systemd service + timer
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.timer" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  ok "systemd service and timer removed"
else
  warn "no systemd, skipped"
fi

# ---------------------------------------------------------------------------
# 2) profile.d
# ---------------------------------------------------------------------------
if [ -f "${PROFILE_D}" ]; then
  rm -f "${PROFILE_D}"
  ok "removed ${PROFILE_D}"
fi

# ---------------------------------------------------------------------------
# 3) restore /etc/environment
# ---------------------------------------------------------------------------
if [ -f /etc/environment ]; then
  if [ -f "${STATE_DIR}/environment.bak" ]; then
    cp -f "${STATE_DIR}/environment.bak" /etc/environment
    chmod 644 /etc/environment
    ok "/etc/environment restored from pre-install backup"
  else
    grep -v -E '^(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY)=' /etc/environment \
      > /etc/environment.geyirem 2>/dev/null || true
    if [ -s /etc/environment.geyirem ]; then
      cp -f /etc/environment.geyirem /etc/environment
      chmod 644 /etc/environment
      ok "proxy variables cleared from /etc/environment"
    else
      rm -f /etc/environment.geyirem
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4) CA certificates from the system trust store
# ---------------------------------------------------------------------------
if [ "${KEEP_CA}" -eq 0 ]; then
  removed=0
  for f in "${CA_DIR}"/geYiProxy_*.crt; do
    [ -e "$f" ] || continue
    rm -f "$f" && removed=$((removed + 1))
  done
  if [ "${removed}" -gt 0 ]; then
    if command -v update-ca-certificates >/dev/null 2>&1; then
      update-ca-certificates >/dev/null 2>&1 || true
    fi
    if command -v update-ca-trust >/dev/null 2>&1; then
      update-ca-trust extract >/dev/null 2>&1 || true
      update-ca-trust >/dev/null 2>&1 || true
    fi
    ok "removed ${removed} geYiProxy CA certificate(s) and refreshed the trust store"
  else
    ok "no geYiProxy CA certificate to remove"
  fi
else
  warn "--keep-ca: CA certificates kept"
fi

# ---------------------------------------------------------------------------
# 5) apt / yum proxy settings (safety net)
# ---------------------------------------------------------------------------
for f in /etc/apt/apt.conf.d/95proxy /etc/apt/apt.conf /etc/yum.conf /etc/dnf/dnf.conf; do
  if [ -f "$f" ] && grep -q "10\.0\.50\.19" "$f" 2>/dev/null; then
    cp -f "$f" "${f}.geyibak" 2>/dev/null || true
    sed -i '/proxy/d' "$f" 2>/dev/null || true
    ok "cleaned proxy settings in ${f} (backup: ${f}.geyibak)"
  fi
done

# ---------------------------------------------------------------------------
# 6) command + directories
# ---------------------------------------------------------------------------
rm -f /usr/local/bin/geYiProxy
rm -rf "${APP_DIR}"
rm -rf "${LOG_DIR}"
ok "removed ${APP_DIR}, ${LOG_DIR} and /usr/local/bin/geYiProxy"

# ---------------------------------------------------------------------------
# 7) current shell environment
# ---------------------------------------------------------------------------
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY

log ""
log "===== GeYiProxy Linux client uninstall: DONE ====="
log "verify: curl https://www.google.com   (should go direct now)"
log "if this shell still has proxy vars: unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY"
