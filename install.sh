#!/usr/bin/env bash
# install.sh - install (or upgrade) muster on Linux and macOS.
#
# muster resolves its own library tree from the entrypoint's location, even
# through a symlink, so the install model is: copy the tree into a library
# directory and symlink the `muster` entrypoint onto your PATH. Re-running this
# script upgrades an existing install in place (it refreshes the tree and the
# symlink), and --uninstall removes everything it created.
#
# Defaults to a per-user install (no sudo):
#   libdir  ${XDG_DATA_HOME:-~/.local/share}/muster
#   bindir  ~/.local/bin
#
# Overrides:
#   PREFIX=/usr/local ./install.sh        # system-wide (bindir/libdir/share)
#   BINDIR=~/bin LIBDIR=~/opt/muster ./install.sh
#   ./install.sh --uninstall
set -eu

SRC="$(cd -P "$(dirname "$0")" && pwd)"
COMPONENTS="muster lib drivers docker completions LICENSE README.md"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
if [ -n "${PREFIX:-}" ]; then
  BINDIR="${BINDIR:-$PREFIX/bin}"
  LIBDIR="${LIBDIR:-$PREFIX/lib/muster}"
  BASHCOMP="${BASHCOMP:-$PREFIX/share/bash-completion/completions}"
  ZSHCOMP="${ZSHCOMP:-$PREFIX/share/zsh/site-functions}"
else
  BINDIR="${BINDIR:-$HOME/.local/bin}"
  LIBDIR="${LIBDIR:-$DATA_HOME/muster}"
  BASHCOMP="${BASHCOMP:-$DATA_HOME/bash-completion/completions}"
  ZSHCOMP="${ZSHCOMP:-$DATA_HOME/zsh/site-functions}"
fi

say() { printf '%s\n' "$*"; }
die() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

uninstall() {
  if [ -L "$BINDIR/muster" ]; then
    target="$(readlink "$BINDIR/muster")"
    case "$target" in
      "$LIBDIR/muster") rm -f "$BINDIR/muster" && say "removed $BINDIR/muster" ;;
      *) say "left $BINDIR/muster (points elsewhere: $target)" ;;
    esac
  fi
  [ -d "$LIBDIR" ] && rm -rf "$LIBDIR" && say "removed $LIBDIR"
  [ -e "$BASHCOMP/muster" ] && rm -f "$BASHCOMP/muster" && say "removed $BASHCOMP/muster"
  [ -e "$ZSHCOMP/_muster" ] && rm -f "$ZSHCOMP/_muster" && say "removed $ZSHCOMP/_muster"
  say "muster uninstalled."
  exit 0
}

case "${1:-}" in
  --uninstall) uninstall ;;
  -h | --help)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *) die "unknown argument: $1 (try --help)" ;;
esac

[ -f "$SRC/muster" ] && [ -d "$SRC/lib" ] || die "run this from a muster checkout (missing muster/ lib/)"

say "installing muster"
say "  from: $SRC"
say "  lib:  $LIBDIR"
say "  bin:  $BINDIR/muster"

mkdir -p "$LIBDIR" "$BINDIR"

# Refresh the managed components so an upgrade never leaves stale files behind.
for item in $COMPONENTS; do
  [ -e "$SRC/$item" ] || continue
  rm -rf "${LIBDIR:?}/$item"
  cp -R "$SRC/$item" "$LIBDIR/$item"
done
chmod +x "$LIBDIR/muster"

ln -sf "$LIBDIR/muster" "$BINDIR/muster"

# Completions are best-effort: install them, but never fail the run over them.
if mkdir -p "$BASHCOMP" 2>/dev/null && cp "$SRC/completions/muster.bash" "$BASHCOMP/muster" 2>/dev/null; then
  say "  bash completion: $BASHCOMP/muster"
fi
if mkdir -p "$ZSHCOMP" 2>/dev/null && cp "$SRC/completions/_muster" "$ZSHCOMP/_muster" 2>/dev/null; then
  say "  zsh completion:  $ZSHCOMP/_muster"
fi

say "done. muster $("$LIBDIR/muster" version 2>/dev/null | awk '{print $2}')"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *)
    say ""
    say "note: $BINDIR is not on your PATH. Add it, e.g.:"
    say "  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.profile"
    ;;
esac
