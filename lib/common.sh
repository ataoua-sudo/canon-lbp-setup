# shellcheck shell=bash
# Common helpers: logging, dry-run, OS detection.

C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
[ -t 1 ] || { C_RED=; C_GRN=; C_YEL=; C_BLU=; C_RST=; }

info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s ok%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%swarn:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}

# run CMD...  -- executes, or only prints when --dry-run
run() {
    if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; return 0; fi
    "$@"
}

# write_file PATH MODE  (content on stdin)
write_file() {
    local path=$1 mode=${2:-644}
    if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] write %s (mode %s)\n' "$path" "$mode"; cat >/dev/null; return 0; fi
    mkdir -p "$(dirname "$path")"
    cat >"$path" && chmod "$mode" "$path"
}

ask_yes_no() {  # ask_yes_no "question" default(y|n)
    local q=$1 def=${2:-y} ans
    [ "$ASSUME_YES" = 1 ] && return 0
    [ -t 0 ] || { [ "$def" = y ]; return; }
    read -r -p "$q [$([ "$def" = y ] && echo Y/n || echo y/N)] " ans
    ans=${ans:-$def}
    [[ $ans =~ ^[Yy] ]]
}

detect_os() {
    OS_ID=unknown; OS_VER=0; OS_LIKE=; OS_CODENAME=
    if [ -r "${OS_RELEASE:-/etc/os-release}" ]; then
        # shellcheck disable=SC1090
        . "${OS_RELEASE:-/etc/os-release}"
        OS_ID=${ID:-unknown}; OS_VER=${VERSION_ID:-0}; OS_LIKE=${ID_LIKE:-}; OS_CODENAME=${VERSION_CODENAME:-}
    fi
    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64 ;;
        i?86)         ARCH=i386 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *)            ARCH=$(uname -m) ;;
    esac
}

# Ubuntu 16.04 .. 26.04 (LTS and interim). Other Debian-likes only with --force.
check_os_supported() {
    detect_os
    if [ "$OS_ID" = ubuntu ]; then
        local major=${OS_VER%%.*}
        if [ "$major" -lt 16 ] 2>/dev/null; then
            [ "${FORCE:-0}" = 1 ] || die "Ubuntu $OS_VER is older than 16.04 (use --force to try anyway)"
        fi
        if [ "$major" -gt 26 ] 2>/dev/null; then
            warn "Ubuntu $OS_VER is newer than the newest release this tool was written for (26.04)."
        fi
        case "$OS_VER" in 16.04|18.04|20.04|22.04|24.04|26.04) ;; *) warn "Ubuntu $OS_VER is an interim/untested release; continuing." ;; esac
    elif [[ " $OS_ID $OS_LIKE " == *" ubuntu "* || " $OS_ID $OS_LIKE " == *" debian "* ]]; then
        warn "$OS_ID ($OS_VER) is Debian/Ubuntu-based but not Ubuntu; behaviour is untested."
    else
        [ "${FORCE:-0}" = 1 ] || die "Unsupported OS '$OS_ID'. This tool targets Ubuntu (16.04-26.04). Use --force to try anyway."
    fi
    ok "OS: $OS_ID $OS_VER ($ARCH)"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || [ "$DRY_RUN" = 1 ] || die "Run as root: sudo $0 $*"
}
