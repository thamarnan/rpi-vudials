#!/usr/bin/env bash
# =============================================================================
# VU-Server one-shot installer for Raspberry Pi OS (Bookworm/Trixie, 64-bit)
#
# Usage:
#   curl -fsSL <raw-url-to-this-script> | sudo bash
#   -- OR --
#   sudo bash install-vu-server.sh
#
# What it does (idempotently — safe to re-run):
#   1. Installs system packages (git, python3, venv, pip)
#   2. Creates a dedicated 'vu' service user in the 'dialout' group
#   3. Clones (or updates) the VU-Server repo to /opt/vu-server/app
#   4. Creates a Python virtualenv and installs requirements
#   5. Patches config.yaml so the API listens on 0.0.0.0 (LAN-reachable)
#   6. Installs a udev rule so the VU hub is accessible without sudo
#   7. Installs and enables a systemd service that starts on boot &
#      auto-restarts on failure
#   8. Installs an 'vu-update' helper to pull + restart later
#
# Tested target: Raspberry Pi OS Lite (64-bit) on Pi 3 / 4 / 5 / Zero 2W
# =============================================================================

set -euo pipefail

# ---- Config (override via env vars if you want) -----------------------------
VU_USER="${VU_USER:-vu}"
VU_HOME="${VU_HOME:-/opt/vu-server}"
VU_APP_DIR="${VU_APP_DIR:-${VU_HOME}/app}"
VU_REPO_URL="${VU_REPO_URL:-https://github.com/SasaKaranovic/VU-Server.git}"
VU_REPO_REF="${VU_REPO_REF:-master}"            # branch/tag/commit to check out
VU_PORT="${VU_PORT:-5340}"
VU_BIND_HOST="${VU_BIND_HOST:-0.0.0.0}"         # set to 127.0.0.1 to keep local-only
SERVICE_NAME="vu-server"

