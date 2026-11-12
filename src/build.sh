#!/bin/bash
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> 环境检查"
uname -s | grep -q Darwin || { echo "必须在 macOS 上构建"; exit 1; }
command -v xcodebuild >/dev/null || { echo "需要 Xcode 命令行工具"; exit 1; }

if [ -z "$THEOS" ]; then
    echo "==> 未检测到 THEOS，尝试默认路径"
    for p in "$HOME/theos" "/opt/theos" "/usr/local/theos"; do
        [ -d "$p" ] && export THEOS="$p" && break
    done
    [ -z "$THEOS" ] && { echo "请先安装 theos: https://theos.dev/docs/installation-macos"; exit 1; }
fi
echo "    THEOS=$THEOS"

SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-version)}"
echo "    SDK=$SDK"

echo "==> 确认上游依赖已回填"
need=0
[ -d "$HERE/../01-越狱内核/XPF/src" ]        || { echo "    缺失 XPF"; need=1; }
[ -d "$HERE/../01-越狱内核/ChOma/src" ]      || { echo "    缺失 ChOma"; need=1; }
[ -d "$HERE/../01-越狱内核/XPF/external/img4lib/lzss.c" ] || { echo "    缺失 img4lib（XPF 子模块，需单独拉 xerub/img4lib）"; need=1; }
[ -d "$HERE/../05-工具链/libgrabkernel2" ]   || { echo "    缺失 libgrabkernel2"; need=1; }
[ -d "$HERE/../01-越狱内核/Dopamine" ]       || { echo "    缺失 Dopamine(exploit 框架来源)"; need=1; }
[ "$need" = "1" ] && { echo "先跑 源码版/_fetch.sh"; exit 1; }

echo "==> 编译上游 C 依赖（choma / img4 / xpf / grabkernel2）"
make -C "$HERE/deps"

cd "$HERE"
echo "==> 清理"
rm -rf .theos .ipa OPENsrc.ipa

echo "==> 构建通道 A（Dopamine 上游源码：BaseBin + 9 个 exploit framework）"
if [ -d "$HERE/../01-越狱内核/Dopamine" ]; then
    bash "$HERE/../tools/build_channel_a.sh" || {
        echo "警告: 通道 A 构建失败，继续出包（容器通道 B 不受影响）"
    }
else
    echo "警告: 缺 Dopamine 源码，跳过通道 A（先跑 ../_fetch.sh）"
fi

echo "==> 编译"
make clean 2>/dev/null || true
make -j"$(sysctl -n hw.ncpu)" package

echo "==> 把通道 A 产物装进 app bundle"
make exploits || echo "警告: exploits 拷贝失败，包里不会有内核通道"

echo "==> 出 IPA"
make ipa

echo "==> 完成: $HERE/OPENsrc.ipa"
echo "    签名环节: 用企业证书重签时保留 entitlements.plist"
echo "    签名命令: ldid -Sentitlements.plist Payload/OPENsrc.app/OPENsrc (或 codesign -f -s <id> --entitlements entitlements.plist)"
