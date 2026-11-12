//
//  OWPrimitives.m
//  见 OWPrimitives.h
//

#import "OWPrimitives.h"
#import "darksword.h"
#import "xpaci.h"
#import "utils.h"
#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

// ---------------------------------------------------------------------------
// 原语绑定
// ---------------------------------------------------------------------------

// libjailbreak 的 struct kernel_primitives（primitives_external.h）
// 这里只用到前几个字段，按上游结构体前半部分声明即可。
// 字段顺序与 BaseBin/libjailbreak/src/primitives_external.h 完全一致
typedef void (*ow_kexec_fn)(void *state);
typedef struct {
    int (*kreadbuf)(uint64_t kaddr, void *output, size_t size);
    int (*kwritebuf)(uint64_t kaddr, const void *input, size_t size);
    int (*physreadbuf)(uint64_t physaddr, void *output, size_t size);
    int (*physwritebuf)(uint64_t physaddr, const void *input, size_t size);
    unsigned krwMinSafeReadSize;
    uint64_t (*kcall)(uint64_t func, int argc, const uint64_t *argv);
    ow_kexec_fn kexec;
    int (*kalloc_global)(uint64_t *addr, uint64_t size);
    int (*kalloc_local)(uint64_t *addr, uint64_t size);
    int (*kfree_global)(uint64_t addr, uint64_t size);
    int (*kmap)(uint64_t pa, uint64_t size, void **uaddr);
    int (*physaccess_mapped)(uint64_t pa, uint64_t size, void *accessorBlock);
    uint64_t (*vtophys)(uint64_t ttep, uint64_t va);
    uint64_t (*phystokv)(uint64_t pa);
} ow_kernel_primitives_t;

typedef int (*ow_kreadbuf_fn)(uint64_t, void *, size_t);
typedef int (*ow_kwritebuf_fn)(uint64_t, const void *, size_t);

// ★ 关于 gPrimitives 的归属：
//   exploit framework（kfd/weightBufs/...）成功后会把 kreadbuf/kwritebuf
//   写进符号 gPrimitives（见 kfd.m:279-281）。
//   已确认 libjailbreak.dylib 导出 _gPrimitives / _kreadbuf / _kwritebuf，
//   所以正确做法是「链 libjailbreak 并用它导出的那个」，不要自己定义 ——
//   重复定义会与 dylib 的符号冲突（duplicate symbol）。
//   这里用弱引用：没链 libjailbreak 时退化为 NULL（由 dlsym 兜底），
//   已链时直接用 dylib 里的实体。
__attribute__((weak))
extern ow_kernel_primitives_t gPrimitives;

static ow_kernel_primitives_t *gOWPrims = NULL;
static ow_kreadbuf_fn  gDirectRead  = NULL;
static ow_kwritebuf_fn gDirectWrite = NULL;
static bool gBound = false;

// darksword.h 声明的全局量（上游代码会引用，必须提供定义）
int      control_socket = -1;
int      rw_socket      = -1;
uint64_t kernel_base    = 0;
uint64_t kernel_slide   = 0;

static ow_primitive_log_cb gLogCb = NULL;
static pthread_mutex_t     gLock = PTHREAD_MUTEX_INITIALIZER;

static void owlog(const char *fmt, ...) {
    if (!gLogCb) return;
    char buf[512];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    gLogCb(buf);
}

// 显式把 bundle 里的 libjailbreak.dylib 载入全局符号表。
// 通道 A 现在由上游源码自建，libjailbreak 放在 App 根目录（install_name
// @executable_path/libjailbreak.dylib），这里两条路径都试，保证 gPrimitives 可见。
static void *ow_open_jailbreak(void) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *cands[] = {
            "@executable_path/libjailbreak.dylib",
            "@executable_path/Frameworks/libjailbreak.dylib",
            NULL,
        };
        for (int i = 0; cands[i] && !handle; i++) {
            handle = dlopen(cands[i], RTLD_NOW | RTLD_GLOBAL);
        }
        if (!handle) {
            NSString *p = [[[NSBundle mainBundle] bundlePath]
                           stringByAppendingPathComponent:@"libjailbreak.dylib"];
            if (p.length) {
                handle = dlopen(p.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            }
        }
        if (!handle) {
            owlog("libjailbreak 未加载（没有内核原语来源）: %s", dlerror());
        }
    });
    return handle;
}

