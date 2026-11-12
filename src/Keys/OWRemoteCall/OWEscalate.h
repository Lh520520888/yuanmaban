//
//  OWEscalate.h
//  内核权限 → 本进程 root + 脱离沙箱
//
//  有了内核读写之后，读取 /var/mobile/Library/... 这类系统区域数据的关键不在
//  「能不能读文件」，而在「本进程是不是 root、有没有沙箱」。这两步做完，
//  后面的 keychain-2.db / sms.db / AddressBook 就都是普通 POSIX 拷贝。
//

#ifndef OW_ESCALATE_H
#define OW_ESCALATE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 准备 proc/ucred 偏移表（init_offsets + offsets_init，带版本守卫）。
// 返回 0 表示偏移就绪；-2 表示表里有字段没填；-3 表示版本不在覆盖范围。
int  ow_prepare_offsets(void);

// 返回 0 表示本进程已具备 root + 无沙箱
int  ow_escalate(void);
bool ow_is_root(void);
bool ow_is_unsandboxed(void);

// 诊断：最近一次失败原因
const char *ow_escalate_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* OW_ESCALATE_H */