# ---- Helpers ----------------------------------------------------------------
log()  { printf '\033[1;34m[vu-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vu-install]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[vu-install]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- Pre-flight checks ------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Please run as root (use sudo)."

if ! grep -qiE 'raspbian|debian|raspberry' /etc/os-release 2>/dev/null; then
    warn "This script targets Raspberry Pi OS / Debian. Detected something else:"
    warn "$(head -3 /etc/os-release)"
    warn "Continuing in 5s — Ctrl+C to abort..."
    sleep 5
fi

# ---- USB hub check ----------------------------------------------------------
# VU-Server can start without the hub plugged in, but it won't actually do
# anything useful until the hub appears AND the service has reconnected.
# Plugging the hub in BEFORE installation means everything is ready in one go
# and no post-install service restart is needed.
echo
echo "============================================================"
echo "  Before continuing: plug in your VU Dials HUB now."
echo "  (USB-A end into the Pi, USB-C end into the HUB)"
echo ""
echo "  Installing with the HUB already plugged in means the"
echo "  server can start talking to your dials immediately —"
echo "  no extra restart needed after the install finishes."
echo ""
echo "  If you install first and plug in later, you'll need to run:"
echo "    sudo systemctl restart vu-server"
echo "============================================================"
echo

# Detect a plausible USB-serial device. The udev rule covers FTDI / CH340 /
# CP210x VID:PIDs, which is what the VU hub typically uses. We just check
# whether any /dev/ttyUSB* exists OR a known VID appears in lsusb output.
hub_detected=false
if compgen -G "/dev/ttyUSB*" >/dev/null 2>&1; then
    hub_detected=true
fi
if command -v lsusb >/dev/null 2>&1; then
    if lsusb 2>/dev/null | grep -qiE '0403:6001|1a86:7523|10c4:ea60'; then
        hub_detected=true
    fi
fi

if [[ "$hub_detected" == "true" ]]; then
    log "USB serial device detected — looks like your hub is plugged in. ✓"
else
    warn "No USB-serial device detected yet."
    # If we're running interactively (stdin is a TTY), ask. Otherwise just
    # warn and continue, so that one-liners like `curl ... | sudo bash` still
    # work unattended.
    if [[ -t 0 ]]; then
        read -r -p "Plug in the HUB now and press ENTER to continue, or type 'skip' to install without it: " ans
        if [[ "${ans,,}" != "skip" ]]; then
            # Re-check after the user has had a chance to plug in.
            sleep 1
            if compgen -G "/dev/ttyUSB*" >/dev/null 2>&1; then
                log "USB serial device now detected. ✓"
            else
                warn "Still no device detected — continuing anyway."
                warn "After plugging in: sudo systemctl restart vu-server"
            fi
        fi
    else
        warn "Running non-interactively — continuing without the hub."
        warn "After plugging in: sudo systemctl restart vu-server"
    fi
fi
echo

# ---- 1. System packages -----------------------------------------------------
log "Updating apt and installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    git python3 python3-venv python3-pip ca-certificates curl

# ---- 2. Service user --------------------------------------------------------
if ! id -u "${VU_USER}" >/dev/null 2>&1; then
    log "Creating service user '${VU_USER}' with home ${VU_HOME}..."
    useradd --system --create-home --home-dir "${VU_HOME}" --shell /bin/bash "${VU_USER}"
else
    log "Service user '${VU_USER}' already exists — ensuring home is ${VU_HOME}..."
    # Force the home directory to be correct even if user was created earlier
    # with a different home (e.g. /home/vu from a prior partial install).
    current_home="$(getent passwd "${VU_USER}" | cut -d: -f6)"
    if [[ "${current_home}" != "${VU_HOME}" ]]; then
        log "  changing home from ${current_home} -> ${VU_HOME}"
        usermod -d "${VU_HOME}" "${VU_USER}"
    fi
fi

# Always make sure the user is in dialout (for /dev/ttyUSB* access)
usermod -aG dialout "${VU_USER}"

# Ensure the home directory exists and is owned by the service user.
install -d -o "${VU_USER}" -g "${VU_USER}" -m 0755 "${VU_HOME}"

# The upstream VU-Server logger HARDCODES its log path as /home/${USER}/vudials.log
# (see https://github.com/SasaKaranovic/VU-Server/issues/20). That means even
# though our service user's home is ${VU_HOME}, the app will still try to write
# to /home/${VU_USER}/. Rather than patch the upstream code, we just create
# that directory and make it writable.
HARDCODED_LOG_DIR="/home/${VU_USER}"
if [[ ! -d "${HARDCODED_LOG_DIR}" ]]; then
    log "Creating ${HARDCODED_LOG_DIR} for upstream's hardcoded log path..."
    install -d -o "${VU_USER}" -g "${VU_USER}" -m 0755 "${HARDCODED_LOG_DIR}"
else
    chown "${VU_USER}:${VU_USER}" "${HARDCODED_LOG_DIR}"
fi

# ---- 3. Clone or update the repo --------------------------------------------
if [[ -d "${VU_APP_DIR}/.git" ]]; then
    log "Repo already cloned — fetching latest from ${VU_REPO_REF}..."
    sudo -u "${VU_USER}" -H git -C "${VU_APP_DIR}" fetch --depth=1 origin "${VU_REPO_REF}"
    sudo -u "${VU_USER}" -H git -C "${VU_APP_DIR}" checkout "${VU_REPO_REF}"
    sudo -u "${VU_USER}" -H git -C "${VU_APP_DIR}" reset --hard "origin/${VU_REPO_REF}" || true
else
    log "Cloning ${VU_REPO_URL} into ${VU_APP_DIR}..."
    install -d -o "${VU_USER}" -g "${VU_USER}" "${VU_HOME}"
    sudo -u "${VU_USER}" -H git clone --depth=1 --branch "${VU_REPO_REF}" \
        "${VU_REPO_URL}" "${VU_APP_DIR}"
fi

# ---- 4. Python virtualenv + deps -------------------------------------------
VENV_DIR="${VU_APP_DIR}/.venv"
if [[ ! -x "${VENV_DIR}/bin/python3" ]]; then
    log "Creating Python virtualenv at ${VENV_DIR}..."
    sudo -u "${VU_USER}" -H python3 -m venv "${VENV_DIR}"
fi

log "Installing/upgrading Python dependencies into venv..."
sudo -u "${VU_USER}" -H "${VENV_DIR}/bin/pip" install --quiet --upgrade pip wheel
# pyinstaller is in requirements.txt but is only needed to build the Windows
# installer — it's a heavy dep on a Pi. We'll let it install anyway for fidelity
# with upstream, but if you want a lean install, uncomment the grep below.
sudo -u "${VU_USER}" -H "${VENV_DIR}/bin/pip" install --quiet -r "${VU_APP_DIR}/requirements.txt"
# Lean alternative:
# grep -v '^pyinstaller' "${VU_APP_DIR}/requirements.txt" \
#   | sudo -u "${VU_USER}" -H "${VENV_DIR}/bin/pip" install --quiet -r /dev/stdin

# Upstream's requirements.txt pins no version for tornado, but VU-Server is
# incompatible with tornado >= 6.5 (strict header handling causes a
# KeyError: 'Content-Type' on every response — see Tornado's web.py
# _clear_representation_headers). Force tornado to the last known-good
# 6.4.x series.
log "Pinning tornado<6.5 (upstream compat workaround)..."
sudo -u "${VU_USER}" -H "${VENV_DIR}/bin/pip" install --quiet "tornado<6.5"

# ---- 5. Patch config.yaml so the API is reachable on the LAN ---------------
CONFIG_FILE="${VU_APP_DIR}/config.yaml"
if [[ -f "${CONFIG_FILE}" ]]; then
    log "Patching ${CONFIG_FILE} (host=${VU_BIND_HOST}, port=${VU_PORT})..."
    # Use a tiny python edit so we don't depend on yq.
    sudo -u "${VU_USER}" -H "${VENV_DIR}/bin/python3" - "$CONFIG_FILE" "$VU_BIND_HOST" "$VU_PORT" <<'PY'
import sys
from ruamel.yaml import YAML
path, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
yaml = YAML()
yaml.preserve_quotes = True
with open(path) as f:
    data = yaml.load(f)
# Walk known shapes — the upstream config keeps server settings under 'server'
srv = data.get('server', data) if isinstance(data, dict) else {}
for key in ('hostname', 'host', 'address'):
    if key in srv:
        srv[key] = host
for key in ('port',):
    if key in srv:
        srv[key] = port
with open(path, 'w') as f:
    yaml.dump(data, f)
print(f"  -> wrote {path}")
PY
else
    warn "No config.yaml found in repo — VU-Server will use its defaults."
fi

# ---- 6. udev rule for the VU hub -------------------------------------------
# The VU hub uses an FTDI/CH340-style USB-serial chip and shows up as
# /dev/ttyUSB*. Membership in 'dialout' is already enough for the vu user,
# but this rule ALSO creates a stable /dev/vu-hub symlink and ensures the
# device is group-writable for dialout even on systems where the default
# udev rules don't already do that.
UDEV_RULE=/etc/udev/rules.d/99-vu-dials.rules
log "Installing udev rule at ${UDEV_RULE}..."
cat > "${UDEV_RULE}" <<'EOF'
# VU Dials hub — make device accessible to the 'dialout' group and create
# a stable /dev/vu-hub symlink. Covers common USB-serial bridge chips used
# by VU1 hubs (FTDI FT232, WCH CH340, Silabs CP210x). Harmless if you have
# other USB-serial devices — the symlink only attaches to matching ones.
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", \
    GROUP="dialout", MODE="0660", SYMLINK+="vu-hub"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", \
    GROUP="dialout", MODE="0660", SYMLINK+="vu-hub"
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", \
    GROUP="dialout", MODE="0660", SYMLINK+="vu-hub"
EOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty || true

# ---- 7. systemd service -----------------------------------------------------
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
log "Installing systemd unit at ${SERVICE_FILE}..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=VU Dials Server
Documentation=https://github.com/SasaKaranovic/VU-Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VU_USER}
Group=dialout
WorkingDirectory=${VU_APP_DIR}
# Force HOME — VU-Server writes logs to a path that depends on ~, and we want
# that to land under /opt/vu-server regardless of what /etc/passwd says.
Environment=HOME=${VU_HOME}
ExecStart=${VENV_DIR}/bin/python3 ${VU_APP_DIR}/server.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

# --- light sandboxing ---
# NOTE: ProtectHome is intentionally OFF because the upstream logger writes
# under the user's home directory. ProtectSystem=full would also block /opt
# writes; we keep it relaxed.
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" >/dev/null
log "Starting ${SERVICE_NAME}..."
systemctl restart "${SERVICE_NAME}.service"

# ---- 8. Convenience updater -------------------------------------------------
UPDATER=/usr/local/bin/vu-update
log "Installing updater command at ${UPDATER}..."
cat > "${UPDATER}" <<EOF
#!/usr/bin/env bash
# Pull latest VU-Server, refresh deps, restart the service.
set -euo pipefail
sudo -u ${VU_USER} -H git -C ${VU_APP_DIR} pull --ff-only
sudo -u ${VU_USER} -H ${VENV_DIR}/bin/pip install --quiet -r ${VU_APP_DIR}/requirements.txt
sudo systemctl restart ${SERVICE_NAME}
sudo systemctl --no-pager --full status ${SERVICE_NAME} | head -n 12
EOF
chmod +x "${UPDATER}"

# ---- Final status -----------------------------------------------------------
sleep 2
IP_ADDR="$(hostname -I | awk '{print $1}')"
echo
log "Install complete!"
echo "  -----------------------------------------------------------------"
echo "  Service:    systemctl status ${SERVICE_NAME}"
echo "  Logs:       journalctl -u ${SERVICE_NAME} -f"
echo "  Update:     sudo vu-update"
echo "  Web UI:     http://${IP_ADDR}:${VU_PORT}"
echo "  Local:      http://localhost:${VU_PORT}"
echo "  -----------------------------------------------------------------"
echo
systemctl --no-pager --full status "${SERVICE_NAME}" | head -n 12 || true
