//
//  OWSelfTest.m
//  OPENsrc
//

#import "OWSelfTest.h"
#import "OWCommon.h"
#import "OWMCM.h"
#import "OWMCMLease.h"
#import "OWLaunchServices.h"
#import "OWKernelChain.h"
#import <dlfcn.h>
#import <unistd.h>
#import <Security/Security.h>

@implementation OWSelfTestResult
- (NSString *)description {
    return [NSString stringWithFormat:@"[%@] %@ %@%@",
            _code, _name, _passed ? @"PASS" : @"FAIL",
            _detail.length ? [NSString stringWithFormat:@" — %@", _detail] : @""];
}
@end

@interface OWSelfTest ()
@property (nonatomic, strong) NSMutableArray<OWSelfTestResult *> *acc;
@property (nonatomic, copy, readwrite) NSArray<OWSelfTestResult *> *lastResults;
@end

@implementation OWSelfTest

+ (instancetype)shared {
    static OWSelfTest *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OWSelfTest new]; });
    return s;
}

#pragma mark 工具

- (OWSelfTestResult *)add:(NSString *)code
                     name:(NSString *)name
                   passed:(BOOL)passed
                   detail:(NSString *)detail
                  elapsed:(NSTimeInterval)elapsed {
    OWSelfTestResult *r = [OWSelfTestResult new];
    r.code = code;
    r.name = name;
    r.passed = passed;
    r.detail = detail;
    r.elapsed = elapsed;
    [_acc addObject:r];
    OWLog(@"SELFTEST %@", r);
    return r;
}

#pragma mark 通道 B

- (NSArray<OWSelfTestResult *> *)runChannelB {
    _acc = [NSMutableArray array];
    OWLog(@"======== SELFTEST 通道B ========");

    // B0 库加载
    NSDate *t0 = [NSDate date];
    OWMCMStatus st = [[OWMCM shared] prepare];
    NSTimeInterval e0 = -[t0 timeIntervalSinceNow];
    BOOL b0 = (st != OWMCMStatusLibNotFound);
    [self add:@"B0" name:@"libsystem_container 加载" passed:b0
        detail:b0 ? @"OK" : [OWMCM shared].lastError elapsed:e0];

    // B1 符号绑定
    BOOL b1 = (st == OWMCMStatusOK);
    [self add:@"B1" name:@"必需符号绑定" passed:b1
        detail:b1 ? @"10/10" : [OWMCM shared].lastError elapsed:0];

    // B2 身份
    NSString *ident = [OWMCM shared].signedIdentity;
    BOOL b2 = [OWMCM shared].identityOK;
    [self add:@"B2" name:@"签名身份 = MHA" passed:b2
        detail:b2 ? ident : [NSString stringWithFormat:@"实际=%@ 期望=com.apple.mobile.MobileHouseArrest",
                             ident ?: @"(nil)"] elapsed:0];

    if (!b1) {
        OWLog(@"SELFTEST: B1 失败，跳过 B3-B5");
        _lastResults = [_acc copy];
        return _lastResults;
    }

    // B3 容器枚举
    t0 = [NSDate date];
    NSError *err = nil;
    NSArray<OWMCMContainer *> *apps = [[OWMCM shared] containersOfClass:OWMCMClassApplicationData
                                                           identifiers:nil error:&err];
    NSTimeInterval e3 = -[t0 timeIntervalSinceNow];
    BOOL b3 = apps.count > 0;
    [self add:@"B3" name:@"App Data 容器枚举" passed:b3
        detail:b3 ? [NSString stringWithFormat:@"%lu 个", (unsigned long)apps.count]
                  : (err.localizedDescription ?: @"0 个（授权被拒或没装 App）")
        elapsed:e3];

    // B3b app-group
    NSArray<OWMCMContainer *> *groups = [[OWMCM shared] containersOfClass:OWMCMClassAppGroup
                                                             identifiers:nil error:nil];
    [self add:@"B3b" name:@"App Group 容器枚举" passed:groups.count > 0
        detail:[NSString stringWithFormat:@"%lu 个", (unsigned long)groups.count] elapsed:0];

    // B4 sandbox token
    t0 = [NSDate date];
    BOOL b4 = NO;
    NSString *b4detail = @"无容器可测";
    OWMCMContainer *probe = apps.firstObject;
    if (probe) {
        NSString *reason = nil;
        b4 = [[OWMCMLease shared] activateContainer:probe reason:&reason];
        b4detail = b4 ? [NSString stringWithFormat:@"handle ok id=%@", probe.identifier]
                      : (reason ?: @"失败");
    }
    [self add:@"B4" name:@"sandbox token 消费" passed:b4 detail:b4detail
        elapsed:-[t0 timeIntervalSinceNow]];

    // B5 实际读文件
    if (b4 && probe) {
        t0 = [NSDate date];
        NSError *lerr = nil;
        NSArray *files = [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath:probe.path error:&lerr];
        BOOL b5 = files.count > 0;
        [self add:@"B5" name:@"实际读容器目录" passed:b5
            detail:b5 ? [NSString stringWithFormat:@"%lu 项 %@", (unsigned long)files.count,
                         probe.path.lastPathComponent]
                      : (lerr.localizedDescription ?: @"目录为空")
            elapsed:-[t0 timeIntervalSinceNow]];
        [[OWMCMLease shared] releasePath:probe.path];
    } else {
        [self add:@"B5" name:@"实际读容器目录" passed:NO detail:@"B4 未通过，跳过" elapsed:0];
    }

    // LS 映射（诊断信息，不算 pass/fail）
    NSUInteger ls = [[OWLaunchServices shared] load];
    [self add:@"B6" name:@"LaunchServices 映射" passed:ls > 0
        detail:[OWLaunchServices shared].status elapsed:0];

    [[OWMCMLease shared] releaseAll];
    _lastResults = [_acc copy];
    OWLog(@"======== SELFTEST 通道B 结束：%lu 项，%lu 通过 ========",
          (unsigned long)_acc.count,
          (unsigned long)[[_acc filteredArrayUsingPredicate:
              [NSPredicate predicateWithFormat:@"passed == YES"]] count]);
    return _lastResults;
}

