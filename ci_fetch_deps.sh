#!/bin/bash
# CI ?:???????????? upstream/ ?(? ASCII ??,??????)?
#   src/Makefile        : ../upstream/{XPF,ChOma,libgrabkernel2}
#   tools/build_channel_a.sh : ../upstream/Dopamine(? BaseBin ???)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/upstream"

clone() {
    local dest="$1"; shift
    if [ -d "$ROOT/upstream/$dest/.git" ]; then
        echo "[skip] $dest"
        return 0
    fi
    echo "[clone] $dest <- $*"
    git clone --depth 1 --recursive "$@" "$ROOT/upstream/$dest"
}

# Dopamine:?? BaseBin(libjailbreak/libxpf/libchoma) ? 9 ? exploit framework ??
clone "Dopamine" https://github.com/opa334/Dopamine

# ?????:deps ?????
clone "ChOma" https://github.com/opa334/ChOma
clone "XPF" https://github.com/opa334/XPF
clone "libgrabkernel2" https://github.com/alfiecg24/libgrabkernel2

echo "== ?????? =="
for d in Dopamine ChOma XPF libgrabkernel2; do
    printf '  %-16s %s\n' "$d" "$(du -sh "$ROOT/upstream/$d" 2>/dev/null | cut -f1)"
done
