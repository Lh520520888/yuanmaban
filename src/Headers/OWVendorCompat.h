//
//  OWVendorCompat.h
//  上游（lara）代码与本工程所用库之间的兼容层
//
//  作用：让搬进来的 TaskRop / offsets / utils 源码不改逻辑即可编译。
//  这里只做三件事：
//    1) 引入真实 XPF 与 libgrabkernel2 的头文件（上游版本），
//    2) 补上 lara 分支里独有的 xpf_gett1szboot()，
//    3) 把 lara 依赖的老版单参数 xpf_start_with_kernel_path 映射到上游三参数版本。
//

#ifndef OW_VENDOR_COMPAT_H
#define OW_VENDOR_COMPAT_H

#include <stdint.h>
#include <stdbool.h>

#include "xpf.h"          // 01-越狱内核/XPF/src
#include "grabkernel.h"   // 05-工具链/libgrabkernel2/include

// lara 的 XPF 分支私有：根据 pointer_mask 推 T1SZ_BOOT。
// 上游 XPF 没有导出，这里按同样算法补回，行为一致。
static inline uint64_t xpf_gett1szboot(void) {
    uint64_t pointer_mask = xpf_item_resolve("kernelConstant.pointer_mask");
    uint64_t T1SZ_BOOT = 0;
    for (uint64_t i = 64; i > 0; i--) {
        if (pointer_mask & (1ULL << (i - 1))) {
            T1SZ_BOOT++;
        }
    }
    return T1SZ_BOOT;
}

// 上游 XPF 的签名是 (kernelPath, optSptmPath, optTxmPath)。
// lara 按单参数调用。宏定义在 xpf.h 之后，故不会递归展开（蓝漆规则）。
// 需要传 SPTM/TXM 的调用点请直接写全三个参数，不要走这个宏。
#define xpf_start_with_kernel_path(p) xpf_start_with_kernel_path((p), NULL, NULL)

#endif /* OW_VENDOR_COMPAT_H */
