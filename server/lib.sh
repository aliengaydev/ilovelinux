#!/usr/bin/env bash
# Спільні функції для скриптів розгортання. Підключати: source "$(dirname "$0")/lib.sh"
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$REPO/server"
# shellcheck source=lab.env
source "$SRV/lab.env"

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m OK\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31mERR\e[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "запускати через sudo: sudo $0"; }

# install_cfg <шлях у репо відносно server/> <ціль> [режим]
install_cfg() { install -D -m "${3:-0644}" -o root -g root "$SRV/$1" "$2"; }

# Пароль для нового облікового запису: генерується один раз і зберігається лише для root
PASSFILE=/root/lab-initial-passwords
gen_pass() { head -c 18 /dev/urandom | base64 | tr -d '/+=' ; }
set_initial_password() {
  local u=$1 p
  if ! grep -q "^$u:" "$PASSFILE" 2>/dev/null; then
    p=$(gen_pass); echo "$u:$p" | chpasswd
    install -m 600 /dev/null "$PASSFILE.tmp"; { cat "$PASSFILE" 2>/dev/null || true; echo "$u:$p"; } > "$PASSFILE.tmp"
    mv "$PASSFILE.tmp" "$PASSFILE"; chmod 600 "$PASSFILE"
  fi
}
