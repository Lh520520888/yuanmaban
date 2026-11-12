# -*- coding: utf-8 -*-
"""
源码版深度审计：在 lint.py 之外，检查「接线 / 数据流 / 资源 / 并发」层面的问题。

lint.py 管的是静态结构（括号、声明匹配、资源引用、Makefile 收录）。
本脚本管的是「写出来了但没用上 / 用错了」这类功能缺陷：
  - 死代码（声明但无人调用）
  - 数据结构对不上（产出字段 vs 消费字段）
  - 持锁做 IO
  - 资源泄漏（query/handle/sqlite stmt）
  - 错误码定义了不用
  - 目录/文件语义错配（如只上传 !isDir 却只产出目录）

用法：
    python tools/audit.py            # 全部检查
    python tools/audit.py --quiet    # 只报问题

退出码：0 = 无问题，1 = 有问题
"""
import os
import re
import sys
import glob
import plistlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'src')

problems = []


def P(msg):
    problems.append(msg)


def read(p):
    with open(p, encoding='utf-8', errors='replace') as f:
        return f.read()


def norm(p):
    return p.replace(chr(92), '/')


def src_files(pattern='**/*.m'):
    return [f for f in glob.glob(os.path.join(SRC, pattern), recursive=True)
            if 'vendor' not in norm(f)]



# ---------------------------------------------------------------- 0 语法配对
def _strip_noise(src):
    """剔除注释与字符串，避免中文括号/转义干扰计数"""
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        if ch == '"':
            i += 1
            while i < n:
                if src[i] == chr(92):
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        if ch == "'":
            i += 1
            while i < n:
                if src[i] == chr(92):
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
            out.append("''")
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def check_syntax():
    print('\n[0] 语法配对（剔除注释/字符串后）')
    bad = 0
    for f in src_files('**/*.[mh]'):
        rel = os.path.relpath(f, SRC)
        src = _strip_noise(read(f))
        o, c = src.count('('), src.count(')')
        bo, bc = src.count('{'), src.count('}')
        if o != c or bo != bc:
            bad += 1
            print('  ! %-46s ( %d/%d  { %d/%d' % (rel, o, c, bo, bc))
            P('%s 括号不配平 ( %d/%d  { %d/%d' % (rel, o, c, bo, bc))
    if bad == 0:
        print('  OK 所有文件括号配平')


# ---------------------------------------------------------------- 1 死代码
def check_dead_code():
    print('\n[1] 死代码检查')
    defs = {}
    for f in src_files():
        for i, line in enumerate(read(f).split('\n'), 1):
            m = re.match(r'^\s*[-+]\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)', line)
            if m:
                defs.setdefault(m.group(1), []).append((os.path.relpath(f, SRC), i))

    calls = set()
    for f in src_files():
        s = read(f)
        for m in re.finditer(r'\[\s*[\w\.\]\[]*\s*(\w+)\s*[:\]]', s):
            calls.add(m.group(1))
        for m in re.finditer(r'\b(\w+)\s*\(', s):
            calls.add(m.group(1))

    # 公开 API / 协议回调 / getter，允许「只定义不调用」
    allow = {
        'init', 'dealloc', 'description', 'shared', 'main', 'application', 'window',
        'setDelegate', 'run', 'runAll', 'prepare', 'load', 'available', 'lastError',
        'workDir', 'results', 'signedIdentity', 'identityOK', 'activeCount', 'maxConcurrent',
        'allMappings', 'status', 'classNameFor', 'bundleIdForUUID', 'uuidForBundleId',
        'bundleIdFromContainerPath', 'containersOfClass', 'containerOfClass',
        'activateContainer', 'releasePath', 'releaseAll', 'hasLeaseForPath',
        'runChannelB', 'runChannelA', 'runKeychain', 'lastResults',
        'grabBundleId', 'copySandboxTokenForContainer', 'start', 'execute', 'flush',
        'enqueueFile', 'enqueueManifest', 'purge', 'tail', 'logFile', 'reset',
        'notePayload', 'markDoneIfPayloadValid', 'isAtLeastMajor', 'isLessOrEqualMajor',
        'protectedDataAvailable', 'socTierName', 'bootManifestHash', 'phaseName',
        'zipFiles', 'scanResultList', 'runWithRemote', 'isSupported',
        # UIApplicationDelegate 回调（系统调用，非本地调用）
        'applicationDidBecomeActive', 'applicationDidEnterBackground',
        'applicationWillEnterForeground', 'applicationWillTerminate',
        # 只读属性（由 @property 合成，外部访问）
        'hits', 'skipped', 'lastJSONPath', 'lastPlainPath', 'synchronize', 'initWithPath',
        'outDir', 'payloads', 'osVersion', 'major', 'minor', 'patch', 'machine',
        'socTier', 'isArm64e',
    }
    dead = []
    for name, locs in sorted(defs.items()):
        if name in allow or name in calls:
            continue
        dead.append((name, locs))
    if dead:
        for name, locs in dead:
            print('  ! %-42s %s' % (name, locs))
            P('疑似死代码: %s（%s）' % (name, locs[0]))
    else:
        print('  OK 无死代码')


