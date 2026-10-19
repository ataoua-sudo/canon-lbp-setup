# shellcheck shell=bash
# Detect Canon CAPT printers on USB.
#
# Strategy (no hard-coded USB product IDs are needed):
#   1. load the usblp kernel module -> /sys/class/usbmisc/lp*/device/ieee1284_id
#   2. parse MDL:/MODEL: from the IEEE-1284 id, map it to the model table
#   3. fall back to CUPS `lpinfo -v` (usb://Canon/<model>?serial=...)
#   4. otherwise report "Canon CAPT printer found but model unknown" so the user can choose
# SYSFS_ROOT lets the tests point at a fake sysfs tree.

SYSFS_ROOT=${SYSFS_ROOT:-}

# Output (tab separated): devnode  model  serial  ieee1284_id
detect_usb_printers() {
    local d lpn id mdl serial model node
    for d in "$SYSFS_ROOT"/sys/class/usbmisc/lp*; do
        [ -e "$d" ] || continue
        lpn=$(basename "$d")
        id=$(cat "$d/device/ieee1284_id" 2>/dev/null | tr -d '\n')
        local vendor; vendor=$(cat "$d/device/../idVendor" 2>/dev/null)
        [ -n "$vendor" ] && [ "$vendor" != 04a9 ] && continue
        mdl=$(printf '%s' "$id" | tr ';' '\n' | awk -F: '$1=="MDL"||$1=="MODEL"{print $2; exit}')
        [ -n "$mdl" ] || mdl=$(cat "$d/device/../product" 2>/dev/null)
        printf '%s' "$id$mdl" | grep -qi 'canon\|lbp' || [ "$vendor" = 04a9 ] || continue
        serial=$(cat "$d/device/../serial" 2>/dev/null)
        model=$(resolve_model "$mdl" 2>/dev/null || true)
        node=/dev/usb/$lpn
        printf '%s\t%s\t%s\t%s\n' "$node" "${model:-?}" "$serial" "${mdl:-unknown}"
    done
}

# Fallback: CUPS device list. Output: uri<TAB>model
detect_cups_printers() {
    command -v lpinfo >/dev/null 2>&1 || return 0
    lpinfo -v 2>/dev/null | awk '$2 ~ /^usb:\/\/Canon\//{print $2}' | while read -r uri; do
        local m; m=$(printf '%s' "$uri" | sed -E 's#usb://Canon/([^?]*).*#\1#; s/%20/ /g')
        printf '%s\t%s\n' "$uri" "$(resolve_model "$m" 2>/dev/null || echo '?')"
    done
}

# Any Canon device on the USB bus at all (even if usblp did not bind)?
canon_usb_present() {
    local d
    for d in "$SYSFS_ROOT"/sys/bus/usb/devices/*; do
        [ "$(cat "$d/idVendor" 2>/dev/null)" = 04a9 ] && return 0
    done
    return 1
}

load_usblp() {
    [ -n "$SYSFS_ROOT" ] && return 0
    [ "$(id -u)" -eq 0 ] || return 0
    lsmod 2>/dev/null | grep -q '^usblp' && return 0
    run modprobe usblp 2>/dev/null || warn "could not load kernel module usblp"
    sleep 1
}
