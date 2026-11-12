#!/usr/bin/env python3
# 源码版静态自检：括号配对、头文件声明与实现匹配、资源引用完整性。
# 在 Windows 侧没有 iOS 工具链，用它做编译前的兜底检查。
import re, os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
problems = []

def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()

def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    return s

def mask_literals(s):
    """把字符串/字符字面量掏空，避免其中的括号、引号干扰配对与选择器解析。"""
    out = []
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if ch == '"':
            j = i + 1
            while j < n:
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == '"':
                    break
                j += 1
            out.append('""')
            i = j + 1
        elif ch == "'":
            j = i + 1
            while j < n:
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == "'":
                    break
                j += 1
            out.append("''")
            i = j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)

def balance(path, src):
    src = mask_literals(src)
    pairs = {"{": "}", "(": ")", "[": "]"}
    stack = []
    for i, ch in enumerate(src):
        if ch in pairs:
            stack.append((ch, i))
        elif ch in pairs.values():
            if not stack:
                problems.append(f"{path}: 多余的 {ch}")
                return
            op, _ = stack.pop()
            if pairs[op] != ch:
                problems.append(f"{path}: 括号不匹配 {op} vs {ch}")
                return
    if stack:
        problems.append(f"{path}: 未闭合 {stack[-1][0]} 共 {len(stack)} 处")

SEL_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*:")

def selector_of(decl):
    """从 '- (int)run:(id)x error:(NSError **)e;' 提取 'run:error:'"""
    body = decl.split(")", 1)[1] if ")" in decl else decl
    parts = SEL_RE.findall(body)
    head = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", body)
    if head and not body.lstrip().startswith(tuple(SEL_RE.findall(body) or ["\0"])):
        name = head.group(1)
    else:
        name = ""
    return (name + ":".join(parts) + (":" if parts else ""))

def declared_selectors(h_src):
    out = set()
    for line in h_src.splitlines():
        line = line.strip()
        if line.startswith("- (") or line.startswith("+ ("):
            if line.rstrip().endswith(";"):
                out.add(selector_of(line))
    return out

def implemented_selectors(m_src):
    """提取实现里的方法选择器。允许 '{' 在下一行（上游代码常见写法）。"""
    out = set()
    # 返回类型里可能含括号（如 (NSMutableArray<NSNumber *> *)），用一个宽松匹配：
    # 行首 +/- 后紧跟一个括号组，然后一直到第一个 '{' 之间没有 ';' 或 '='
    for m in re.finditer(r"^[-+]\s*\([\s\S]*?\)\s*(?P<body>[^{;=]*?)\s*\{",
                         m_src, flags=re.M):
        sel = selector_of("- (void)" + m.group("body"))
        if sel:
            out.add(sel)
    return out

def norm(s):
    """归一化：去掉空白与指针星号，便于跨风格比对。"""
    return re.sub(r"\s+", "", s).replace("*", "")

def rel_src(p):
    return os.path.relpath(p, ROOT).replace("\\", "/")

def non_vendor_m_files():
    out = []
    for dp, _, fs in os.walk(ROOT):
        rel = rel_src(dp)
        if "vendor" in rel.split("/"):
            continue
        for f in fs:
            if f.endswith(".m"):
                out.append(os.path.join(dp, f))
    return out

def check_include_paths():
    """Makefile 的 -I 必须覆盖所有存放本地头文件的目录。

    之前漏了 Common/Exfil/Kernel/Orchestrator/App/Cleanup，
    #import "OWCommon.h" 这类写法在 macOS 上会直接报 file not found。
    """
    mk = read(os.path.join(ROOT, "Makefile"))
    base_map = {"CURDIR": "", "RC": "Keys/OWRemoteCall", "VENDOR": "Keys/OWRemoteCall/vendor"}
    covered = set()
    for var, sub in re.findall(r"-I\$\((CURDIR|RC|VENDOR)\)(?:(/[A-Za-z0-9_]+))?", mk):
        prefix = base_map[var]
        rel = (prefix + sub).strip("/")
        covered.add(rel)

    need = set()
    for dp, _, fs in os.walk(ROOT):
        rel = rel_src(dp)
        if any(h.endswith(".h") for h in fs):
            need.add(rel)
    # vendor 目录由 -I$(VENDOR) / -I$(VENDOR)/pe 统一覆盖
    need = {d for d in need if not d.startswith("Keys/OWRemoteCall/vendor")}
    # Resources/prebuilt 是从目标包提取的第三方 framework（kfd/weightBufs/...），
    # 头文件不参与本工程编译（我们全用 dlsym 访问），不需要 -I
    need = {d for d in need if not d.startswith("Resources/prebuilt")}
    for d in sorted(need):
        if d not in covered:
            problems.append(f"Makefile 缺少头文件搜索路径 -I$(CURDIR)/{d}")