# ---------------------------------------------------------------- 2 数据流
def check_dataflow():
    print('\n[2] 数据流：产出字段 vs 消费字段')
    cp = read(os.path.join(SRC, 'Container/OWContainerPass.m'))
    rt = read(os.path.join(SRC, 'Orchestrator/OWRoute.m'))

    # 采集产出：找 _noteResultForName 里的 dict 键
    m = re.search(r'- \(void\)_noteResultForName:(.*?)\n\}', cp, re.S)
    produced = set()
    if m:
        produced = set(re.findall(r'@"(\w+)":', m.group(1)))
    print('  OWContainerPass 产出: %s' % sorted(produced))

    consumed = set(re.findall(r'r\[@"(\w+)"\]', rt))
    print('  OWRoute 消费: %s' % sorted(consumed))

    # 消费的字段必须被产出
    for k in consumed:
        if produced and k not in produced:
            P('OWRoute 消费了 OWContainerPass 不产出的字段: %s' % k)
            print('  ! 消费了不存在的字段: %s' % k)

    # 关键语义：只上传 !isDir 会丢掉目录产出
    if 'isDir: @(YES)' in cp or 'isDir": @(YES)' in cp:
        if re.search(r'if \(p && .*&& !isDir\) \{\s*\n\s*\[up enqueueFile', rt):
            P('OWRoute 只上传 !isDir，但 OWContainerPass 产出的是目录 → 全部丢失')
            print('  ! 只上传 !isDir，但产出是目录')
        elif 'enumeratorAtPath:p' in rt:
            print('  OK 目录条目会被逐文件入队')
        else:
            print('  ? 目录处理未检出，需人工确认')


# ---------------------------------------------------------------- 3 持锁 IO
def check_lock_io():
    print('\n[3] 持锁做 IO 检查')
    for f in src_files():
        s = read(f)
        if 'os_unfair_lock_lock' not in s:
            continue
        rel = os.path.relpath(f, SRC)
        lines = s.split('\n')
        depth = 0
        lock_line = None
        call_inside = []
        for i, l in enumerate(lines):
            if 'os_unfair_lock_lock' in l:
                lock_line = i
            depth += l.count('{') - l.count('}')
            if lock_line is not None:
                for fn in ('gConsume', 'gRelease(', 'sqlite3_', 'NSFileManager',
                           'contentsOfDirectory', 'dictionaryWithContentsOfFile'):
                    if fn in l and 'os_unfair_lock' not in l:
                        call_inside.append((i + 1, fn))
            if 'os_unfair_lock_unlock' in l:
                lock_line = None
                call_inside = []
        if call_inside:
            for ln, fn in call_inside:
                P('%s:%d 持锁调用 %s' % (rel, ln, fn))
                print('  ! %s:%d 持锁调用 %s' % (rel, ln, fn))
        else:
            print('  OK %s 无持锁 IO' % rel)


# ---------------------------------------------------------------- 4 资源泄漏
def check_resources():
    print('\n[4] 资源配对检查')
    for f in src_files():
        s = read(f)
        rel = os.path.relpath(f, SRC)
        pairs = [
            ('sqlite3_prepare_v2', 'sqlite3_finalize'),
            ('os_unfair_lock_lock', 'os_unfair_lock_unlock'),
            ('OWQueryRetain', 'OWQueryRelease'),
        ]
        for a, b in pairs:
            na, nb = s.count(a), s.count(b)
            if na == 0 and nb == 0:
                continue
            # 定义行算一次
            da = 1 if re.search(r'^static .*\b' + a + r'\(', s, re.M) or ('- (' in s and a + ':' in s) else 0
            print('  %-34s %-22s %d / %-22s %d' % (rel, a, na, b, nb))
            if na > nb:
                P('%s %s(%d) 多于 %s(%d)，可能泄漏' % (rel, a, na, b, nb))


