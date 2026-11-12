#!/bin/bash
# =============================================================================
#  tools/build_channel_a.sh
#  ?? A(???)???? -- ? Dopamine ????????,??????? IPA?
#
#  ??(??? src/channel_a/,????? Resources -- ??????????????):
#    libjailbreak.dylib / libchoma.dylib / libxpf.dylib
#    kfd.framework / weightBufs.framework / multicast_bytecopy.framework
#    dmaFail.framework / badRecovery.framework
#    ClearSword.framework / DarkSword.framework / Titan.framework / momentarius.framework
#
#  ??(??? macOS + Xcode ??):
#      bash tools/build_channel_a.sh
#      bash tools/build_channel_a.sh --clean     # ????????
#
#  ??:
#    - BaseBin ?? libjailbreak / libxpf / libchoma(Dopamine ???????)
#    - 9 ? exploit ? Dopamine.xcodeproj ?? framework target,???
#      Application/Dopamine/Exploits/<name>/
#    - ????? install_name,????????:
#         App.app/libjailbreak.dylib
#         App.app/libchoma.dylib
#         App.app/Frameworks/libxpf.dylib
#         App.app/Frameworks/<exploit>.framework
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DOPAMINE="$ROOT/upstream/Dopamine"
BASEBIN="$DOPAMINE/BaseBin"
PROJ="$DOPAMINE/Application/Dopamine.xcodeproj"
OUT="$ROOT/src/channel_a"
BUILDDIR="$ROOT/.build/channel_a"

EXPLOITS=(kfd weightBufs multicast_bytecopy dmaFail badRecovery ClearSword DarkSword Titan momentarius)

log() { echo "==> $*"; }
die() { echo "??: $*" >&2; exit 1; }

# ---------- ???? ----------
[ "$(uname -s)" = "Darwin" ] || die "??? macOS ???(?? $(uname -s))"
command -v xcodebuild >/dev/null || die "? xcodebuild,?? Xcode ?????"
command -v xcrun      >/dev/null || die "? xcrun"
command -v ldid       >/dev/null || echo "??: ???? ldid(BaseBin ???????,brew install ldid)"
[ -d "$PROJ" ]  || die "??? Dopamine.xcodeproj: $PROJ(?? ???/_fetch.sh)"
[ -d "$BASEBIN" ] || die "??? BaseBin: $BASEBIN"
[ -d "$BASEBIN/_external/include" ] || die "BaseBin/_external ???(Dopamine ?????)"
if ! brew --prefix libarchive >/dev/null 2>&1; then
    echo "??: ???? brew libarchive,libjailbreak ?????(brew install libarchive)"
fi

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$OUT" "$BUILDDIR" "$BASEBIN/.build" "$BASEBIN/.include"
    log "??????"
fi

mkdir -p "$OUT" "$BUILDDIR"

# ---------- 1. BaseBin:libchoma / libxpf / libjailbreak ----------
log "?? BaseBin(libchoma / libxpf / libjailbreak)"
make -C "$BASEBIN" ChOma XPF libjailbreak

for f in libchoma.dylib libxpf.dylib libjailbreak.dylib; do
    [ -f "$BASEBIN/.build/$f" ] || die "BaseBin ??? $f"
    cp -f "$BASEBIN/.build/$f" "$OUT/$f"
    echo "    $f  $(du -h "$OUT/$f" | cut -f1)"
done

