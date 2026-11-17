#!/usr/bin/env bash
# Tor Automate (Sanaei 3x-ui Edition) - installer for Debian / Ubuntu.
#
#   One-liner (after you publish the repo, see README):
#     bash <(curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh)
#   or from an extracted copy:
#     sudo bash install.sh
#
# What it does:   installs files to /opt/tor-automate, a launcher at /usr/local/bin/tor-automate,
#                 then runs "tor-automate --install-engine" (apt deps, /etc/tor-automate, cron).
# What it never does: modify, restart, stop or reconfigure Sanaei 3x-ui (/usr/local/x-ui, /etc/x-ui, x-ui service).

set -u
APP_DIR="/opt/tor-automate"
BIN_LINK="/usr/local/bin/tor-automate"
# Where to download from when this script is not run from a local copy (set when you publish your repo):
TA_BASE_URL="${TA_BASE_URL:-https://raw.githubusercontent.com/YOUR_GITHUB_USER/tor-automate-3xui/main}"

R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; N='\033[0m'
die()  { echo -e "${R}[!] $*${N}" >&2; exit 1; }
info() { echo -e "${C}[*]${N} $*"; }
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash install.sh"
[ -n "${BASH_VERSION:-}" ] || die "Please run this installer with bash."

# ---- OS check
[ -r /etc/os-release ] || die "Cannot detect the operating system."
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*) ok "Detected ${PRETTY_NAME:-$ID}" ;;
    *) die "Unsupported OS '${PRETTY_NAME:-unknown}'. Debian and Ubuntu only." ;;
esac
command -v apt-get >/dev/null 2>&1 || die "apt-get not found."

# ---- detect Sanaei 3x-ui (read-only)
XUI_BIN=""
for p in "${XUI_MAIN_FOLDER:-/usr/local/x-ui}/x-ui" /usr/local/x-ui/x-ui; do [ -x "$p" ] && { XUI_BIN="$p"; break; }; done
XUI_STATE_BEFORE="n/a"
if [ -n "$XUI_BIN" ]; then
    XUI_STATE_BEFORE=$(systemctl is-active x-ui 2>/dev/null || true)
    ok "Sanaei 3x-ui found at $XUI_BIN (service: ${XUI_STATE_BEFORE:-unknown}) - it will not be modified."
else
    warn "Sanaei 3x-ui was not found on this server."
    warn "Installation continues; you can point Tor Automate at a panel URL manually later."
fi

# ---- minimum tools needed by the installer itself
if ! command -v curl >/dev/null 2>&1 && ! [ -f "$(dirname "$(readlink -f "$0" 2>/dev/null)")/tor-automate.sh" ]; then
    info "Installing curl..."; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates || die "Could not install curl."
fi

# ---- fetch sources (local copy preferred)
SRC_DIR=""
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)")" 2>/dev/null && pwd)"
if [ -n "$HERE" ] && [ -f "$HERE/tor-automate.sh" ] && [ -f "$HERE/lib/xui.sh" ]; then
    SRC_DIR="$HERE"; info "Using local files from $SRC_DIR"
else
    case "$TA_BASE_URL" in *YOUR_GITHUB_USER*) die "No local files found and TA_BASE_URL is not set.
    Run from the extracted project folder (sudo bash install.sh) or set TA_BASE_URL to your published repo, e.g.
    TA_BASE_URL=https://raw.githubusercontent.com/<you>/<repo>/main bash <(curl -fsSL \$TA_BASE_URL/install.sh)" ;; esac
    SRC_DIR="$(mktemp -d /tmp/tor-automate-src.XXXXXX)"; trap 'rm -rf "$SRC_DIR"' EXIT
    mkdir -p "$SRC_DIR/lib"
    info "Downloading from $TA_BASE_URL ..."
    curl -fsSL "$TA_BASE_URL/tor-automate.sh" -o "$SRC_DIR/tor-automate.sh" || die "Download of tor-automate.sh failed."
    curl -fsSL "$TA_BASE_URL/lib/xui.sh"      -o "$SRC_DIR/lib/xui.sh"      || die "Download of lib/xui.sh failed."
fi
bash -n "$SRC_DIR/tor-automate.sh" && bash -n "$SRC_DIR/lib/xui.sh" || die "Downloaded files failed a syntax check; aborting."

# ---- install files (dedicated directory)
info "Installing to $APP_DIR ..."
install -d -m 755 "$APP_DIR" "$APP_DIR/lib"
install -m 755 "$SRC_DIR/tor-automate.sh" "$APP_DIR/tor-automate"
install -m 644 "$SRC_DIR/lib/xui.sh"      "$APP_DIR/lib/xui.sh"
[ -f "$SRC_DIR/LICENSE" ] && install -m 644 "$SRC_DIR/LICENSE" "$APP_DIR/LICENSE"
[ -f "$SRC_DIR/README.md" ] && install -m 644 "$SRC_DIR/README.md" "$APP_DIR/README.md"
ln -sf "$APP_DIR/tor-automate" "$BIN_LINK"

# ---- dependencies, directories, cron (idempotent; implemented once, in the main script)
"$APP_DIR/tor-automate" --install-engine || die "Engine setup failed (see messages above)."

# ---- prove we left 3x-ui alone
if [ -n "$XUI_BIN" ]; then
    after=$(systemctl is-active x-ui 2>/dev/null || true)
    [ "$after" = "$XUI_STATE_BEFORE" ] && ok "3x-ui service state unchanged (${after:-unknown})." || warn "3x-ui service state changed: ${XUI_STATE_BEFORE:-?} -> ${after:-?} (not caused by this installer)."
fi

echo ""
ok "Tor Automate installed."
echo -e "   Start it with:  ${G}sudo tor-automate${N}"
echo -e "   1) menu [5] Bulk Add Nodes   2) menu [9] Panel Sanaei 3x-ui Integration -> [1] Auto-Extract"
echo -e "   Config: /etc/tor-automate   Data: /var/lib/tor-automate   Program: $APP_DIR"
