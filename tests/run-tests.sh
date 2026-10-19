#!/usr/bin/env bash
# Offline tests: model resolution, detection against a fake sysfs, dry-run install flows.
# Optional: CANON_PPD_DIR=<dir with Canon's CNCUPSLBP*CAPT*.ppd> verifies the model->PPD table.
set -u
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT_DIR/lib/common.sh"; . "$ROOT_DIR/lib/models.sh"; . "$ROOT_DIR/lib/detect.sh"
fail=0; t() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 1. every model resolves to itself
while read -r m; do t "resolve $m" "$(resolve_model "$m")" "$m"; done < <(list_models)

# 2. real-world IEEE-1284 MDL / product strings
t "Canon LBP6300dn"      "$(resolve_model 'Canon LBP6300dn')" LBP6300
t "LBP6300n"             "$(resolve_model 'LBP6300n')"        LBP6300n
t "LBP7210Cdn"           "$(resolve_model 'LBP7210Cdn')"      LBP7210C
t "LBP3018B"             "$(resolve_model 'LBP3018B')"        LBP3018
t "LBP2900B"             "$(resolve_model 'LBP2900B')"        LBP2900
t "LBP6200d"             "$(resolve_model 'LBP6200d')"        LBP6200
t "LBP-810 spaced"       "$(resolve_model 'LBP 810')"         LBP-810
t "LBP5050N"             "$(resolve_model 'LBP5050N')"        LBP5050
t "unknown LBP9999"      "$(resolve_model 'LBP9999' || echo none)" none
t "non-canon"            "$(resolve_model 'HP LaserJet' || echo none)" none

# 3. fake sysfs detection
FS=$(mktemp -d); trap 'rm -rf "$FS"' EXIT
mk() { # mk lpN ieee product serial
    mkdir -p "$FS/sys/class/usbmisc/$1" "$FS/sys/class/usbmisc/dev$1"
    ln -sfn "../dev$1" "$FS/sys/class/usbmisc/$1/device"
    printf '%s' "$2" > "$FS/sys/class/usbmisc/dev$1/ieee1284_id"
    printf '04a9' > "$FS/sys/class/usbmisc/dev$1/idVendor" 2>/dev/null
}
# device dir's parent holds idVendor/product/serial; emulate with ".." == usbmisc dir
mkdir -p "$FS/sys/class/usbmisc"
printf '04a9' > "$FS/sys/class/usbmisc/idVendor"; printf 'Canon CAPT USB Printer' > "$FS/sys/class/usbmisc/product"; printf 'ABC123' > "$FS/sys/class/usbmisc/serial"
mk lp0 'MFG:Canon;CMD:CAPT;MDL:LBP6020B;CLS:PRINTER;' x y
SYSFS_ROOT=$FS
out=$(detect_usb_printers)
t "detect node"   "$(cut -f1 <<<"$out")" /dev/usb/lp0
t "detect model"  "$(cut -f2 <<<"$out")" LBP6020B
t "detect serial" "$(cut -f3 <<<"$out")" ABC123

# 4. optional: PPD table vs Canon driver
if [ -n "${CANON_PPD_DIR:-}" ]; then
    while read -r m; do
        id=$(model_field "$m" 2)
        if ls "$CANON_PPD_DIR"/CNCUPSLBP${id}CAPT?.ppd >/dev/null 2>&1; then echo "ok   ppd $m -> $id"; else echo "MISS ppd $m -> $id (not in this Canon driver version)"; fi
    done < <(list_models)
fi
exit $fail
