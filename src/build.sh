#!/bin/bash
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> ????"
uname -s | grep -q Darwin || { echo "??? macOS ???"; exit 1; }
command -v xcodebuild >/dev/null || { echo "?? Xcode ?????"; exit 1; }

if [ -z "$THEOS" ]; then
    echo "==> ???? THEOS,??????"
    for p in "$HOME/theos" "/opt/theos" "/usr/local/theos"; do
        [ -d "$p" ] && export THEOS="$p" && break
    done
    [ -z "$THEOS" ] && { echo "???? theos: https://theos.dev/docs/installation-macos"; exit 1; }
fi
echo "    THEOS=$THEOS"

SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-version)}"
echo "    SDK=$SDK"

echo "==> ?????????(upstream/,? ci_fetch_deps.sh ??)"
need=0
[ -d "$HERE/../upstream/XPF/src" ]        || { echo "    ?? XPF"; need=1; }
[ -d "$HERE/../upstream/ChOma/src" ]      || { echo "    ?? ChOma"; need=1; }
[ -f "$HERE/../upstream/XPF/external/img4lib/lzss.c" ] || { echo "    ?? img4lib(XPF ???)"; need=1; }
[ -d "$HERE/../upstream/libgrabkernel2" ] || { echo "    ?? libgrabkernel2"; need=1; }
[ -d "$HERE/../upstream/Dopamine" ]       || { echo "    ?? Dopamine(exploit ????)"; need=1; }
[ "$need" = "1" ] && { echo "?? ./ci_fetch_deps.sh"; exit 1; }

echo "==> ???? C ??(choma / img4 / xpf / grabkernel2)"
make -C "$HERE/deps"

cd "$HERE"
echo "==> ??"
rm -rf .theos .ipa OPENsrc.ipa

echo "==> ???? A(Dopamine ????:BaseBin + 9 ? exploit framework)"
if [ -d "$HERE/../upstream/Dopamine" ]; then
    bash "$HERE/../tools/build_channel_a.sh" || {
        echo "??: ?? A ????,????(???? B ????)"
    }
else
    echo "??: ? Dopamine ??,???? A(?? ./ci_fetch_deps.sh)"
fi

echo "==> ??"
make clean 2>/dev/null || true
make -j"$(sysctl -n hw.ncpu)" package

echo "==> ??? A ???? app bundle"
make exploits || echo "??: exploits ????,?????????"

echo "==> ? IPA"
make ipa

echo "==> ??: $HERE/OPENsrc.ipa"
echo "    ????: ?????????? entitlements.plist"
echo "    ????: ldid -Sentitlements.plist Payload/OPENsrc.app/OPENsrc (? codesign -f -s <id> --entitlements entitlements.plist)"