int ow_bind_primitives(void) {
    pthread_mutex_lock(&gLock);

    // 0) 先显式把 libjailbreak 拉进全局符号表。
    //    exploit framework 是用 @executable_path/libjailbreak.dylib 依赖它的，
    //    但若 framework 还没 dlopen，主程序里 dlsym(RTLD_DEFAULT) 找不到 gPrimitives。
    //    RTLD_GLOBAL 保证后续 dlsym(RTLD_DEFAULT) 能命中。
    void *jb = ow_open_jailbreak();

    // 1) 首选：libjailbreak 导出的 gPrimitives（exploit framework 会写它）
    gOWPrims = (ow_kernel_primitives_t *)dlsym(RTLD_DEFAULT, "gPrimitives");
    if (!gOWPrims && jb) {
        gOWPrims = (ow_kernel_primitives_t *)dlsym(jb, "gPrimitives");
    }

    // 2) 兜底：framework 直接把 kreadbuf/kwritebuf 导出（multicast_bytecopy 这类）
    gDirectRead  = (ow_kreadbuf_fn)dlsym(RTLD_DEFAULT, "kreadbuf");
    gDirectWrite = (ow_kwritebuf_fn)dlsym(RTLD_DEFAULT, "kwritebuf");
    if (!gDirectRead && jb)  gDirectRead  = (ow_kreadbuf_fn)dlsym(jb, "kreadbuf");
    if (!gDirectWrite && jb) gDirectWrite = (ow_kwritebuf_fn)dlsym(jb, "kwritebuf");

    gBound = true;
    int ok = (gOWPrims && gOWPrims->kreadbuf && gOWPrims->kwritebuf) ||
             (gDirectRead && gDirectWrite);
    owlog("primitives bind: jb=%p gPrimitives=%p kread=%p kwrite=%p direct=%p/%p -> %s",
          jb, (void *)gOWPrims,
          gOWPrims ? (void *)gOWPrims->kreadbuf : NULL,
          gOWPrims ? (void *)gOWPrims->kwritebuf : NULL,
          (void *)gDirectRead, (void *)gDirectWrite,
          ok ? "OK" : "NONE");
    pthread_mutex_unlock(&gLock);
    return ok ? 0 : -1;
}

bool ow_primitives_available(void) {
    if (!gBound) ow_bind_primitives();
    return (gOWPrims && gOWPrims->kreadbuf && gOWPrims->kwritebuf) ||
           (gDirectRead && gDirectWrite);
}

void ow_set_primitive_log_callback(ow_primitive_log_cb cb) { gLogCb = cb; }

// ---------------------------------------------------------------------------
// 基址
// ---------------------------------------------------------------------------

void ow_set_kernel_base(uint64_t base)   { kernel_base  = base; }
void ow_set_kernel_slide(uint64_t slide) { kernel_slide = slide; }
uint64_t ow_kernel_base(void)   { return kernel_base; }
uint64_t ow_kernel_slide(void)  { return kernel_slide; }

// ---------------------------------------------------------------------------
// 读写
// ---------------------------------------------------------------------------

int ow_kreadbuf(uint64_t kaddr, void *out, size_t size) {
    if (!kaddr || !out || !size) return -1;
    if (!ow_primitives_available()) return -2;
    if (gOWPrims && gOWPrims->kreadbuf) {
        return gOWPrims->kreadbuf(kaddr, out, size);
    }
    if (gDirectRead) return gDirectRead(kaddr, out, size);
    return -2;
}

int ow_kwritebuf(uint64_t kaddr, const void *in, size_t size) {
    if (!kaddr || !in || !size) return -1;
    if (!ow_primitives_available()) return -2;
    if (gOWPrims && gOWPrims->kwritebuf) {
        return gOWPrims->kwritebuf(kaddr, (void *)in, size);
    }
    if (gDirectWrite) return gDirectWrite(kaddr, in, size);
    return -2;
}

uint64_t ow_kread64(uint64_t kaddr) {
    uint64_t v = 0;
    if (ow_kreadbuf(kaddr, &v, sizeof(v)) != 0) return 0;
    return v;
}

int ow_kwrite64(uint64_t kaddr, uint64_t v) {
    return ow_kwritebuf(kaddr, &v, sizeof(v));
}

int ow_kalloc_global(uint64_t *outAddr, uint64_t size) {
    if (!outAddr || !size) return -1;
    if (!ow_primitives_available()) return -2;
    if (gOWPrims && gOWPrims->kalloc_global) return gOWPrims->kalloc_global(outAddr, size);
    return -3;
}

uint64_t ow_kcall(uint64_t func, int argc, const uint64_t *argv) {
    if (!ow_primitives_available()) return 0;
    if (gOWPrims && gOWPrims->kcall) return gOWPrims->kcall(func, argc, argv);
    return 0;
}

// ---------------------------------------------------------------------------
// ds_* 接口（darksword.h）
// ---------------------------------------------------------------------------

void ds_set_log_callback(ds_log_callback_t callback) {
    gLogCb = (ow_primitive_log_cb)callback;
}
void ds_set_progress_callback(ds_progress_callback_t callback) {
    // 上游用它把利用进度回传给 UI。本工程没有独立的 exploit 进度阶段
    // （内核权限由 OWKernelChain 用日志汇报），保留空实现以维持 ABI，
    // 但不做任何事 —— 这是刻意降级，不是漏写。
    (void)callback;
}

// 上游用 ds_run() 触发它自己的利用。我们这边内核权限由 OWKernelChain 建立，
// 所以这里只做「是否已具备内核读写」的判定，不再另起一套利用。
int ds_run(void) {
    return ow_primitives_available() ? 0 : -1;
}

bool ds_is_ready(void) {
    return ow_primitives_available();
}