# ---------- 2. 9 ? exploit framework ----------
log "?? exploit framework(${#EXPLOITS[@]} ?)"
failed=()
for name in "${EXPLOITS[@]}"; do
    src="$DOPAMINE/Application/Dopamine/Exploits/$name"
    [ -d "$src" ] || { echo "    ??(?????): $name"; continue; }
    [ -f "$src/Info.plist" ] || { echo "    ??(? Info.plist): $name"; continue; }

    echo "    ---- $name"
    if ! xcodebuild -project "$PROJ" \
            -target "$name" \
            -configuration Release \
            -sdk iphoneos \
            -derivedDataPath "$BUILDDIR" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
            build > "$BUILDDIR/$name.log" 2>&1; then
        echo "    ????,??: $BUILDDIR/$name.log"
        failed+=("$name")
        continue
    fi
    fw="$(find "$BUILDDIR/Build/Products/Release-iphoneos" -maxdepth 1 -name "$name.framework" -print -quit)"
    if [ -z "$fw" ]; then
        fw="$(find "$BUILDDIR/Build/Products" -name "$name.framework" -print -quit)"
    fi
    [ -n "$fw" ] || { echo "    ??? $name.framework"; failed+=("$name"); continue; }

    rm -rf "$OUT/$name.framework"
    cp -R "$fw" "$OUT/"
    echo "    ??: $OUT/$name.framework"
done

if [ ${#failed[@]} -gt 0 ]; then
    echo ""
    echo "??: ?? exploit ????: ${failed[*]}"
    echo "      ???????;?? .build/channel_a/<name>.log"
fi

# ---------- 3. ??? install_name(??????????) ----------
log "?? install_name"
if command -v install_name_tool >/dev/null; then
    # ? dylib ? App ???
    install_name_tool -id "@executable_path/libjailbreak.dylib" "$OUT/libjailbreak.dylib" 2>/dev/null || true
    install_name_tool -id "@executable_path/libchoma.dylib"     "$OUT/libchoma.dylib"     2>/dev/null || true
    # libjailbreak ?? libchoma
    choma_old="$(otool -L "$OUT/libjailbreak.dylib" 2>/dev/null | awk '/libchoma/{print $1; exit}')"
    if [ -n "${choma_old:-}" ] && [ "$choma_old" != "@executable_path/libchoma.dylib" ]; then
        install_name_tool -change "$choma_old" "@executable_path/libchoma.dylib" "$OUT/libjailbreak.dylib"
    fi
    # libxpf ? Frameworks
    install_name_tool -id "@executable_path/Frameworks/libxpf.dylib" "$OUT/libxpf.dylib" 2>/dev/null || true

    # ?? framework:? libjailbreak ????? @executable_path/libjailbreak.dylib
    for fw in "$OUT"/*.framework; do
        [ -d "$fw" ] || continue
        bin="$fw/$(basename "$fw" .framework)"
        [ -f "$bin" ] || continue
        old="$(otool -L "$bin" 2>/dev/null | awk '/libjailbreak/{print $1; exit}')"
        if [ -n "${old:-}" ] && [ "$old" != "@executable_path/libjailbreak.dylib" ]; then
            install_name_tool -change "$old" "@executable_path/libjailbreak.dylib" "$bin"
            echo "    $(basename "$fw"): $old -> @executable_path/libjailbreak.dylib"
        fi
        # ??? rpath:?? @executable_path/Frameworks ??
        install_name_tool -add_rpath "@executable_path/Frameworks" "$bin" 2>/dev/null || true
    done
else
    echo "    ? install_name_tool,??(??????)"
fi

# ---------- 4. ?? ----------
log "ad-hoc ??"
if command -v ldid >/dev/null; then
    for f in "$OUT"/*.dylib; do [ -f "$f" ] && ldid -Cadhoc -s "$f"; done
    for fw in "$OUT"/*.framework; do
        [ -d "$fw" ] || continue
        bin="$fw/$(basename "$fw" .framework)"
        [ -f "$bin" ] && ldid -Cadhoc -S "$bin"
    done
    echo "    ldid ??"
else
    echo "    ? ldid,??(Xcode ?????????)"
fi

# ---------- 5. ?? ----------
echo ""
log "?? A ????:$OUT"
ls -1 "$OUT" | sed 's/^/    /'
echo ""
echo "???:./build.sh(???? channel_a ?? app bundle),? make exploits ????"