def check_void_return_misuse():
    """把返回 void 的函数当返回值用（如 ds_kreadbuf(...) != 0）会编译失败或判断失真。"""
    void_names = set()
    for dp, _, fs in os.walk(ROOT):
        for f in fs:
            if not f.endswith(".h"):
                continue
            src = strip_comments(read(os.path.join(dp, f)))
            void_names |= set(re.findall(r"^\s*void\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", src, flags=re.M))
    void_names -= {"if", "for", "while", "return", "else", "switch"}
    if not void_names:
        return
    pat = re.compile(r"\b(" + "|".join(sorted(map(re.escape, void_names))) + r")\s*\([^;\n]*\)\s*(?:!=|==)\s*[A-Za-z0-9_]")
    for p in non_vendor_m_files():
        src = strip_comments(read(p))
        for m in pat.finditer(src):
            line = src[:m.start()].count("\n") + 1
            problems.append(f"{rel_src(p)}:{line}: {m.group(1)} 返回 void，却被用于条件判断")

def check_vendor_exit():
    """vendor 里出现 exit() 会在运行时直接杀掉宿主进程，必须改成可返回的错误。"""
    for dp, _, fs in os.walk(os.path.join(ROOT, "Keys", "OWRemoteCall", "vendor")):
        for f in fs:
            if not f.endswith((".m", ".c", ".h")):
                continue
            p = os.path.join(dp, f)
            src = strip_comments(read(p))
            for m in re.finditer(r"\bexit\s*\(", src):
                line = src[:m.start()].count("\n") + 1
                problems.append(f"{rel_src(p)}:{line}: vendor 代码调用 exit()，会终止宿主进程")

def check_offsets_wired():
    """offsets_init() 定义了却没人调用，等于 proc/ucred 偏移永远是 0。"""
    body = "\n".join(strip_comments(read(p)) for p in non_vendor_m_files())
    if "offsets_init" not in body:
        problems.append("offsets_init() 从未被本工程代码调用，proc/ucred 偏移不会被填")

def main():
    for dirpath, _, files in os.walk(ROOT):
        for fn in files:
            if not fn.endswith((".h", ".m")):
                continue
            p = os.path.join(dirpath, fn)
            src = strip_comments(read(p))
            rel = os.path.relpath(p, ROOT)
            balance(rel, src)

            if fn.endswith(".h"):
                m_path = os.path.join(dirpath, fn[:-2] + ".m")
                if not os.path.exists(m_path):
                    continue
                m_src = strip_comments(read(m_path))
                impl = implemented_selectors(m_src)
                for sel in sorted(declared_selectors(src)):
                    if not sel:
                        continue
                    if sel not in impl:
                        problems.append(f"{rel}: 声明了 {sel} 但 {os.path.basename(m_path)} 未实现")

    # 资源引用检查（只看我们自己的代码，vendor 目录里的上游引用不归本工程管）
    m_src_all = "\n".join(
        read(os.path.join(dp, f))
        for dp, _, fs in os.walk(ROOT) for f in fs
        if f.endswith(".m") and "vendor" not in os.path.relpath(dp, ROOT).replace("\\", "/")
    )
    res = os.path.join(ROOT, "Resources")
    have = set(os.listdir(res)) if os.path.isdir(res) else set()
    for name in ("targets.plist", "VarCleanRules.json", "cover.html"):
        if name not in have:
            problems.append(f"Resources 缺失 {name}")
    for name in re.findall(r'pathForResource:@"([^"]+)" ofType:@"([^"]+)"', m_src_all):
        fn = f"{name[0]}.{name[1]}"
        if fn not in have:
            problems.append(f"代码引用了不存在的资源 {fn}")

    # Makefile 文件列表与实际文件比对
    mk = read(os.path.join(ROOT, "Makefile"))
    listed = set(re.findall(r"^\s+((?:[A-Za-z0-9_]+/)+[A-Za-z0-9_]+\.m)\s*\\?$", mk, flags=re.M))
    actual = set()
    for dp, _, fs in os.walk(ROOT):
        for f in fs:
            if f.endswith(".m"):
                actual.add(os.path.relpath(os.path.join(dp, f), ROOT).replace("\\", "/"))
    for a in sorted(actual - listed):
        problems.append(f"Makefile 未收录 {a}")
    for l in sorted(listed - actual):
        problems.append(f"Makefile 收录了不存在的文件 {l}")

    # ---- 编译/运行阻断类检查（本轮审计新增）----
    check_include_paths()
    check_void_return_misuse()
    check_vendor_exit()
    check_offsets_wired()

    if problems:
        print(f"发现 {len(problems)} 个问题：")
        for x in problems:
            print("  -", x)
        return 1
    print("静态自检通过：括号配对、声明/实现匹配、资源与 Makefile 收录、"
          "头文件路径、void 误用、vendor exit、偏移接线")
    return 0

if __name__ == "__main__":
    sys.exit(main())
