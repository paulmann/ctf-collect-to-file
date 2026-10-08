#!/usr/bin/env bash
###############################################################################
# install.sh — установка ctf.
#
#   ./install.sh                          # в ~/.local/bin
#   ./install.sh --prefix /usr/local      # системная установка (нужен root)
#   ./install.sh --dry-run                # показать действия, ничего не менять
#   ./install.sh --uninstall              # удалить
#   ./install.sh --prefix /opt/ctf --bindir /opt/ctf/bin
#
# Установщик намеренно не использует make: он обязан работать там, где make нет.
# Код возврата: 0 успех, 2 ошибка аргументов, 1 ошибка выполнения.
###############################################################################
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR=''
DRY_RUN=0
DO_UNINSTALL=0
# ctf.sh ставится также под коротким именем `ctf`.
LINK_NAME='ctf'

die() { printf '%s\n' "install: $*" >&2; exit "${2:-1}"; }
say() { printf '%s\n' "$*"; }
# Никакого eval: команда передаётся массивом аргументов и исполняется напрямую.
run() { if (( DRY_RUN )); then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() {
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while (( $# > 0 )); do
    case "$1" in
        --prefix)    PREFIX="${2:?--prefix requires a value}"; shift 2 ;;
        --prefix=*)  PREFIX="${1#*=}"; shift ;;
        --bindir)    BINDIR="${2:?--bindir requires a value}"; shift 2 ;;
        --bindir=*)  BINDIR="${1#*=}"; shift ;;
        --dry-run|-n) DRY_RUN=1; shift ;;
        --uninstall|-u) DO_UNINSTALL=1; shift ;;
        -h|--help)   usage ;;
        *)           die "unknown option: $1 (see --help)" 2 ;;
    esac
done

[[ -n "$BINDIR" ]] || BINDIR="$PREFIX/bin"
DEST="$BINDIR/$LINK_NAME"

# --- uninstall ---------------------------------------------------------------
if (( DO_UNINSTALL )); then
    for f in "$DEST" "$BINDIR/ctf.sh" "$BINDIR/ctf.ps1" "$BINDIR/ctf.bat" "$BINDIR/VERSION"; do
        if [[ -e "$f" || -L "$f" ]]; then say "removing $f"; run rm -f -- "$f"; fi
    done
    say "uninstall complete"
    exit 0
fi

# --- проверка источника ------------------------------------------------------
[[ -f "$SRC_DIR/ctf.sh" ]] || die "ctf.sh not found next to install.sh ($SRC_DIR)" 1
if command -v bash >/dev/null 2>&1; then
    bash -n "$SRC_DIR/ctf.sh" || die "ctf.sh fails 'bash -n' — refusing to install" 1
fi
version="$(awk -F"'" '/^readonly CTF_SCRIPT_VERSION=/{print $2; exit}' "$SRC_DIR/ctf.sh")"
[[ -n "$version" ]] || die "cannot determine the version from ctf.sh" 1

say "ctf v${version}"
say "  source : $SRC_DIR"
say "  bindir : $BINDIR"
(( DRY_RUN )) && say "  (dry run — nothing will be changed)"

if (( ! DRY_RUN )); then
    [[ -d "$BINDIR" ]] || mkdir -p -- "$BINDIR" || die "cannot create $BINDIR" 1
    [[ -w "$BINDIR" ]] || die "$BINDIR is not writable (try --prefix \$HOME/.local)" 1
fi

# --- установка ---------------------------------------------------------------
# ctf.sh -> bin/ctf (основное имя) и bin/ctf.sh (для явных вызовов).
run cp -f -- "$SRC_DIR/ctf.sh" "$BINDIR/ctf.sh"
run chmod 0755 -- "$BINDIR/ctf.sh"
run ln -sf -- "ctf.sh" "$DEST"
for f in ctf.ps1 ctf.bat VERSION; do
    [[ -f "$SRC_DIR/$f" ]] || continue
    run cp -f -- "$SRC_DIR/$f" "$BINDIR/$f"
    run chmod 0644 -- "$BINDIR/$f"
done

# --- PATH --------------------------------------------------------------------
case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *)
        say ""
        say "  $BINDIR is not in PATH. Add it to your shell profile:"
        say "    export PATH=\"$BINDIR:\$PATH\""
        ;;
esac

say ""
say "installed. Verify with:  $DEST --version"