#pragma mark 通道 A

- (NSArray<OWSelfTestResult *> *)runChannelA {
    _acc = [NSMutableArray array];
    OWLog(@"======== SELFTEST 通道A ========");

    void *h = dlopen(NULL, RTLD_NOW);

    // A0 kernelcache 获取（真实调用 OWKernelChain）
    NSDate *t0 = [NSDate date];
    OWKernelChain *kc = [OWKernelChain new];
    NSError *kerr = nil;
    NSString *kcPath = [kc resolveKernelCache:&kerr];
    BOOL a0 = kcPath.length > 0;
    NSString *a0detail;
    if (a0) {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:kcPath error:nil];
        a0detail = [NSString stringWithFormat:@"%@ %llu B", kcPath.lastPathComponent,
                    [attr fileSize]];
    } else {
        a0detail = kerr.localizedDescription ?: @"获取失败";
    }
    [self add:@"A0" name:@"kernelcache 获取" passed:a0 detail:a0detail
        elapsed:-[t0 timeIntervalSinceNow]];

    // A1 XPF 符号
    BOOL hasXPF = h && dlsym(h, "xpf_start_with_kernel_path");
    [self add:@"A1" name:@"XPF 符号可用" passed:hasXPF
        detail:hasXPF ? @"dlsym OK" : @"缺 libxpf.dylib（检查 Frameworks/）" elapsed:0];

    // A1b 偏移解析（真实调用；需要 A0 + A1 都通过）
    if (a0 && hasXPF) {
        t0 = [NSDate date];
        NSError *oerr = nil;
        BOOL ok = [kc resolveOffsets:&oerr];
        [self add:@"A1b" name:@"XPF 偏移解析" passed:ok
            detail:ok ? [NSString stringWithFormat:@"base=0x%llx slide=0x%llx",
                         kc.kernelBase, kc.kernelSlide]
                      : (oerr.localizedDescription ?: @"patchfind 失败")
            elapsed:-[t0 timeIntervalSinceNow]];
    } else {
        [self add:@"A1b" name:@"XPF 偏移解析" passed:NO detail:@"A0/A1 未通过，跳过" elapsed:0];
    }

    // A2 exploit framework
    NSString *fwDir = [[[NSBundle mainBundle] bundlePath]
                       stringByAppendingPathComponent:@"Frameworks"];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fwDir error:nil];
    NSUInteger exploitCount = 0;
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *it in items) {
        if (![it hasSuffix:@".framework"]) continue;
        NSString *pl = [[fwDir stringByAppendingPathComponent:it]
                        stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:pl];
        if (d[@"DPExploitType"]) {
            exploitCount++;
            [names addObject:[it stringByDeletingPathExtension]];
        }
    }
    [self add:@"A2" name:@"exploit framework 入包" passed:exploitCount > 0
        detail:exploitCount ? [NSString stringWithFormat:@"%lu 个: %@",
                               (unsigned long)exploitCount, [names componentsJoinedByString:@","]]
                            : @"0 个（跑 link_exploits.sh）"
        elapsed:0];

    // A2b 候选枚举（真实调用；会按设备版本过滤）
    if (exploitCount > 0) {
        NSArray *cands = [kc candidatesOfType:OWExploitTypeKernel];
        NSMutableArray *cn = [NSMutableArray array];
        for (OWExploitEntry *e in cands) [cn addObject:[NSString stringWithFormat:@"%@:%@",
                                                         e.identifier, e.flavorName]];
        [self add:@"A2b" name:@"本设备可用候选" passed:cands.count > 0
            detail:cands.count ? [cn componentsJoinedByString:@", "] : @"无候选（版本/机型不在支持范围）"
            elapsed:0];
    } else {
        [self add:@"A2b" name:@"本设备可用候选" passed:NO detail:@"A2 未通过，跳过" elapsed:0];
    }

    // A3 KRW 原语
    BOOL hasPrim = h && (dlsym(h, "gPrimitives") || dlsym(h, "kreadbuf"));
    [self add:@"A3" name:@"KRW 原语符号" passed:hasPrim
        detail:hasPrim ? @"OK" : @"缺 libjailbreak（exploit 成功前正常）" elapsed:0];

    // A4 提权
    BOOL a4 = getuid() == 0;
    [self add:@"A4" name:@"进程已 root" passed:a4
        detail:[NSString stringWithFormat:@"uid=%d", getuid()] elapsed:0];

    _lastResults = [_acc copy];
    OWLog(@"======== SELFTEST 通道A 结束 ========");
    return _lastResults;
}

