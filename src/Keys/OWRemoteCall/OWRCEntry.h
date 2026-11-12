//
//  OWRCEntry.h
//  对外暴露的 C 入口（OWKeys 通过 dlsym 或直接链接调用）
//
//  这一层把"内核权限"翻译成三件具体的事：
//    1) rc_attach                —— 把函数注入到目标进程（默认 securityd）
//    2) rc_copy_file             —— 拷贝普通进程读不到的文件
//    3) rc_unwrap_class_keys     —— 取 keychain class keys（AKS 路径）
//       rc_export_keychain_items —— 取 keychain 明文（root + SecItem 路径，兜底）
//

#ifndef OW_RC_ENTRY_H
#define OW_RC_ENTRY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 当前是否具备内核权限（exploit 已成功且原语可用）
int rc_ready(void);

// 在目标进程里建立远程调用能力。processName 如 "securityd"、"SpringBoard"
int rc_attach(const char *processName);
int rc_detach(void);

// 特权文件拷贝：先 root + 脱沙箱，再走 POSIX 拷贝
int rc_copy_file(const char *src, const char *dst);

// AKS 路径：通过注入 securityd 解出 class keys。
// 成功返回 0，*outBytes 指向内部缓冲区（不要 free），*outLen 为长度。
int rc_unwrap_class_keys(const void **outBytes, unsigned int *outLen);

// 兜底路径：root 之后直接用 Security 框架把条目读成明文（keychain-dumper 的做法）。
// 成功返回 0，*outBytes 为 JSON 文本（内部缓冲区，不要 free）。
int rc_export_keychain_items(const void **outBytes, unsigned int *outLen);

const char *rc_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* OW_RC_ENTRY_H */
