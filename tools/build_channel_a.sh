#!/bin/bash
# =============================================================================
#  tools/build_channel_a.sh
#  通道 A（内核链）全部产物 —— 从 Dopamine 上游源码自己编译，不依赖任何现成 IPA。
#
#  产物（输出到 src/channel_a/，刻意不放进 Resources —— 否则会被当成资源整目录拷进包）：
#    libjailbreak.dylib / libchoma.dylib / libxpf.dylib
#    kfd / weightBufs / multicast_bytecopy / dmaFail / badRecovery
#    ClearSword / DarkSword / Titan / momentarius  .framework
#
#  用法（macOS + Xcode）：
#      bash tools/build_channel_a.sh
#      bash tools/build_channel_a.sh --clean
#
#  目录兼容：优先 upstream/Dopamine，其次 01-越狱内核/Dopamine
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [ -d "$ROOT/upstream/Dopamine" ]; then
    DOPAMINE="$ROOT/upstream/Dopamine"
elif [ -d "$ROOT/01-越狱内核/Dopamine" ]; then
    DOPAMINE="$ROOT/01-越狱内核/Dopamine"
else
    DOPAMINE="$ROOT/upstream/Dopamine"
fi

BASEBIN="$DOPAMINE/BaseBin"
PROJ="$DOPAMINE/Application/Dopamine.xcodeproj"
OUT="$ROOT/src/channel_a"
BUILDDIR="$ROOT/.build/channel_a"

EXPLOITS=(kfd weightBufs multicast_bytecopy dmaFail badRecovery ClearSword DarkSword Titan momentarius)

log() { echo "==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }

# ---------- 环境检查 ----------
[ "$(uname -s)" = "Darwin" ] || die "必须在 macOS 上构建（当前 $(uname -s)）"
command -v xcodebuild >/dev/null || die "缺 xcodebuild"
command -v xcrun      >/dev/null || die "缺 xcrun"
command -v ldid       >/dev/null || echo "警告: 未检测到 ldid（BaseBin 构建要用它签名）"
[ -d "$PROJ" ]    || die "找不到 Dopamine.xcodeproj: $PROJ"
[ -d "$BASEBIN" ] || die "找不到 BaseBin: $BASEBIN"
[ -d "$BASEBIN/_external/include" ] || die "BaseBin/_external 不完整（子模块没拉全）"

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$OUT" "$BUILDDIR" "$BASEBIN/.build" "$BASEBIN/.include"
    log "已清理旧产物"
fi

mkdir -p "$OUT" "$BUILDDIR"

# ---------- 1. BaseBin ----------
log "构建 BaseBin（libchoma / libxpf / libjailbreak）"
make -C "$BASEBIN" ChOma XPF libjailbreak

for f in libchoma.dylib libxpf.dylib libjailbreak.dylib; do
    [ -f "$BASEBIN/.build/$f" ] || die "BaseBin 未产出 $f"
    cp -f "$BASEBIN/.build/$f" "$OUT/$f"
    echo "    $f  $(du -h "$OUT/$f" | cut -f1)"
done

# ---------- 2. exploit framework ----------
log "构建 exploit framework（${#EXPLOITS[@]} 个）"
FAILED=""
for name in "${EXPLOITS[@]}"; do
    src="$DOPAMINE/Application/Dopamine/Exploits/$name"
    if [ ! -d "$src" ]; then
        echo "    跳过（源码不存在）: $name"
        continue
    fi

    echo "    ---- $name"
    if ! xcodebuild -project "$PROJ" \
            -target "$name" \
            -configuration Release \
            -sdk iphoneos \
            SYMROOT="$BUILDDIR/Build/Products" \
            OBJROOT="$BUILDDIR/Build/Intermediates" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
            build > "$BUILDDIR/$name.log" 2>&1; then
        echo "    构建失败，末尾 25 行（完整日志: .build/channel_a/$name.log）："
        tail -n 25 "$BUILDDIR/$name.log" | sed 's/^/      /'
        FAILED="$FAILED $name"
        continue
    fi

    fw="$(find "$BUILDDIR/Build/Products" -maxdepth 2 -name "$name.framework" -print -quit 2>/dev/null || true)"
    if [ -z "$fw" ]; then
        echo "    未找到 $name.framework，末尾 10 行："
        tail -n 10 "$BUILDDIR/$name.log" | sed 's/^/      /'
        FAILED="$FAILED $name"
        continue
    fi

    rm -rf "$OUT/$name.framework"
    cp -R "$fw" "$OUT/"
    echo "    产出: $OUT/$name.framework"
done

if [ -n "$FAILED" ]; then
    echo ""
    echo "警告: 这些 exploit 编译失败:$FAILED"
    echo "      其余产物仍可用；日志在 .build/channel_a/<name>.log"
fi

# ---------- 3. install_name ----------
log "统一 install_name"
if command -v install_name_tool >/dev/null; then
    install_name_tool -id "@executable_path/libjailbreak.dylib" "$OUT/libjailbreak.dylib" 2>/dev/null || true
    install_name_tool -id "@executable_path/libchoma.dylib"     "$OUT/libchoma.dylib"     2>/dev/null || true
    choma_old="$(otool -L "$OUT/libjailbreak.dylib" 2>/dev/null | awk '/libchoma/{print $1; exit}' || true)"
    if [ -n "${choma_old:-}" ] && [ "$choma_old" != "@executable_path/libchoma.dylib" ]; then
        install_name_tool -change "$choma_old" "@executable_path/libchoma.dylib" "$OUT/libjailbreak.dylib"
    fi
    install_name_tool -id "@executable_path/Frameworks/libxpf.dylib" "$OUT/libxpf.dylib" 2>/dev/null || true

    for fw in "$OUT"/*.framework; do
        [ -d "$fw" ] || continue
        bin="$fw/$(basename "$fw" .framework)"
        [ -f "$bin" ] || continue
        old="$(otool -L "$bin" 2>/dev/null | awk '/libjailbreak/{print $1; exit}' || true)"
        if [ -n "${old:-}" ] && [ "$old" != "@executable_path/libjailbreak.dylib" ]; then
            install_name_tool -change "$old" "@executable_path/libjailbreak.dylib" "$bin"
        fi
        install_name_tool -add_rpath "@executable_path/Frameworks" "$bin" 2>/dev/null || true
    done
else
    echo "    无 install_name_tool，跳过"
fi

# ---------- 4. 自签 ----------
log "ad-hoc 签名"
if command -v ldid >/dev/null; then
    for f in "$OUT"/*.dylib; do
        [ -f "$f" ] && ldid -Cadhoc -s "$f" || true
    done
    for fw in "$OUT"/*.framework; do
        [ -d "$fw" ] || continue
        bin="$fw/$(basename "$fw" .framework)"
        [ -f "$bin" ] && ldid -Cadhoc -S "$bin" || true
    done
    echo "    ldid 完成"
else
    echo "    无 ldid，跳过"
fi

# ---------- 5. 清单 ----------
echo ""
log "通道 A 产物清单：$OUT"
ls -1 "$OUT" | sed 's/^/    /'
