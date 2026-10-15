#!/usr/bin/env bash
# Packages a built begonia kernel into an AnyKernel3 flashable zip.
# Layout, device config and tool set follow POX-project/pox-begonia-kernel.
#
# Payload format: Image.gz-dtb = gzip(Image) followed by the begonia DTB(s)
# appended raw after the gzip stream, matching ak3-core's write path.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AK3="${AK3:-$here/anykernel3}"
OUTDIR="${OUTDIR:-$here/out}"
BRANCH="${BRANCH:-7.1}"
PANEL="${PANEL:-all}"
KTITLE="${KTITLE:-mt6785-begonia}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }

[ $# -gt 0 ] && BRANCH="$1"
[ $# -gt 1 ] && PANEL="$2"

case "$PANEL" in all|csot|tianma) ;; *) die "panel must be all, csot or tianma" ;; esac

src="$OUTDIR/$BRANCH"
img="$src/Image"
zip_out="$OUTDIR/$KTITLE-$BRANCH-AnyKernel3.zip"

[ -d "$AK3" ] || die "missing AnyKernel3 assets: $AK3"
[ -f "$AK3/META-INF/com/google/android/update-binary" ] || die "missing update-binary in $AK3"
[ -f "$AK3/tools/ak3-core.sh" ] || die "missing tools/ak3-core.sh in $AK3"
[ -s "$img" ] || die "no kernel Image at $img (build first)"

# 7.1 has one DTB per panel (csot/tianma); 6.16 has a single un-suffixed DTB.
collect_dtbs() {
  local p f=()
  shopt -s nullglob
  for p in "$src"/mt6785-xiaomi-begonia*.dtb; do
    [ -s "$p" ] || continue
    f+=("$p")
  done
  shopt -u nullglob
  [ "${#f[@]}" -gt 0 ] || return 1
  if [ "$PANEL" != "all" ]; then
    local want="$src/mt6785-xiaomi-begonia-$PANEL.dtb"
    [ -s "$want" ] || return 1
    printf '%s\n' "$want"
    return 0
  fi
  printf '%s\n' "${f[@]}"
}

DTBS=()
while IFS= read -r line; do DTBS+=("$line"); done < <(collect_dtbs) || true
[ "${#DTBS[@]}" -gt 0 ] ||
  die "no begonia DTB in $src (looked for mt6785-xiaomi-begonia*.dtb)"

if [ "$PANEL" = "all" ] && [ "${#DTBS[@]}" -gt 1 ]; then
  info "including all ${#DTBS[@]} begonia DTBs; bootloader selects by compatible"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp -r "$AK3/META-INF" "$work/"
cp -r "$AK3/tools"  "$work/"
for d in ramdisk modules patch; do
  [ -d "$AK3/$d" ] && cp -r "$AK3/$d" "$work/"
done

# gzip the Image, then append the DTB(s) raw after the gzip stream
gzip -9 -c "$img" > "$work/Image.gz-dtb"
for d in "${DTBS[@]}"; do
  cat "$d" >> "$work/Image.gz-dtb"
  ok "appended $(basename "$d")"
done

labels=""
for d in "${DTBS[@]}"; do
  b="$(basename "$d" .dtb)"; labels+="${b#mt6785-xiaomi-} "
done

ver="$(make -s -C "$here" ARCH=arm64 O="$src/kernel" kernelversion 2>/dev/null || echo "$BRANCH")"
stamp="$(date -u '+%Y-%m-%d %H:%M') UTC"

cat > "$work/anykernel.sh" <<AKSCRIPT
properties() { '
kernel.string=MT6785 mainline $BRANCH for Xiaomi Redmi Note 8 Pro (begonia)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=begonia
device.name2=begonia_in
device.name3=begoniain
supported.versions=
supported.patchlevels=
'; } # end properties

# begonia is non-A/B ("A-only"); matches POX-project/pox-begonia-kernel
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

ui_print " ";
ui_print " ============================================";
ui_print "   MT6785 MAINLINE KERNEL $BRANCH";
ui_print " ============================================";
ui_print "  * Device      : Xiaomi Redmi Note 8 Pro (begonia)";
ui_print "  * Branch      : $BRANCH";
ui_print "  * Linux Ver   : $ver";
ui_print "  * Build Date  : $stamp";
ui_print "  * Partition   : /dev/block/by-name/boot (A-only)";
ui_print "  * Device trees: $labels";
ui_print " --------------------------------------------";
ui_print " ";
ui_print " [*] Dumping and unpacking current boot image...";
dump_boot;
ui_print " [*] Writing kernel and device trees...";
write_boot;
ui_print " ";
ui_print " ============================================";
ui_print "   Done. Reboot to apply.";
ui_print " ============================================";
ui_print " ";
AKSCRIPT

chmod +x "$work/META-INF/com/google/android/update-binary" "$work/tools/"* 2>/dev/null || true

rm -f "$zip_out"
( cd "$work" && zip -r9X "$zip_out" META-INF tools anykernel.sh Image.gz-dtb \
    ramdisk modules patch -x '.*' >/dev/null )

ok "$(basename "$zip_out") ($(du -h "$zip_out" | cut -f1))"
info "$zip_out"