# ---------------------------------------------------------------- 5 错误码
def check_error_codes():
    print('\n[5] 错误码是否都被使用')
    h = read(os.path.join(SRC, 'Container/OWMCM.h'))
    m = read(os.path.join(SRC, 'Container/OWMCM.m'))
    lease = read(os.path.join(SRC, 'Container/OWMCMLease.m'))
    codes = re.findall(r'(OWMCMStatus\w+)\s*=\s*(-?\d+)', h)
    unused = []
    for name, val in codes:
        if name == 'OWMCMStatusOK':
            continue
        # .m 里出现 >=1 次即说明被 return/比较用到（定义在 .h）
        n = m.count(name) + lease.count(name)
        if n < 1:
            unused.append('%s(%s)' % (name, val))
    if unused:
        for u in unused:
            print('  ! %s 定义但从未在实现里出现' % u)
            P('OWMCM 错误码未使用: %s' % u)
    else:
        print('  OK 所有错误码都有使用')


# ---------------------------------------------------------------- 6 目标清单
def check_targets():
    print('\n[6] targets.plist 与代码一致性')
    pl_path = os.path.join(SRC, 'Resources/targets.plist')
    if not os.path.exists(pl_path):
        P('Resources/targets.plist 缺失')
        return
    try:
        pl = plistlib.load(open(pl_path, 'rb'))
    except Exception as e:
        P('targets.plist 解析失败: %s' % e)
        return
    wallets = pl.get('wallets', [])
    print('  %d 条目标' % len(wallets))

    cp = read(os.path.join(SRC, 'Container/OWContainerPass.m'))
    read_keys = set(re.findall(r'target\[@"(\w+)"\]', cp))
    all_keys = set()
    for w in wallets:
        all_keys |= set(w.keys())
    unused = all_keys - read_keys
    if unused:
        print('  ! plist 有但代码未读: %s' % sorted(unused))
    else:
        print('  OK plist 字段全部被读取')

    # mode 值是否被处理
    for w in wallets:
        mode = w.get('mode', 'files')
        if '"%s"' % mode not in cp and "'%s'" % mode not in cp:
            P('mode=%s 代码未处理（%s）' % (mode, w.get('name')))


# ---------------------------------------------------------------- 7 库路径
def check_lib_paths():
    print('\n[7] dlopen 路径与符号判据')
    m = read(os.path.join(SRC, 'Container/OWMCM.m'))
    l = read(os.path.join(SRC, 'Container/OWMCMLease.m'))

    # 必须「取到符号」才算库可用，不能只看 dlopen 成功
    if 'container_query_create' in m and 'dlsym(h, "container_query_create")' in m:
        print('  OK OWMCM 按符号判据选库')
    else:
        P('OWMCM 只用 dlopen 成功判据（MobileContainerManager 能加载但不导出 C 函数）')

    if 'sandbox_extension_consume' in l and 'dlsym(h, "sandbox_extension_consume")' in l:
        print('  OK OWMCMLease 按符号判据选库')
    else:
        P('OWMCMLease 只用 dlopen 成功判据')

    if 'libSystem.B.dylib' in l:
        print('  OK 有 libSystem 兜底')
    else:
        print('  ? 无 libSystem 兜底（部分版本 sandbox 符号在 libSystem）')


# ---------------------------------------------------------------- 8 自检接线
def check_selftest_wiring():
    print('\n[8] OWSelfTest 是否被调用')
    found = []
    for f in src_files():
        if 'OWSelfTest' in norm(f):
            continue
        if 'OWSelfTest' in read(f):
            found.append(os.path.relpath(f, SRC))
    if found:
        print('  OK 被 %s 调用' % found)
    else:
        P('OWSelfTest 没有任何调用者（死代码）')
        print('  ! 无人调用')


# ---------------------------------------------------------------- main
def main():
    quiet = '--quiet' in sys.argv
    print('=' * 70)
    print('源码版深度审计（lint.py 之外）')
    print('=' * 70)

    check_syntax()
    check_dead_code()
    check_dataflow()
    check_lock_io()
    check_resources()
    check_error_codes()
    check_targets()
    check_lib_paths()
    check_selftest_wiring()

    print('\n' + '=' * 70)
    if problems:
        print('发现 %d 个问题：' % len(problems))
        for i, p in enumerate(problems, 1):
            print('  %d. %s' % (i, p))
        sys.exit(1)
    else:
        print('深度审计通过：无死代码、数据流一致、无持锁 IO、资源配对、错误码已用')
        sys.exit(0)


if __name__ == '__main__':
    main()
