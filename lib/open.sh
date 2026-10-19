# shellcheck shell=bash
# Bundled open-source driver (captdriver lineage): LBP2900 / LBP2900B / LBP3000. No 32-bit libs, no ccpd.

open_ppd_for() {
    case "$(norm "$1")" in
        LBP2900|LBP2900B) echo Canon-LBP-2900.ppd ;;
        LBP3000)          echo Canon-LBP-3000.ppd ;;
        *) return 1 ;;
    esac
}

open_build_install() {
    install_open_deps
    local b="$WORK/open"
    run rm -rf "$b"; run mkdir -p "$b"
    run cp -r "$ROOT_DIR/open-driver/." "$b/"
    info "Building the open-source filter"
    if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] autoreconf/configure/make in $b"; else
        ( cd "$b" && autoreconf -fi >/dev/null 2>&1 && ./configure --prefix=/usr >/dev/null && make -j"$(nproc)" >/dev/null ) \
            || die "build of the open-source driver failed"
    fi
    local fdir; fdir="$(cups-config --serverbin 2>/dev/null || echo /usr/lib/cups)/filter"
    run install -Dm755 "$b/src/rastertocapt" "$fdir/rastertocapt"
    run install -Dm644 "$ROOT_DIR/open-driver/ppd/Canon-LBP-2900.ppd" /usr/share/cups/model/Canon-LBP-2900.ppd
    run install -Dm644 "$ROOT_DIR/open-driver/ppd/Canon-LBP-3000.ppd" /usr/share/cups/model/Canon-LBP-3000.ppd
    write_file /etc/udev/rules.d/99-canon-lbp-capt.rules 644 <<'RULE'
# Keep LBP2900 (04a9:2676) and LBP3000 (04a9:2678) out of USB autosuspend.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="04a9", ATTR{idProduct}=="2676", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="04a9", ATTR{idProduct}=="2678", TEST=="power/control", ATTR{power/control}="on"
RULE
    run udevadm control --reload-rules
    run systemctl restart cups
}

# open_configure MODEL NAME SERIAL
open_configure() {
    local model=$1 name=$2 serial=$3 ppd uri
    ppd=/usr/share/cups/model/$(open_ppd_for "$model") || die "open driver does not support $model"
    uri=$(lpinfo -v 2>/dev/null | awk -v m="usb://Canon/$(norm "$model")" '{u=$2; t=toupper(u); gsub(/%20|-/,"",t); if (index(t, toupper(m))==1) {print u; exit}}')
    [ -n "$uri" ] || uri="usb://Canon/${model}${serial:+?serial=$serial}"
    run lpadmin -p "$name" -E -v "$uri" -P "$ppd" -o printer-error-policy=abort-job
    ok "'$name' added ($uri)"
    echo "  Test page: lp -d $name /usr/share/cups/data/testprint"
}

open_uninstall() {
    local fdir; fdir="$(cups-config --serverbin 2>/dev/null || echo /usr/lib/cups)/filter"
    [ -e "$fdir/rastertocapt" ] || [ -e /usr/share/cups/model/Canon-LBP-3000.ppd ] || return 0
    info "Removing open-source driver"
    run lpadmin -x Canon-LBP2900 2>/dev/null || true
    run lpadmin -x LBP2900 2>/dev/null || true
    run lpadmin -x LBP3000 2>/dev/null || true
    run lpadmin -x Canon-LBP3000 2>/dev/null || true
    run rm -f "$fdir/rastertocapt" /usr/share/cups/model/Canon-LBP-2900.ppd /usr/share/cups/model/Canon-LBP-3000.ppd /etc/udev/rules.d/99-canon-lbp-capt.rules
}
