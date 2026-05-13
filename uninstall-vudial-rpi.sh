#!/usr/bin/env bash
# =============================================================================
# VU-Server uninstaller — reverses everything install-vu-server.sh did.
#
# Usage:
#   sudo bash uninstall-vu-server.sh             # interactive (asks about data)
#   sudo bash uninstall-vu-server.sh --purge     # remove EVERYTHING, no prompt
#   sudo bash uninstall-vu-server.sh --keep-data # keep /opt/vu-server intact
# =============================================================================

set -euo pipefail

VU_USER="${VU_USER:-vu}"
VU_HOME="${VU_HOME:-/opt/vu-server}"
SERVICE_NAME="vu-server"

log()  { printf '\033[1;34m[vu-uninstall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vu-uninstall]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[vu-uninstall]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root (use sudo)."

MODE="ask"
for arg in "$@"; do
    case "$arg" in
        --purge)     MODE="purge" ;;
        --keep-data) MODE="keep"  ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---- 1. Stop & disable the service -----------------------------------------
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    log "Stopping and disabling ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
else
    log "Service ${SERVICE_NAME} not installed — skipping."
fi

# ---- 2. Remove systemd unit ------------------------------------------------
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
if [[ -f "${SERVICE_FILE}" ]]; then
    log "Removing ${SERVICE_FILE}..."
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
fi

# ---- 3. Remove udev rule ---------------------------------------------------
UDEV_RULE=/etc/udev/rules.d/99-vu-dials.rules
if [[ -f "${UDEV_RULE}" ]]; then
    log "Removing udev rule..."
    rm -f "${UDEV_RULE}"
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=tty || true
fi

# ---- 4. Remove the helper command ------------------------------------------
if [[ -f /usr/local/bin/vu-update ]]; then
    log "Removing /usr/local/bin/vu-update..."
    rm -f /usr/local/bin/vu-update
fi

# ---- 5. Decide what to do with /opt/vu-server ------------------------------
if [[ -d "${VU_HOME}" ]]; then
    case "$MODE" in
        purge)
            REMOVE=yes
            ;;
        keep)
            REMOVE=no
            ;;
        ask)
            echo
            warn "About to delete ${VU_HOME} — this contains:"
            warn "  - your VU-Server SQLite database (dial settings, API keys)"
            warn "  - your config.yaml (including master_key)"
            warn "  - the cloned source code and virtualenv"
            echo
            read -r -p "Delete ${VU_HOME}? [y/N] " ans
            case "${ans,,}" in
                y|yes) REMOVE=yes ;;
                *)     REMOVE=no  ;;
            esac
            ;;
    esac

    if [[ "${REMOVE}" == "yes" ]]; then
        log "Removing ${VU_HOME}..."
        rm -rf "${VU_HOME}"
        # Upstream hardcodes /home/${VU_USER}/vudials.log — remove that too.
        # The :? guard ensures we abort rather than rm -rf /home if VU_USER is empty.
        if [[ -d "/home/${VU_USER}" ]]; then
            log "Removing /home/${VU_USER} (upstream's hardcoded log directory)..."
            rm -rf "/home/${VU_USER:?refusing to remove /home with empty VU_USER}"
        fi
    else
        log "Keeping ${VU_HOME} intact."
    fi
else
    log "${VU_HOME} not present — nothing to clean up there."
fi

# ---- 6. Remove the service user --------------------------------------------
if id -u "${VU_USER}" >/dev/null 2>&1; then
    # Only delete the user if their home directory is gone (or if --purge).
    if [[ ! -d "${VU_HOME}" ]] || [[ "$MODE" == "purge" ]]; then
        log "Removing service user '${VU_USER}'..."
        # userdel may complain if the user is logged in or owns processes;
        # ignore that, since by this point the service is stopped.
        userdel "${VU_USER}" 2>/dev/null || warn "Could not remove user '${VU_USER}' (it may still own files outside ${VU_HOME})."
    else
        log "Keeping service user '${VU_USER}' (since ${VU_HOME} was kept)."
    fi
fi

echo
log "Uninstall complete."
echo "  - System packages (git, python3, python3-venv) were NOT removed,"
echo "    since you may want them. Remove manually if desired:"
echo "      sudo apt-get autoremove --purge git python3-venv"
