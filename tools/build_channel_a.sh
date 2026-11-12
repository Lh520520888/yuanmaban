#!/bin/bash
# =============================================================================
#  tools/build_channel_a.sh
#  通道 A（内核链）全部产物 —— 从 Dopamine 上游源码自己编译，不依赖任何现成 IPA。
#
#  产物（输出到 src/channel_a/，刻意不放进 Resources —— 否则会被当成资源整目录拷进包）：
#    libjailbreak.dylib / libchoma.dylib / libxpf.dylib
#    kfd.framework / weightBufs.framework / multicast_bytecopy.framework
#    dmaFail.framework / badRecovery.framework
#    ClearSword.framework / DarkSword.framework / Titan.framework / momentarius.framework
#
#  用法（必须在 macOS + Xcode 上跑）：
#      bash tools/build_channel_a.sh
#      bash tools/build_channel_a.sh --clean     # 先清掉旧产物再编
#
#  说明：
#    - BaseBin 提供 libjailbreak / libxpf / libchoma（Dopamine 自己的构建方式）
#    - 9 个 exploit 是 Dopamine.xcodeproj 里的 framework target，源码在
#      Application/Dopamine/Exploits/<name>/
#    - 编完统一改 install_name，布局与目标包一致：
#         App.app/libjailbreak.dylib
#         App.app/libchoma.dylib
#         App.app/Frameworks/libxpf.dylib
#         App.app/Frameworks/<exploit>.framework
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DOPAMINE="$ROOT/01-越狱内核/Dopamine"
BASEBIN="$DOPAMINE/BaseBin"
PROJ="$DOPAMINE/Application/Dopamine.xcodeproj"
OUT="$ROOT/src/channel_a"
BUILDDIR="$ROOT/.build/channel_a"

EXPLOITS=(kfd weightBufs multicast_bytecopy dmaFail badRecovery ClearSword DarkSword Titan momentarius)

