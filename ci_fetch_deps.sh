#!/bin/bash
# CI 用：把构建所需的上游源码拉到 upstream/ 下（全 ASCII 路径，避免编码问题）。
#   src/Makefile        : ../upstream/{XPF,ChOma,libgrabkernel2}
#   tools/build_channel_a.sh : ../upstream/Dopamine（含 BaseBin 子模块）
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

# Dopamine：提供 BaseBin(libjailbreak/libxpf/libchoma) 与 9 个 exploit framework 源码
clone "Dopamine" https://github.com/opa334/Dopamine

# 独立源码树：deps 静态库要用
clone "ChOma" https://github.com/opa334/ChOma
clone "XPF" https://github.com/opa334/XPF
clone "libgrabkernel2" https://github.com/alfiecg24/libgrabkernel2

echo "== 上游源码就绪 =="
for d in Dopamine ChOma XPF libgrabkernel2; do
    printf '  %-16s %s\n' "$d" "$(du -sh "$ROOT/upstream/$d" 2>/dev/null | cut -f1)"
done
