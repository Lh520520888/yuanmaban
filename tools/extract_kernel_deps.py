# -*- coding: utf-8 -*-
"""
【已弃用 / 仅作溯源】从目标包提取内核链二进制依赖。

2026-11-12 起，通道 A 改为从 Dopamine 上游源码自行编译（tools/build_channel_a.sh），
不再使用目标包里的编译产物；本脚本保留只为说明历史来源，不参与构建。
原 prebuilt 已归档到 _archive/prebuilt_from_ipa_20261112/。

从目标包提取内核链所需的全部二进制依赖，放到 src/Resources/prebuilt/。

为什么可以直接用：
    原包（星耀国际-v4C2-签名完整.ipa）里的 8 个内核组件是**已编译好的 arm64 产物**，
    带 DPExploitType / DPExploitFlavors 元数据，与 Dopamine 3.x 的 ABI 一致。
    不需要 macOS 重新编译 Dopamine。

提取内容：
    exploit framework（5 个，带 DPExploitType）
        kfd.framework              Kernel / landa+physpuppet+smith
        weightBufs.framework       Kernel
        multicast_bytecopy.framework Kernel
        dmaFail.framework          PPL
        badRecovery.framework      PAC
    运行时 dylib（4 个，exploit 依赖）
        libjailbreak.dylib         提供 gPrimitives 符号与越狱原语
        libxpf.dylib               patchfinder（xpf_start_with_kernel_path）
        libgrabkernel2.dylib       抓 kernelcache
        libchoma.dylib             Mach-O / CMS 解析

用法：
    python tools/extract_kernel_deps.py --ipa <目标包.ipa> [--out src/Resources/prebuilt]

产出后在 Makefile 里由 link_exploits.sh / 打包脚本拷入 app bundle。
"""

import argparse
import os
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

EXPLOIT_FWS = [
    'kfd',
    'weightBufs',
    'multicast_bytecopy',
    'dmaFail',
    'badRecovery',
]

RUNTIME_DYLIBS = [
    'Frameworks/libjailbreak.dylib',
    'Frameworks/libxpf.dylib',
    'Frameworks/libgrabkernel2.dylib',
    'Frameworks/libchoma.dylib',
]


def extract_one(z, name, dest_root, as_dylib):
    """提取单个 framework 目录（name='kfd'）或 dylib 文件（name='Frameworks/x.dylib'）"""
    if not as_dylib:
        prefix = 'Payload/OPEN.app/Frameworks/%s.framework/' % name
        members = [n for n in z.namelist() if n.startswith(prefix) and not n.endswith('/')]
        if not members:
            print('  ! %s.framework 不存在于包内' % name)
            return 0
        out_dir = os.path.join(dest_root, name + '.framework')
        if os.path.isdir(out_dir):
            shutil.rmtree(out_dir)
        os.makedirs(out_dir, exist_ok=True)
        total = 0
        for m in members:
            rel = m[len(prefix):]
            # 去掉 _CodeSignature（我们后面自己签）
            if rel.startswith('_CodeSignature/'):
                continue
            dst = os.path.join(out_dir, rel.replace('/', os.sep))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            data = z.read(m)
            with open(dst, 'wb') as f:
                f.write(data)
            total += len(data)
        print('  OK %-30s %8d B' % (name + '.framework', total))
        return total
    else:
        src = 'Payload/OPEN.app/' + name
        try:
            data = z.read(src)
        except KeyError:
            print('  ! %s 不存在' % name)
            return 0
        dst = os.path.join(dest_root, os.path.basename(name))
        with open(dst, 'wb') as f:
            f.write(data)
        print('  OK %-30s %8d B' % (os.path.basename(name), len(data)))
        return len(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ipa', required=True)
    ap.add_argument('--out', default=os.path.join(ROOT, 'src', 'Resources', 'prebuilt'))
    a = ap.parse_args()

    if not os.path.exists(a.ipa):
        raise SystemExit('包不存在: %s' % a.ipa)

    os.makedirs(a.out, exist_ok=True)
    print('[1] 提取 exploit framework')
    z = zipfile.ZipFile(a.ipa)
    total = 0
    for fw in EXPLOIT_FWS:
        total += extract_one(z, fw, a.out, as_dylib=False)

    print('\n[2] 提取运行时 dylib')
    for d in RUNTIME_DYLIBS:
        total += extract_one(z, d, a.out, as_dylib=True)

    print('\n[3] 校验 DPExploitType')
    import plistlib
    found = 0
    for fw in EXPLOIT_FWS:
        p = os.path.join(a.out, fw + '.framework', 'Info.plist')
        if not os.path.exists(p):
            continue
        try:
            d = plistlib.load(open(p, 'rb'))
        except Exception as e:
            print('  ! %s plist 解析失败: %s' % (fw, e))
            continue
        t = d.get('DPExploitType')
        fl = d.get('DPExploitFlavors', {})
        if t:
            found += 1
            names = ','.join(fl.keys())
            print('  %-24s type=%-8s flavors=%s' % (fw, t, names))

    print('\n合计 %.2f MB，%d/5 个 framework 带 DPExploitType' % (total / 1024 / 1024, found))
    print('输出目录: %s' % a.out)

    if found != len(EXPLOIT_FWS):
        print('\nWARNING: 有 framework 缺 DPExploitType，内核通道会少候选')
        sys.exit(1)
    print('\nDONE')


if __name__ == '__main__':
    main()
