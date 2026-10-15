#!/usr/bin/env bash
# Builds the Android 16 GKI kernel (aosp-mirror/kernel_common, android16-6.12).
# The GitHub mirror has no Kleaf, so this uses the classic gki_defconfig path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${TREE:-$SCRIPT_DIR/gki-android16-6.12}"
OUTDIR="${OUTDIR:-$SCRIPT_DIR/out-gki}"
JOBS="${JOBS:-$(nproc)}"
TARGETS="${TARGETS:-Image}"
USE_CCACHE="${USE_CCACHE:-1}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: build-gki.sh [options]

Builds the Android 16 GKI kernel from aosp-mirror/kernel_common (android16-6.12).

Options:
  -j N          parallel jobs (default: nproc)
  --targets T   make targets (default: Image)
                e.g. --targets "Image modules"
  --out DIR     output root (default: <script dir>/out-gki)
  -h, --help    this text

Environment:
  TREE          kernel source tree
  USE_CCACHE    set to 0 to bypass ccache
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ "$JOBS" -gt 0 ] 2>/dev/null || die "invalid job count: $JOBS"
[ -f "$TREE/Makefile" ] || die "no kernel tree at $TREE (set TREE)"
command -v clang >/dev/null 2>&1 || die "clang not found (install clang lld)"
[ "$JOBS" -lt 5 ] || info "note: GKI is sensitive to job count; -j$JOBS on a small VM can exhaust RAM"

CACHE_PREFIX=""
if [ "$USE_CCACHE" != "0" ] && command -v ccache >/dev/null 2>&1; then
  CACHE_PREFIX="ccache "
fi

kdir="$OUTDIR/kernel"
mkdir -p "$kdir"

# The kernel honours LLVM=<prefix> or LLVM=-<suffix>; the suffix form wires up
# both target and HOST* tools consistently, which matters on Debian/Ubuntu where
# LLVM binutils ship versioned (llvm-ar-18) with no unversioned alias.
CLANG_MAJOR="$(clang --version | sed -n 's/.*version \([0-9][0-9]*\).*/\1/p' | head -1)"
if [ -n "$CLANG_MAJOR" ] && command -v "clang-$CLANG_MAJOR" >/dev/null 2>&1 &&
   command -v "llvm-ar-$CLANG_MAJOR" >/dev/null 2>&1; then
  LLVM_ARG="-$CLANG_MAJOR"
else
  LLVM_ARG=1
fi

make_args=(ARCH=arm64 "LLVM=$LLVM_ARG" O="$kdir" CROSS_COMPILE=aarch64-linux-gnu-)
[ -n "$CACHE_PREFIX" ] && make_args+=(CC="$CACHE_PREFIX clang-$CLANG_MAJOR")

# CONFIG_GENDWARFKSYMS=y in gki_defconfig; its host tool includes <dwarf.h>,
# which Debian ships under /usr/include/libdwarf. HOST_EXTRACFLAGS is the
# kernel's supported hook for host-tool include paths.
EXTRAC=""
if [ -f /usr/include/libdwarf/dwarf.h ] && [ ! -f /usr/include/dwarf.h ]; then
  EXTRAC="-I/usr/include/libdwarf"
  info "gendwarfksyms: adding $EXTRAC"
fi
[ -n "$EXTRAC" ] && make_args+=(HOST_EXTRACFLAGS="$EXTRAC")

ver=$(make -s -C "$TREE" "${make_args[@]}" kernelversion 2>/dev/null || echo "?")
info "tree    : $TREE"
info "version : $ver"
info "targets : $TARGETS"
info "jobs    : $JOBS"
[ -n "$CACHE_PREFIX" ] && info "ccache  : enabled" || info "ccache  : disabled"

info "configuring gki_defconfig"
make -C "$TREE" "${make_args[@]}" gki_defconfig

info "building with -j$JOBS"
make -C "$TREE" "${make_args[@]}" -j"$JOBS" $TARGETS

mkdir -p "$OUTDIR"
for f in Image Image.lz4 System.map vmlinux; do
  [ -f "$kdir/arch/arm64/boot/$f" ] && cp -f "$kdir/arch/arm64/boot/$f" "$OUTDIR/" && ok "$f"
done
[ -f "$kdir/vmlinux" ] && cp -f "$kdir/vmlinux" "$OUTDIR/" 2>/dev/null || true
[ -f "$kdir/System.map" ] && cp -f "$kdir/System.map" "$OUTDIR/" 2>/dev/null || true
[ -f "$kdir/.config" ] && cp -f "$kdir/.config" "$OUTDIR/gki.config"
[ -d "$kdir/lib/modules" ] && cp -f -r "$kdir/lib/modules" "$OUTDIR/" 2>/dev/null || true

command -v ccache >/dev/null 2>&1 && ccache -s 2>/dev/null | grep -E "Hits|Misses" | sed 's/^/      /' || true

info "GKI $ver artifacts in $OUTDIR"
[ -s "$OUTDIR/Image" ] || die "no Image produced"
ok "GKI Image: $(du -h "$OUTDIR/Image" | cut -f1)"