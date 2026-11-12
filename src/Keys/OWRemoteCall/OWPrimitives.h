//
//  OWPrimitives.h
//  内核原语适配层：把 Dopamine/libjailbreak 的原语包装成上游（lara）的 ds_* 接口
//
//  这样搬进来的 TaskRop / offsets / utils 源码不需要改逻辑即可工作，
//  而内核权限的来源换成我们自己的 OWKernelChain（Dopamine 的 exploit 队列）。
//

#ifndef OW_PRIMITIVES_H
#define OW_PRIMITIVES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- 原语来源 ----
// 1) libjailbreak 的 gPrimitives（exploit 成功后由 exploit framework 填充）
// 2) 直接导出的 kreadbuf/kwritebuf（kfd 系）
// 两者都拿不到即为「无内核权限」，所有 ds_* 返回失败，调用方自然降级。
bool ow_primitives_available(void);
int  ow_bind_primitives(void);          // 重新探测（exploit 成功后调用）

// ---- 内核基址 ----
// 由 OWKernelChain 在 XPF 解析出偏移字典后回填（kernelConstant.base / .slide）
void     ow_set_kernel_base(uint64_t base);
void     ow_set_kernel_slide(uint64_t slide);
uint64_t ow_kernel_base(void);
uint64_t ow_kernel_slide(void);

// ---- 原始读写（本层内部统一入口，外部也可直接用）----
int      ow_kreadbuf(uint64_t kaddr, void *out, size_t size);
int      ow_kwritebuf(uint64_t kaddr, const void *in, size_t size);
uint64_t ow_kread64(uint64_t kaddr);
int      ow_kwrite64(uint64_t kaddr, uint64_t v);

// ---- 分配 / 调用（供提权与沙箱逃逸使用）----
int      ow_kalloc_global(uint64_t *outAddr, uint64_t size);
uint64_t ow_kcall(uint64_t func, int argc, const uint64_t *argv);

// ---- 日志回传（可选）----
typedef void (*ow_primitive_log_cb)(const char *msg);
void ow_set_primitive_log_callback(ow_primitive_log_cb cb);

#ifdef __cplusplus
}
#endif

#endif /* OW_PRIMITIVES_H */
