# shellcheck shell=bash
# Canon proprietary CAPT driver (cndrvcups-common + cndrvcups-capt, v2.71).

CCPD_PORT_URI="ccp://localhost:59687"
CANON_SUPPORT_PAGE="https://asia.canon/en/support/0100459601"

canon_bits_dir() { [ "$ARCH" = amd64 ] && echo 64-bit_Driver || echo 32-bit_Driver; }

_find_debs() {  # _find_debs DIR -> sets COMMON_DEB / CAPT_DEB if found
    local d=$1
    [ -d "$d" ] || return 1
    COMMON_DEB=$(find "$d" -maxdepth 6 -name "cndrvcups-common_*_${ARCH}.deb" 2>/dev/null | sort | tail -1)
    CAPT_DEB=$(find "$d" -maxdepth 6 -name "cndrvcups-capt_*_${ARCH}.deb" 2>/dev/null | sort | tail -1)
    [ -n "$COMMON_DEB" ] && [ -n "$CAPT_DEB" ]
}

# _extract_archive FILE -> unpack into $WORK/extract/<n>, then look for the .debs (nested archives
# are unpacked one level deep). Supports .tar.gz/.tgz/.tar.xz/.tar.bz2/.tar and .zip.
_extract_archive() {
    local f=$1 dest depth=${2:-0}
    dest="$WORK/extract/$(basename "$f").$RANDOM"
    info "Unpacking $(basename "$f")"
    run mkdir -p "$dest"
    case "$f" in
        *.zip) run unzip -q -o "$f" -d "$dest" || return 1 ;;
        *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tar) run tar -xf "$f" -C "$dest" || return 1 ;;
        *) return 1 ;;
    esac
    [ "$DRY_RUN" = 1 ] && return 0
    _find_debs "$dest" && return 0
    if [ "$depth" -lt 1 ]; then       # archive inside the archive
        local inner
        while IFS= read -r inner; do
            _extract_archive "$inner" 1 && return 0
        done < <(find "$dest" -maxdepth 4 -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*.tar.xz' \) 2>/dev/null)
    fi
    return 1
}