#pragma mark Keychain

- (NSArray<OWSelfTestResult *> *)runKeychain {
    _acc = [NSMutableArray array];
    OWLog(@"======== SELFTEST Keychain ========");

    NSString *dbPath = @"/var/mobile/Library/Keychains/keychain-2.db";
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:dbPath error:nil];
    BOOL k0 = a != nil;
    [self add:@"K0" name:@"keychain-2.db 可读" passed:k0
        detail:k0 ? [NSString stringWithFormat:@"%llu B", [a fileSize]]
                  : @"不可读（需 root + 脱沙箱）" elapsed:0];

    // class keys 目录
    NSString *cls = @"/var/mobile/Library/Keychains/metadata_class_keys.plist";
    BOOL k1 = [[NSFileManager defaultManager] fileExistsAtPath:cls];
    [self add:@"K1" name:@"metadata_class_keys.plist" passed:k1
        detail:k1 ? @"存在" : @"缺失（v_Data 解不开）" elapsed:0];

    // SecItem 兜底
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecReturnAttributes: @YES,
                        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef out = NULL;
    OSStatus rc = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    if (out) CFRelease(out);

    // -34018 (errSecMissingEntitlement) 的含义与 -25300 完全不同：
    //   -25300 = 真没找到（说明 API 能用）
    //   -34018 = 缺 entitlement 或签名不被信任 → SecItem 整条路不可用
    //   其他 = 异常
    BOOL k2;
    NSString *k2detail;
    if (rc == errSecSuccess || rc == errSecItemNotFound) {
        k2 = YES;
        k2detail = [NSString stringWithFormat:@"OSStatus=%d（可用）", (int)rc];
    } else if (rc == -34018) {
        k2 = NO;
        k2detail = @"OSStatus=-34018 缺 keychain entitlement（签名问题，SecItem 路不可用）";
    } else {
        k2 = NO;
        k2detail = [NSString stringWithFormat:@"OSStatus=%d（异常）", (int)rc];
    }
    [self add:@"K2" name:@"SecItem 查询可用" passed:k2 detail:k2detail elapsed:0];

    _lastResults = [_acc copy];
    OWLog(@"======== SELFTEST Keychain 结束 ========");
    return _lastResults;
}

#pragma mark 全部

- (void)runAll {
    OWLog(@"######## SELFTEST 全量开始 ########");
    [self runChannelB];
    [self runChannelA];
    [self runKeychain];
    OWLog(@"######## SELFTEST 全量结束 ########");
}

@end
