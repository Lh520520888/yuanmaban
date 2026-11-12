#!/bin/bash
# CI 用：把构建所需的上游源码拉到与“源码版/”相同的目录布局。
#   src/Makefile        : ../01-越狱内核/{XPF,ChOma}、../05-工具链/libgrabkernel2
#   tools/build_channel_a.sh : ../01-越狱内核/Dopamine（含 BaseBin 子模块）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/01-越狱内核" "$ROOT/05-工具链"

clone() {
    local dest="$1"; shift
    if [ -d "$ROOT/$dest/.git" ]; then
        echo "[skip] $dest"
        return 0
    fi
    echo "[clone] $dest <- $*"
    git clone --depth 1 --recursive "$@" "$ROOT/$dest"
}

# Dopamine：提供 BaseBin(libjailbreak/libxpf/libchoma) 与 9 个 exploit framework 源码
clone "01-越狱内核/Dopamine" https://github.com/opa334/Dopamine

# 独立源码树：deps 静态库要用
clone "01-越狱内核/ChOma" https://github.com/opa334/ChOma
clone "01-越狱内核/XPF" https://github.com/opa334/XPF
clone "05-工具链/libgrabkernel2" https://github.com/alfiecg24/libgrabkernel2

echo "== 上游源码就绪 =="
for d in 01-越狱内核/Dopamine 01-越狱内核/ChOma 01-越狱内核/XPF 05-工具链/libgrabkernel2; do
    printf '  %-32s %s\n' "$d" "$(du -sh "$ROOT/$d" 2>/dev/null | cut -f1)"
done