# The driver is NEVER downloaded. It must be supplied next to this tool (same folder), either as the
# Canon archive (e.g. Linux_CAPT_PrinterDriver_V271_uk_EN.tar.gz / linux-capt-drv-v271-uken.tar.gz / .zip)
# or as the already unpacked cndrvcups-common/-capt .deb files. --driver-file / --driver-dir override.
canon_locate_driver() {
    COMMON_DEB=; CAPT_DEB=
    if [ -n "${DRIVER_FILE:-}" ]; then
        [ -f "$DRIVER_FILE" ] || die "--driver-file not found: $DRIVER_FILE"
        _extract_archive "$DRIVER_FILE" && return 0
        die "no cndrvcups .deb files for $ARCH found inside $DRIVER_FILE"
    fi
    local d dirs=("${DRIVER_DIR:-$ROOT_DIR}") f
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        if _find_debs "$d"; then ok "using driver packages found in $d"; return 0; fi
        while IFS= read -r f; do
            _extract_archive "$f" && { ok "using driver archive $(basename "$f")"; return 0; }
        done < <(find "$d" -maxdepth 1 -type f \( -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar.xz' -o -iname '*.tar.bz2' -o -iname '*.zip' \) 2>/dev/null | sort)
    done
    [ "$DRY_RUN" = 1 ] && { warn "no driver archive found in ${DRIVER_DIR:-$ROOT_DIR} (dry-run: continuing)"; return 0; }
    cat >&2 <<MSG

Canon's CAPT driver was not found next to this tool.
Put the driver archive you downloaded from Canon in the SAME FOLDER as canon-lbp-setup:
    ${DRIVER_DIR:-$ROOT_DIR}/
and run again. Expected: the Canon CAPT v2.71 archive (linux-capt-drv-v271-uken.tar.gz or
Linux_CAPT_PrinterDriver_V271_*.tar.gz, .zip also accepted), containing the cndrvcups-common
and cndrvcups-capt .deb files for $ARCH.
Canon's download page: $CANON_SUPPORT_PAGE
(Nothing is downloaded automatically.)
MSG
    return 1
}

canon_install_packages() {
    info "Installing cndrvcups-common and cndrvcups-capt"
    if [ "$DRY_RUN" != 1 ]; then
        [ -f "$COMMON_DEB" ] && [ -f "$CAPT_DEB" ] || die "driver packages missing"
    fi
    if run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$(readlink -f "${COMMON_DEB:-common.deb}")" "$(readlink -f "${CAPT_DEB:-capt.deb}")"; then
        ok "packages installed"; return 0
    fi
    warn "apt could not satisfy the packages' old dependency names; retrying with dpkg --force-depends"
    run dpkg -i --force-depends "$COMMON_DEB" "$CAPT_DEB" || die "dpkg failed to install the Canon packages"
    warn "installed with forced dependencies; run '$0 doctor' to check for missing libraries"
}

canon_find_ppd() {  # canon_find_ppd ppd_id -> path
    local id=$1 p
    for p in /usr/share/cups/model/CNCUPSLBP${id}CAPTK.ppd /usr/share/cups/model/CNCUPSLBP${id}CAPT?.ppd; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

CCPD_UNIT=canon-ccpd.service   # NOT "ccpd.service": Canon ships /etc/init.d/ccpd, and a same-named native unit
                               # makes `systemctl enable` fail ("Default-Start contains no runlevels").

canon_write_service() {
    write_file /etc/systemd/system/$CCPD_UNIT 644 <<'UNIT'
[Unit]
Description=Canon CAPT printer daemon (ccpd)
After=cups.service network.target
Wants=cups.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/start-stop-daemon --start --quiet --oknodo --exec /usr/sbin/ccpd
ExecStop=/sbin/start-stop-daemon --stop --quiet --oknodo --retry TERM/30/KILL/5 --exec /usr/sbin/ccpd

[Install]
WantedBy=multi-user.target
UNIT
    # clean up an earlier version of this tool / Canon's SysV script
    run rm -f /etc/systemd/system/ccpd.service
    run systemctl disable ccpd >/dev/null 2>&1 || true
    run systemctl daemon-reload
    run systemctl enable "$CCPD_UNIT"
}

canon_restart_ccpd() {
    # stop any ccpd started by Canon's package scripts before our unit takes over
    run start-stop-daemon --stop --quiet --oknodo --retry TERM/10/KILL/3 --exec /usr/sbin/ccpd
    run systemctl restart "$CCPD_UNIT"
}

# ---- 32-bit libxml2 -----------------------------------------------------------------------
# Canon's ccpd launches /usr/bin/captmon2 (or captmoncna*) = 32-bit monitor programs that need
# libxml2.so.2. Ubuntu 26.04 has no libxml2:i386, so without this ccpd runs as ONE process, the printer
# status is never read and jobs hang. We fetch libxml2 (+ICU) for i386 from Ubuntu's own 24.04 archive
# into a private folder and give only the captmon programs access to it through a wrapper.
COMPAT_DIR=/opt/canon-lbp-compat/lib32

_has_lib32() { ldconfig -p 2>/dev/null | grep -Eq "^[[:space:]]*$1 \(libc6\) "; }

fetch_compat_libs() {
    [ -e "$COMPAT_DIR/libxml2.so.2" ] && return 0
    info "Fetching 32-bit libxml2 from the Ubuntu 24.04 (noble) archive"
    local w="$WORK/compat" key=/usr/share/keyrings/ubuntu-archive-keyring.gpg
    [ -f "$key" ] || { warn "Ubuntu archive keyring not found ($key)"; return 1; }
    run mkdir -p "$w/debs" "$w/x" "$w/lists" "$w/cache"
    local o="deb [arch=i386 signed-by=$key]"
    write_file "$w/sources.list" 644 <<LIST
$o http://archive.ubuntu.com/ubuntu noble main
$o http://archive.ubuntu.com/ubuntu noble-updates main
$o http://security.ubuntu.com/ubuntu noble-security main
LIST
    local apt_o=(-o "Dir::Etc::sourcelist=$w/sources.list" -o Dir::Etc::sourceparts=/dev/null
                 -o "Dir::State::lists=$w/lists" -o "Dir::Cache=$w/cache" -o Acquire::Languages=none)
    run apt-get "${apt_o[@]}" update || { warn "could not read the Ubuntu 24.04 i386 package index"; return 1; }
    local pkgs=(libxml2:i386 libicu74:i386)
    _has_lib32 liblzma.so.5 || pkgs+=(liblzma5:i386)
    ( [ "$DRY_RUN" = 1 ] || cd "$w/debs" || exit 1; run apt-get "${apt_o[@]}" download "${pkgs[@]}" ) \
        || { warn "download of ${pkgs[*]} failed"; return 1; }
    run mkdir -p "$COMPAT_DIR"
    if [ "$DRY_RUN" != 1 ]; then
        local d
        for d in "$w"/debs/*.deb; do [ -e "$d" ] && dpkg-deb -x "$d" "$w/x"; done
        find "$w/x" \( -name 'libxml2.so.2*' -o -name 'libicu*.so.74*' -o -name 'liblzma.so.5*' \) \
            -exec cp -a {} "$COMPAT_DIR/" \;
        [ -e "$COMPAT_DIR/libxml2.so.2" ] || { warn "libxml2.so.2 not found in downloaded packages"; return 1; }
    fi
    ok "32-bit libxml2 installed in $COMPAT_DIR"
}

# canon_fix_captmon: wrap every 32-bit captmon* that cannot find libxml2.so.2
canon_fix_captmon() {
    local f need=0 fixed=0
    for f in /usr/bin/captmon*; do
        [ -f "$f" ] || continue
        case "$f" in *.real) continue ;; esac
        if file -b "$f" 2>/dev/null | grep -q 'ELF 32-bit' && ldd "$f" 2>&1 | grep -q 'libxml2.so.2 => not found'; then
            need=1
        fi
    done
    [ "$DRY_RUN" = 1 ] && need=1
    [ "$need" = 1 ] || { ok "captmon programs find all their libraries"; return 0; }
    fetch_compat_libs || { warn "Could not obtain 32-bit libxml2. Printing will hang until /usr/bin/captmon* can load libxml2.so.2 (i386)."; return 1; }
    for f in /usr/bin/captmon*; do
        [ -f "$f" ] || continue
        case "$f" in *.real) continue ;; esac
        file -b "$f" 2>/dev/null | grep -q 'ELF 32-bit' || continue
        ldd "$f" 2>&1 | grep -q 'libxml2.so.2 => not found' || continue
        run dpkg-divert --local --add --rename --divert "$f.real" "$f" >/dev/null
        write_file "$f" 755 <<WRAP
#!/bin/sh
# generated by canon-lbp-setup: gives Canon's 32-bit monitor a private libxml2.so.2
export LD_LIBRARY_PATH=$COMPAT_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec $f.real "\$@"
WRAP
        fixed=$((fixed+1))
    done
    ok "wrapped $fixed monitor program(s)"
}

# canon_configure MODEL NAME CONN(usb|net:IP) DEVNODE SERIAL
canon_configure() {
    local model=$1 name=$2 conn=$3 node=$4 serial=$5 ppd_id ppd dev
    ppd_id=$(model_field "$model" 2)
    ppd=$(canon_find_ppd "$ppd_id") || {
        [ "$DRY_RUN" = 1 ] && ppd=/usr/share/cups/model/CNCUPSLBP${ppd_id}CAPTK.ppd || \
        die "PPD for $model (CNCUPSLBP${ppd_id}CAPT*.ppd) is not in the installed Canon driver version"; }

    if [ "$conn" = usb ]; then
        dev=$node
        if [ -n "$serial" ]; then
            dev=/dev/canon$name
            write_file "/etc/udev/rules.d/85-canon-capt-$name.rules" 644 <<RULE
KERNEL=="lp[0-9]*", SUBSYSTEMS=="usb", ATTRS{idVendor}=="04a9", ATTRS{serial}=="$serial", SYMLINK+="canon$name"
RULE
            run udevadm control --reload-rules
            run udevadm trigger --subsystem-match=usbmisc --action=add || true
            run udevadm settle || true
            local i
            for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$dev" ] || [ "$DRY_RUN" = 1 ] && break; sleep 1; done
            if [ ! -e "$dev" ] && [ "$DRY_RUN" != 1 ]; then
                warn "$dev did not appear (turn the printer off and on once to apply the udev rule); using $node for now"
                dev=$node
            fi
        else
            warn "printer reports no USB serial number; using $dev directly (may change after replug)"
        fi
    else
        dev=$conn   # net:IP
    fi

    info "Registering '$name' with CUPS and ccpd"
    run systemctl restart cups
    run lpadmin -p "$name" -P "$ppd" -v "$CCPD_PORT_URI" -E
    run lpadmin -d "$name"
    run ccpdadmin -p "$name" -o "$dev"
    if [ "$DRY_RUN" != 1 ] && ! ccpdadmin 2>/dev/null | grep -q "$name"; then
        die "ccpdadmin did not register $name"
    fi

    # cupsd's AppArmor profile blocks the ccp:// / filter chain on some releases.
    if command -v aa-complain >/dev/null 2>&1 && [ -f /etc/apparmor.d/usr.sbin.cupsd ]; then
        run aa-complain /usr/sbin/cupsd >/dev/null 2>&1 || true
    fi

    canon_write_service
    canon_restart_ccpd
    ok "'$name' configured (device: $dev)"
    echo "  Status monitor:  captstatusui -P $name"
    echo "  Test page:       lp -d $name /usr/share/cups/data/testprint"
}

# Post-install verification: missing shared libraries, daemon, monitor, queue state.
canon_doctor() {
    local bad=0 f out
    info "Checking Canon driver binaries for missing libraries"
    for f in /usr/bin/captfilter /usr/bin/captdrv /usr/bin/captmon* /usr/sbin/ccpd \
             /usr/lib/cups/filter/pstocapt /usr/bin/captstatusui /usr/bin/cngplp; do
        [ -f "$f" ] || continue
        case "$f" in *.real) continue ;; esac
        if head -c2 "$f" | grep -q '#!'; then   # wrapper: check the real binary with the private path
            [ -f "$f.real" ] || continue
            out=$(LD_LIBRARY_PATH=$COMPAT_DIR ldd "$f.real" 2>&1 | grep -E 'not found' || true)
        else
            out=$(ldd "$f" 2>&1 | grep -E 'not found|not a dynamic' || true)
        fi
        if [ -n "$out" ]; then
            bad=1; warn "$f: $(printf '%s' "$out" | tr -s ' \t\n' ' ')"
        fi
    done
    [ $bad = 0 ] && ok "no missing libraries"
    if command -v pidof >/dev/null 2>&1; then
        local n=0 t
        for t in 1 2 3 4 5 6 7 8 9 10; do   # the monitor child needs a few seconds to appear
            n=$(pidof ccpd 2>/dev/null | wc -w); [ "$n" -ge 2 ] && break; sleep 1
        done
        if [ "$n" -ge 2 ]; then ok "ccpd running ($n processes: daemon + printer monitor)"
        else bad=1; warn "ccpd has $n process(es), expected 2. The monitor (captmon) is not running: run 'sudo $0 fix', then check 'journalctl -u $CCPD_UNIT' and /var/log/syslog"; fi
    fi
    command -v ccpdadmin >/dev/null && ccpdadmin 2>/dev/null | grep -E '^\s+\[' | sed 's/^/  ccpd: /'
    command -v lpstat >/dev/null && lpstat -p 2>/dev/null | sed 's/^/  cups: /'
    lpstat -v 2>/dev/null | grep -i 'usb://Canon' | sed 's/^/  note: extra USB queue (can conflict with ccpd): /' || true
    return $bad
}

canon_uninstall() {
    info "Removing Canon CAPT driver and printers"
    local n
    if command -v ccpdadmin >/dev/null 2>&1; then
        for n in $(ccpdadmin 2>/dev/null | grep LBP | awk '{print $3}'); do
            run killall captstatusui 2>/dev/null || true
            run ccpdadmin -x "$n" || true
            run lpadmin -x "$n" || true
        done
    fi
    run systemctl disable --now "$CCPD_UNIT" 2>/dev/null || true
    run systemctl disable --now ccpd 2>/dev/null || true
    local f
    for f in /usr/bin/captmon*.real; do      # undo the libxml2 wrappers
        [ -f "$f" ] || continue
        run rm -f "${f%.real}"
        run dpkg-divert --local --remove --rename "${f%.real}" >/dev/null 2>&1 || true
    done
    run rm -rf /opt/canon-lbp-compat
    run rm -f /etc/systemd/system/$CCPD_UNIT /etc/systemd/system/ccpd.service /etc/udev/rules.d/85-canon-capt-*.rules
    run systemctl daemon-reload
    dpkg -s cndrvcups-capt >/dev/null 2>&1 && run dpkg --purge cndrvcups-capt
    dpkg -s cndrvcups-common >/dev/null 2>&1 && run dpkg --purge cndrvcups-common
    run udevadm control --reload-rules
}
