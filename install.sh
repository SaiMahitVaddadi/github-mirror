#!/usr/bin/env bash
# Symlink bin/mirror into a directory on $PATH.
#
# Override the target with BIN_DIR=~/.local/bin ./install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/bin/mirror"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
DST="$BIN_DIR/mirror"

if [[ ! -x "$SRC" ]]; then
  chmod +x "$SRC"
fi

mkdir -p "$BIN_DIR"

# If the destination is already a symlink to us, no-op.
if [[ -L "$DST" && "$(readlink "$DST")" == "$SRC" ]]; then
  echo "Already installed: $DST → $SRC"
  exit 0
fi

# If something else is at $DST, refuse unless --force.
if [[ -e "$DST" || -L "$DST" ]]; then
  if [[ "${1:-}" != "--force" ]]; then
    echo "Refusing to overwrite $DST. Re-run with --force, or remove it first." >&2
    exit 1
  fi
  rm -f "$DST"
fi

ln -s "$SRC" "$DST"
echo "Installed: $DST → $SRC"
echo
echo "Next: mirror init"