bool ds_isvalid(uint64_t addr) {
    if (!addr) return false;
    uint64_t base = kernel_base ? kernel_base : 0xfffffff007004000ULL;
    // 内核地址落在静态基址上下 0x40000000 范围内视为有效
    return (addr > (base - 0x40000000ULL)) && (addr < (base + 0x40000000ULL));
}

uint64_t ds_kread64(uint64_t address)  { return ow_kread64(address); }

uint32_t ds_kread32(uint64_t address) {
    uint32_t v = 0;
    ow_kreadbuf(address, &v, sizeof(v));
    return v;
}

uint16_t ds_kread16(uint64_t addr) {
    uint16_t v = 0;
    ow_kreadbuf(addr, &v, sizeof(v));
    return v;
}

uint8_t ds_kread8(uint64_t addr) {
    uint8_t v = 0;
    ow_kreadbuf(addr, &v, sizeof(v));
    return v;
}

void ds_kwrite64(uint64_t address, uint64_t value) { ow_kwritebuf(address, &value, sizeof(value)); }
void ds_kwrite32(uint64_t address, uint32_t value) { ow_kwritebuf(address, &value, sizeof(value)); }
void ds_kwrite16(uint64_t addr, uint16_t val)      { ow_kwritebuf(addr, &val, sizeof(val)); }
void ds_kwrite8(uint64_t what, uint8_t val)        { ow_kwritebuf(what, &val, sizeof(val)); }

void ds_kread(uint64_t address, void *buffer, uint64_t size) {
    ow_kreadbuf(address, buffer, (size_t)size);
}
void ds_kwrite(uint64_t address, void *buffer, uint64_t size) {
    ow_kwritebuf(address, buffer, (size_t)size);
}
void ds_kreadbuf(uint64_t addr, void *buf, uint64_t len) {
    ow_kreadbuf(addr, buf, (size_t)len);
}
void ds_kwritebuf(uint64_t addr, const void *buf, uint64_t len) {
    ow_kwritebuf(addr, buf, (size_t)len);
}

// DarkSword 的 zone element 写入：本工程没有该原语，退化为普通写入。
// 上游只在特定 kalloc 路径用它，退化后功能不受影响（只是少了越界保护语义）。
void ds_kwritezoneelement(uint64_t dst, const void *src, uint64_t len) {
    ow_kwritebuf(dst, src, (size_t)len);
}

void ds_khexdump(uint64_t addr, size_t size) {
    if (!ow_primitives_available()) { owlog("khexdump: 无内核权限"); return; }
    uint8_t line[16];
    for (size_t off = 0; off < size; off += 16) {
        size_t n = size - off > 16 ? 16 : size - off;
        if (ow_kreadbuf(addr + off, line, n) != 0) { owlog("khexdump: 读失败 @0x%llx", addr + off); return; }
        char out[16 * 3 + 1]; char *p = out;
        for (size_t i = 0; i < n; i++) p += snprintf(p, 4, "%02x ", line[i]);
        owlog("0x%llx: %s", addr + off, out);
    }
}

// 指针读取：arm64e 上内核指针带 PAC，需要剥离后再用
uint64_t ds_kreadptr(uint64_t va) {
    uint64_t v = ow_kread64(va);
    if (!v) return 0;
    return xpaci(v);
}

// SMR（shared memory region）指针：按上游语义先读再按需剥 PAC
uint64_t ds_kreadsmrptr(uint64_t va) {
    uint64_t v = ow_kread64(va);
    if (!v) return 0;
    return xpaci(v);
}

// kalloc 数组递减：上游 DarkSword 专用，本工程无对应原语，返回 0 表示不可用。
// 调用点只有 RemoteCall.m / utils.m 里 `if (!is_pac_supported())` 分支，
// arm64e（A12 及以上）永远进不去，因此对目标机型无影响；
// 非 arm64e（A11 及以下）会在这里拿不到 table，进而 attach 失败 —— 属预期。
uint64_t ds_kallocarrdec(uint64_t ptr) {
    (void)ptr;
    return 0;
}

uint64_t ds_get_kernel_base(void)  { return kernel_base; }
uint64_t ds_get_kernel_slide(void) { return kernel_slide; }

// DarkSword 的 socket-based 原语：依赖它自己 exploit 建立的 rw_socket。
// 本工程的内核读写来自 libjailbreak，没有这个 socket，故返回 0 表示不可用。
// procbysock / procbysock_hardcoded 会因此直接返回 0，ourproc() 随后走
// procbypid()（kernproc / allproc 链表）—— 该路径由 OWKernelChain 落盘的
// lara.allprocoff 支撑。
uint64_t ds_get_pcbinfo(void)       { return 0; }
uint64_t ds_get_rw_socket_pcb(void) { return 0; }

uint64_t ds_get_our_proc(void) {
    if (!ow_primitives_available()) return 0;
    pid_t pid = getpid();
    uint64_t proc = procbypid(pid);
    if (!proc) proc = ourproc();
    return proc;
}

uint64_t ds_get_our_task(void) {
    uint64_t proc = ds_get_our_proc();
    if (!proc) return 0;
    return taskbyproc(proc);
}
