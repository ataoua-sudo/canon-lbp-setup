# shellcheck shell=bash
# Prerequisite installation. Always runs first, before detection or driver work.

apt_install() { run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

pkg_candidate() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}'; }
pkg_available() {
    [ "$DRY_RUN" = 1 ] && return 0
    local c; c=$(pkg_candidate "$1"); [ -n "$c" ] && [ "$c" != "(none)" ]
}
# install_first_available alt1 alt2 ...   (handles t64 / soname renames between releases)
install_first_available() {
    local p
    for p in "$@"; do
        if pkg_available "$p"; then apt_install "$p" && return 0; fi
    done
    return 1
}

install_base_deps() {
    info "Installing base prerequisites (CUPS, tools)"
    run apt-get update || warn "apt-get update reported errors; continuing"
    apt_install cups cups-client ghostscript ca-certificates tar gzip unzip xz-utils file binutils udev \
        || die "could not install base packages (cups, cups-client, ...)"
    run systemctl enable --now cups 2>/dev/null || true
    ok "base prerequisites installed"
}

# 32-bit support needed by Canon's proprietary binaries (captfilter, captdrv, captmon*).
# Returns 1 when the essential libraries cannot be installed (caller may fall back to the open driver).
install_canon_deps() {
    info "Installing prerequisites for Canon's CAPT driver"
    if [ "$ARCH" != amd64 ] && [ "$ARCH" != i386 ]; then
        warn "Canon's proprietary driver only exists for x86 (this is $ARCH)"; return 1
    fi

    if [ "$ARCH" = amd64 ]; then
        if ! dpkg --print-foreign-architectures | grep -qx i386; then
            info "Enabling i386 multiarch"
            run dpkg --add-architecture i386
        fi
        run apt-get update || warn "apt-get update reported errors"
        local essential=(libc6:i386 libpopt0:i386) optional=(libstdc++6:i386 zlib1g:i386) p missing=()
        for p in "${essential[@]}"; do
            if pkg_available "$p"; then apt_install "$p" || missing+=("$p"); else missing+=("$p"); fi
        done
        if [ ${#missing[@]} -gt 0 ]; then
            warn "essential 32-bit libraries unavailable in this release's archive: ${missing[*]}"
            return 1
        fi
        for p in "${optional[@]}"; do
            pkg_available "$p" && apt_install "$p" || warn "optional 32-bit library not available: $p (status monitor may not work)"
        done
        install_first_available libgcc-s1:i386 libgcc1:i386 || true
        # libxml2:i386 is needed by Canon's captmon* (printer monitor). Missing on Ubuntu 26.04: handled by
        # canon_fix_captmon after the driver is installed.
        pkg_available libxml2:i386 && apt_install libxml2:i386 || \
            info "libxml2:i386 is not in this release's archive; a compatible copy will be set up for Canon's monitor program"
    fi

    # 64-bit GUI/daemon libs used by captstatusui and cngplp (package names differ per release)
    install_first_available libglade2-0 || warn "libglade2-0 not available; cngplp settings UI will not start"
    install_first_available libgtk2.0-0t64 libgtk2.0-0 || warn "GTK2 not available; captstatusui will not start"
    install_first_available libatk1.0-0t64 libatk1.0-0 || true
    install_first_available libpopt0 || true
    install_first_available libxml2 || true
    install_first_available libcanberra-gtk-module || true
    install_first_available apparmor-utils || true
    ok "Canon driver prerequisites done"
}

# Prerequisites for compiling the bundled open-source driver.
install_open_deps() {
    info "Installing build prerequisites for the open-source driver"
    apt_install build-essential autoconf automake libcups2-dev \
        || die "could not install build dependencies"
}