log() { echo "==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }

# ---------- 环境检查 ----------
[ "$(uname -s)" = "Darwin" ] || die "必须在 macOS 上构建（当前 $(uname -s)）"
command -v xcodebuild >/dev/null || die "缺 xcodebuild，先装 Xcode 命令行工具"
command -v xcrun      >/dev/null || die "缺 xcrun"
command -v ldid       >/dev/null || echo "警告: 未检测到 ldid（BaseBin 构建要用它签名，brew install ldid）"
[ -d "$PROJ" ]  || die "找不到 Dopamine.xcodeproj: $PROJ（先跑 源码版/_fetch.sh）"
[ -d "$BASEBIN" ] || die "找不到 BaseBin: $BASEBIN"
[ -d "$BASEBIN/_external/include" ] || die "BaseBin/_external 不完整（Dopamine 子模块缺失）"
if ! brew --prefix libarchive >/dev/null 2>&1; then
    echo "警告: 未检测到 brew libarchive，libjailbreak 可能编不过（brew install libarchive）"
fi

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$OUT" "$BUILDDIR" "$BASEBIN/.build" "$BASEBIN/.include"
    log "已清理旧产物"
fi

mkdir -p "$OUT" "$BUILDDIR"

# ---------- 1. BaseBin：libchoma / libxpf / libjailbreak ----------
log "构建 BaseBin（libchoma / libxpf / libjailbreak）"
make -C "$BASEBIN" ChOma XPF libjailbreak

for f in libchoma.dylib libxpf.dylib libjailbreak.dylib; do
    [ -f "$BASEBIN/.build/$f" ] || die "BaseBin 未产出 $f"
    cp -f "$BASEBIN/.build/$f" "$OUT/$f"
    echo "    $f  $(du -h "$OUT/$f" | cut -f1)"
done

# ---------- 2. 9 个 exploit framework ----------
log "构建 exploit framework（${#EXPLOITS[@]} 个）"
failed=()
for name in "${EXPLOITS[@]}"; do
    src="$DOPAMINE/Application/Dopamine/Exploits/$name"
    [ -d "$src" ] || { echo "    跳过（源码不存在）: $name"; continue; }
    [ -f "$src/Info.plist" ] || { echo "    跳过（无 Info.plist）: $name"; continue; }

    echo "    ---- $name"
    if ! xcodebuild -project "$PROJ" \
            -target "$name" \
            -configuration Release \
            -sdk iphoneos \
            -derivedDataPath "$BUILDDIR" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
            build > "$BUILDDIR/$name.log" 2>&1; then
        echo "    构建失败，日志: $BUILDDIR/$name.log"
        failed+=("$name")
        continue
    fi
    fw="$(find "$BUILDDIR/Build/Products/Release-iphoneos" -maxdepth 1 -name "$name.framework" -print -quit)"
    if [ -z "$fw" ]; then
        fw="$(find "$BUILDDIR/Build/Products" -name "$name.framework" -print -quit)"
    fi
    [ -n "$fw" ] || { echo "    未找到 $name.framework"; failed+=("$name"); continue; }

    rm -rf "$OUT/$name.framework"
    cp -R "$fw" "$OUT/"
    echo "    产出: $OUT/$name.framework"
done

if [ ${#failed[@]} -gt 0 ]; then
    echo ""
    echo "警告: 以下 exploit 编译失败: ${failed[*]}"
    echo "      其余产物仍可用；先看 .build/channel_a/<name>.log"
fi

# ---------- 3. 归一化 install_name（对齐目标包的加载布局） ----------
log "统一 install_name"
if command -v install_name_tool >/dev/null; then
    # 主 dylib 放 App 根目录
    install_name_tool -id "@executable_path/libjailbreak.dylib" "$OUT/libjailbreak.dylib" 2>/dev/null || true
    install_name_tool -id "@executable_path/libchoma.dylib"     "$OUT/libchoma.dylib"     2>/dev/null || true
    # libjailbreak 依赖 libchoma
    choma_old="$(otool -L "$OUT/libjailbreak.dylib" 2>/dev/null | awk '/libchoma/{print $1; exit}')"
    if [ -n "${choma_old:-}" ] && [ "$choma_old" != "@executable_path/libchoma.dylib" ]; then
        install_name_tool -change "$choma_old" "@executable_path/libchoma.dylib" "$OUT/libjailbreak.dylib"
    fi
    # libxpf 放 Frameworks
    install_name_tool -id "@executable_path/Frameworks/libxpf.dylib" "$OUT/libxpf.dylib" 2>/dev/null || true

    # 每个 framework：把 libjailbreak 依赖统一成 @executable_path/libjailbreak.dylib
    for fw in "$OUT"/*.framework; do
        [ -d "$fw" ] || continue
        bin="$fw/$(basename "$fw" .framework)"
        [ -f "$bin" ] || continue
        old="$(otool -L "$bin" 2>/dev/null | awk '/libjailbreak/{print $1; exit}')"
        if [ -n "${old:-}" ] && [ "$old" != "@executable_path/libjailbreak.dylib" ]; then
            install_name_tool -change "$old" "@executable_path/libjailbreak.dylib" "$bin"
            echo "    $(basename "$fw"): $old -> @executable_path/libjailbreak.dylib"
        fi
        # 框架内 rpath：保留 @executable_path/Frameworks 兜底
        install_name_tool -add_rpath "@executable_path/Frameworks" "$bin" 2>/dev/null || true
    done
else
    echo "    无 install_name_tool，跳过（后续手动处理）"
fi

# ---------- 4. 自签 ----------
log "ad-hoc 签名"
if command -v ldid >/dev/null; then
    for f in "$OUT"/*.dylib; do [ -f "$f" ] && ldid -Cadhoc -s "$f"; done
    for fw in "$OUT"/*.framework; do
        [ -d "$fw" ] || continue
        bin="$fw/$(basename "$fw" .framework)"
        [ -f "$bin" ] && ldid -Cadhoc -S "$bin"
    done
    echo "    ldid 完成"
else
    echo "    无 ldid，跳过（Xcode 打包阶段会重新签名）"
fi

# ---------- 5. 清单 ----------
echo ""
log "通道 A 产物清单：$OUT"
ls -1 "$OUT" | sed 's/^/    /'
echo ""
echo "下一步：./build.sh（会自动把 channel_a 装进 app bundle），或 make exploits 单独拷入"
