#import "OWKernelChain.h"
#import "OWPrimitives.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <xpc/xpc.h>

#pragma mark - 外部符号（运行时解析，编译期不依赖；未编入时自动降级）

// XPF（01-越狱内核/XPF）
typedef int  (*ow_xpf_start_fn)(const char *kernelPath, const char *optSptmPath, const char *optTxmPath);
typedef bool (*ow_xpf_set_supported_fn)(const char *name);
typedef void *(*ow_xpf_construct_fn)(const char *sets[]);
typedef const char *(*ow_xpf_error_fn)(void);
typedef uint64_t (*ow_xpf_item_fn)(const char *name);
typedef void (*ow_xpf_stop_fn)(void);

// libgrabkernel2（05-工具链/libgrabkernel2）
typedef bool (*ow_grab_images_fn)(id dir);

// AppleDB endpoint（内置兜底下载用；以 libgrabkernel2 内实现为准）
static NSString * const kOWAppleDBBase = @"https://api.appledb.dev";

// 每次开机仅有一次机会的利用（失败即作废，必须落盘，不能靠内存记）
static NSArray<NSString *> * const kOWOneShotExploits = @[@"multicast_bytecopy"];

// XPF 符号解析：优先主程序（deps/libxpf.a 静态链接），
// 否则尝试 bundle 里的 libxpf.dylib（通道 A 源码自建时由 BaseBin 产出）。
// 两种形态都支持，避免“静态库没编上就整条链失效”。
static void *gOWXPFHandle = NULL;

// 系统 build：Info.plist 的 OWBuildVersionOverride 优先（联调时可强指定），
// 否则读 kern.osversion。exploit 的 DPSupportInclude.Builds 白名单靠它匹配。
static NSString *ow_current_build(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *ov = [[NSBundle mainBundle] infoDictionary][@"OWBuildVersionOverride"];
        cached = ov.length ? ov : ([OWDeviceProfile current].osBuild ?: @"");
    });
    return cached;
}

// 机型 → 粗略 SoC 族，仅用于 DPSupportedDevices（Titan/momentarius）过滤。
// 判不准就返回 nil —— 宁可不拦，也不要把支持的机型误杀。
static NSString *ow_soc_family(NSString *machine) {
    if (![machine hasPrefix:@"iPhone"]) return nil;
    NSInteger num = 0;
    NSScanner *sc = [NSScanner scannerWithString:machine];
    [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
    if (![sc scanInteger:&num]) return nil;
    switch (num) {
        case 11: return @"A13";
        case 12: return @"A14";
        case 13: return @"A15";
        case 14: return @"A16";   // 14/14Plus=A15、14Pro=A16：取高的
        case 15: return @"A16";   // 15/15Plus=A16、15Pro=A17：取低的，保证能进白名单
        case 16: return @"A18";
        default: return nil;
    }
}

// 调试开关：忽略 exploit 自己声明的 Builds 白名单。
// 只跳过 build 规则，DPSupportedRanges（版本）与 DPSupportedDevices（机型）仍然生效。
// 默认 NO。打开后会在「上游未验证过的 build」上真跑 exploit —— 很可能直接 panic，
// 仅用于联调/试验，不要作为正式包默认值。
static BOOL ow_ignore_build_whitelist(void) {
    static BOOL v = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id b = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"OWIgnoreBuildWhitelist"];
        if (!b) b = [[NSUserDefaults standardUserDefaults] objectForKey:@"OWIgnoreBuildWhitelist"];
        v = [b respondsToSelector:@selector(boolValue)] ? [b boolValue] : NO;
        if (v) OWLog(@"⚠️ OWIgnoreBuildWhitelist=YES：将忽略 exploit 的 build 白名单");
    });
    return v;
}

static void *ow_xpf_sym(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;

    if (!gOWXPFHandle) {
        const char *cands[] = {
            "@executable_path/Frameworks/libxpf.dylib",
            "@executable_path/libxpf.dylib",
        };
        for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]) && !gOWXPFHandle; i++) {
            gOWXPFHandle = dlopen(cands[i], RTLD_NOW | RTLD_GLOBAL);
        }
        if (!gOWXPFHandle) {
            NSString *p2 = [[[NSBundle mainBundle] bundlePath]
                            stringByAppendingPathComponent:@"Frameworks/libxpf.dylib"];
            if (p2.length) {
                gOWXPFHandle = dlopen(p2.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            }
        }
    }
    return gOWXPFHandle ? dlsym(gOWXPFHandle, name) : NULL;
}

#pragma mark - OWExploitEntry

@implementation OWExploitEntry {
    NSDictionary *_flavor;
    void *_handle;
    BOOL _supportLoaded;
    BOOL _supported;
}

- (instancetype)initWithPath:(NSString *)path
                        info:(NSDictionary *)info
                  flavorName:(NSString *)flavorName
                 flavorDict:(NSDictionary *)flavorDict {
    if (self = [super init]) {
        _executablePath = path;
        _flavorName = flavorName;
        _flavor = flavorDict;
        // 真实 framework 的 Info.plist 没有 DPExploitIdentifier，
        // 用 framework 目录名（去掉 .framework）作标识，与 Dopamine 一致。
        _identifier = info[@"DPExploitIdentifier"]
            ?: [[[path stringByDeletingLastPathComponent] lastPathComponent]
                stringByReplacingOccurrencesOfString:@".framework" withString:@""];

        NSString *t = info[@"DPExploitType"];
        if ([t isEqualToString:@"PAC"]) _type = OWExploitTypePAC;
        else if ([t isEqualToString:@"PPL"]) _type = OWExploitTypePPL;
        else _type = OWExploitTypeKernel;

        // 真实字段名是 DPFlavorPriority（不是 DPExploitPriority）
        _priority = [flavorDict[@"DPFlavorPriority"] unsignedLongLongValue];
        _requirements = flavorDict[@"DPFlavorRequirements"]
            ?: flavorDict[@"DPExploitRequirements"]
            ?: info[@"DPExploitRequirements"]
            ?: @[];
        _oneShot = [kOWOneShotExploits containsObject:_identifier];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@:%@ prio=%llu>", _identifier, _flavorName, _priority];
}

// 判定规则对照真实 framework 的 Info.plist 结构：
//   DPSupportedRanges : [{Start:"15.0", End:"16.6.1"}, ...]  —— 落在任一区间即支持
//   DPSupportInclude  : [] 或 [{Builds:[...]}, {Devices:[...]}]  —— 非空时必须至少命中一项
//   DPSupportExclude  : 同理，命中即排除
- (BOOL)isSupported {
    if (_supportLoaded) return _supported;
    _supportLoaded = YES;

    OWDeviceProfile *dev = [OWDeviceProfile current];

    // ---- 1) 版本区间 ----
    NSArray *ranges = _flavor[@"DPSupportedRanges"];
    if ([ranges isKindOfClass:NSArray.class] && ranges.count) {
        BOOL inAny = NO;
        for (NSDictionary *r in ranges) {
            if (![r isKindOfClass:NSDictionary.class]) continue;
            NSString *start = r[@"Start"];
            NSString *end   = r[@"End"];
            BOOL geStart = ![start isKindOfClass:NSString.class] || start.length == 0
                || [dev.osVersion compare:start options:NSNumericSearch] != NSOrderedAscending;
            BOOL leEnd = ![end isKindOfClass:NSString.class] || end.length == 0
                || [dev.osVersion compare:end options:NSNumericSearch] != NSOrderedDescending;
            if (geStart && leEnd) { inAny = YES; break; }
        }
        if (!inAny) {
            OWLog(@"%@(%@) 不支持: iOS %@ 不在 DPSupportedRanges 内",
                  _identifier, _flavorName, dev.osVersion);
            _supported = NO;
            return NO;
        }
    } else {
        // 兼容旧式单区间字段（部分 fork 用）
        NSString *minOS = _flavor[@"DPExploitMinOSVersion"];
        NSString *maxOS = _flavor[@"DPExploitMaxOSVersion"];
        if ([minOS isKindOfClass:NSString.class] && minOS.length &&
            [dev.osVersion compare:minOS options:NSNumericSearch] == NSOrderedAscending) {
            OWLog(@"%@ 不支持: %@ < min %@", _identifier, dev.osVersion, minOS);
            _supported = NO;
            return NO;
        }
        if ([maxOS isKindOfClass:NSString.class] && maxOS.length &&
            [dev.osVersion compare:maxOS options:NSNumericSearch] == NSOrderedDescending) {
            OWLog(@"%@ 不支持: %@ > max %@", _identifier, dev.osVersion, maxOS);
            _supported = NO;
            return NO;
        }
    }

    // ---- 1b) 机型/SoC 白名单（Titan/momentarius 用 DPSupportedDevices）----
    NSArray *supDevs = _flavor[@"DPSupportedDevices"];
    if ([supDevs isKindOfClass:NSArray.class] && supDevs.count) {
        NSString *fam = ow_soc_family(dev.machine);
        if (fam && ![supDevs containsObject:fam]) {
            OWLog(@"%@(%@) 不支持: SoC %@ 不在 %@",
                  _identifier, _flavorName, fam, [supDevs componentsJoinedByString:@","]);
            _supported = NO;
            return NO;
        }
        if (!fam) {
            OWLog(@"%@(%@) SoC 无法判定（%@），仍尝试但可能失败",
                  _identifier, _flavorName, dev.machine);
        }
    }

    // ---- 2) DPSupportInclude（非空时必须至少命中一项）----
    NSArray *include = _flavor[@"DPSupportInclude"];
    if ([include isKindOfClass:NSArray.class] && include.count) {
        BOOL hit = [self _matchesRules:include device:dev];
        if (!hit) {
            OWLog(@"%@(%@) 不支持: 未命中 DPSupportInclude", _identifier, _flavorName);
            _supported = NO;
            return NO;
        }
    }

    // ---- 3) DPSupportExclude（命中即排除）----
    NSArray *exclude = _flavor[@"DPSupportExclude"];
    if ([exclude isKindOfClass:NSArray.class] && exclude.count) {
        if ([self _matchesRules:exclude device:dev]) {
            OWLog(@"%@(%@) 不支持: 命中 DPSupportExclude", _identifier, _flavorName);
            _supported = NO;
            return NO;
        }
    }
    // 兼容旧式字典形态
    NSDictionary *excludeDict = _flavor[@"DPSupportExclude"];
    if ([excludeDict isKindOfClass:NSDictionary.class]) {
        NSArray *exDev = excludeDict[@"Devices"];
        NSArray *exBuild = excludeDict[@"Builds"];
        BOOL devHit = [exDev isKindOfClass:NSArray.class] && [exDev containsObject:dev.machine];
        BOOL buildHit = NO;
        if ([exBuild isKindOfClass:NSArray.class]) {
            NSString *build = ow_current_build();
            buildHit = build.length ? [exBuild containsObject:build] : NO;
            if (ow_ignore_build_whitelist()) buildHit = NO;   // 排除项里的 build 也一并忽略
        }
        if (devHit && buildHit) {
            OWLog(@"%@ 命中排除项", _identifier);
            _supported = NO;
            return NO;
        }
    }

    _supported = YES;
    return YES;
}

// 规则数组的任一元素命中即 YES。
// 元素形态：{Builds:[...]} 或 {Devices:[...]} 或 {Ranges:[{Start,End}]}
- (BOOL)_matchesRules:(NSArray *)rules device:(OWDeviceProfile *)dev {
    NSString *build = ow_current_build();
    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:NSDictionary.class]) continue;

        NSArray *builds = rule[@"Builds"];
        if ([builds isKindOfClass:NSArray.class] && builds.count) {
            if (build.length && [builds containsObject:build]) return YES;
            if (ow_ignore_build_whitelist()) {
                OWLog(@"⚠️ %@ 跳过 build 白名单（当前 %@，声明 %@）",
                      _identifier, build.length ? build : @"未知",
                      [builds componentsJoinedByString:@","]);
                return YES;
            }
            continue;
        }
        NSArray *devices = rule[@"Devices"];
        if ([devices isKindOfClass:NSArray.class] && devices.count) {
            if ([devices containsObject:dev.machine]) return YES;
            continue;
        }
        NSArray *rs = rule[@"Ranges"];
        if ([rs isKindOfClass:NSArray.class] && rs.count) {
            for (NSDictionary *r in rs) {
                NSString *start = r[@"Start"], *end = r[@"End"];
                BOOL ge = ![start isKindOfClass:NSString.class] || !start.length
                    || [dev.osVersion compare:start options:NSNumericSearch] != NSOrderedAscending;
                BOOL le = ![end isKindOfClass:NSString.class] || !end.length
                    || [dev.osVersion compare:end options:NSNumericSearch] != NSOrderedDescending;
                if (ge && le) return YES;
            }
        }
        // 空规则视为无条件命中
        if (!builds && !devices && !rs) return YES;
    }
    return NO;
}

- (int)load {
    if (!_handle) _handle = dlopen(_executablePath.fileSystemRepresentation, RTLD_NOW);
    return _handle ? 0 : -1;
}

- (int)run {
    if (!_handle && [self load] != 0) return -1;
    int (*exploit_init)(const char *flavor) = dlsym(_handle, "exploit_init");
    if (!exploit_init) { OWLog(@"%@ 无 exploit_init", _identifier); return -1; }
    int r = exploit_init(_flavorName.UTF8String);
    OWLog(@"%@(%@) exploit_init -> %d", _identifier, _flavorName, r);
    return r;
}

- (int)cleanup {
    if (!_handle) return -1;
    int (*exploit_deinit)(void) = dlsym(_handle, "exploit_deinit");
    if (!exploit_deinit) return -1;
    return exploit_deinit();
}

@end

#pragma mark - OWKernelChain

@implementation OWKernelChain {
    NSMutableDictionary *_offsetCache;
}

- (instancetype)init {
    if (self = [super init]) {
        _perAttemptTimeout = 60.0;
        _totalBudget = 240.0;
        _maxCandidates = 3;
        _kernelBase = 0;
        _kernelSlide = 0;
    }
    return self;
}

#pragma mark 候选枚举

- (NSArray<OWExploitEntry *> *)candidatesOfType:(OWExploitType)type {
    NSMutableArray *out = [NSMutableArray new];
    // 注意：framework 在 app bundle 内部的 Frameworks 目录（不是 .app 的同级目录）
    NSString *fwDir = [[[NSBundle mainBundle] bundlePath]
                       stringByAppendingPathComponent:@"Frameworks"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fwDir]) {
        OWLog(@"内核: 包内没有 Frameworks 目录（%s）", fwDir.lastPathComponent.UTF8String);
        return out;
    }

    NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fwDir error:nil] ?: @[];
    for (NSString *fwName in entries) {
        if (![fwName hasSuffix:@".framework"]) continue;
        NSString *plistPath = [fwDir stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@/Info.plist", fwName]];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (!info[@"DPExploitType"]) continue;

        NSString *exeName = [fwName stringByDeletingPathExtension];
        NSString *exePath = [fwDir stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@/%@", fwName, exeName]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:exePath]) continue;

        NSDictionary *flavors = info[@"DPExploitFlavors"];
        for (NSString *flavorName in flavors) {
            OWExploitEntry *e = [[OWExploitEntry alloc] initWithPath:exePath
                                                               info:info
                                                         flavorName:flavorName
                                                        flavorDict:flavors[flavorName]];
            if (e.type != type) continue;
            if (![e isSupported]) continue;
            [out addObject:e];
        }
    }

    [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"priority" ascending:NO]]];
    return out;
}

- (BOOL)kernelStaticallySupported {
    NSUInteger k = [self candidatesOfType:OWExploitTypeKernel].count;
    if (!k) {
        OWLog(@"内核: Kernel 候选 0 个（PAC=%lu，PPL=%lu）",
              (unsigned long)[self candidatesOfType:OWExploitTypePAC].count,
              (unsigned long)[self candidatesOfType:OWExploitTypePPL].count);
    } else {
        OWLog(@"内核: Kernel 候选 %lu 个", (unsigned long)k);
    }
    return k > 0;
}

#pragma mark kernelcache

- (NSString *)resolveKernelCache:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = docs.firstObject ?: NSTemporaryDirectory();

    // 1) 随包内嵌：只用于特定版本兜底，不依赖任何特权
    NSString *bundled = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"kernelcache"];
    if ([fm fileExistsAtPath:bundled]) {
        OWLog(@"kernelcache: 使用内嵌 %@", bundled);
        return bundled;
    }

    // 2) 已下载缓存（同一 boot-manifest-hash 复用）
    NSString *cached = [docDir stringByAppendingPathComponent:@"kernelcache"];
    NSString *hashFile = [docDir stringByAppendingPathComponent:@"kernelcache.bmhash"];
    NSString *bmh = [OWDeviceProfile current].bootManifestHash;
    NSString *savedHash = [NSString stringWithContentsOfFile:hashFile encoding:NSUTF8StringEncoding error:nil];
    if ([fm fileExistsAtPath:cached] && bmh.length && [savedHash isEqualToString:bmh]) {
        OWLog(@"kernelcache: 命中缓存 %@", cached);
        return cached;
    }

    // 3) 下载。优先用编入的 libgrabkernel2；拿不到符号则用内置 AppleDB 兜底。
    ow_grab_images_fn grab = (ow_grab_images_fn)dlsym(RTLD_DEFAULT, "grab_images");
    BOOL ok = NO;
    if (grab) {
        OWLog(@"kernelcache: 走 libgrabkernel2 grab_images");
        ok = grab(docDir);
    } else {
        OWLog(@"kernelcache: 未链接 libgrabkernel2，走内置 AppleDB 下载");
        ok = [self _downloadKernelCacheTo:docDir error:error];
    }

    if (!ok) {
        if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:1
                                userInfo:@{NSLocalizedDescriptionKey: @"kernelcache 获取失败"}];
        return nil;
    }

    NSString *p = [docDir stringByAppendingPathComponent:@"kernelcache"];
    if (![fm fileExistsAtPath:p]) {
        p = [docDir stringByAppendingPathComponent:@"kernel"];
    }
    if (![fm fileExistsAtPath:p]) {
        if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:2
                                userInfo:@{NSLocalizedDescriptionKey: @"下载后未找到 kernelcache 文件"}];
        return nil;
    }
    [bmh writeToFile:hashFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    OWLog(@"kernelcache: 就绪 %@", p);
    return p;
}

- (BOOL)_downloadKernelCacheTo:(NSString *)dir error:(NSError **)error {
    NSString *bmh = [OWDeviceProfile current].bootManifestHash;
    if (!bmh.length) {
        if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:3
                                userInfo:@{NSLocalizedDescriptionKey: @"boot-manifest-hash 不可用"}];
        return NO;
    }
    NSString *machine = [OWDeviceProfile current].machine;
    NSURL *url = [NSURL URLWithString:
                  [NSString stringWithFormat:@"%@/ios/%@/%@/kernelcache", kOWAppleDBBase, machine, bmh]];
    OWLog(@"kernelcache: 尝试 %@", url);

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSError *err = nil;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            data = d; err = e;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));

    if (!data.length) {
        if (error) *error = err ?: [NSError errorWithDomain:@"OWKernelChain" code:4
                                        userInfo:@{NSLocalizedDescriptionKey: @"下载为空"}];
        return NO;
    }
    NSString *out = [dir stringByAppendingPathComponent:@"kernelcache"];
    [data writeToFile:out atomically:YES];
    return YES;
}

#pragma mark 偏移

- (BOOL)resolveOffsets:(NSError **)error {
    ow_xpf_start_fn xpf_start = (ow_xpf_start_fn)ow_xpf_sym("xpf_start_with_kernel_path");
    ow_xpf_construct_fn xpf_construct = (ow_xpf_construct_fn)ow_xpf_sym("xpf_construct_offset_dictionary");
    ow_xpf_error_fn xpf_error = (ow_xpf_error_fn)ow_xpf_sym("xpf_get_error");

    if (!xpf_start || !xpf_construct) {
        if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:10
                                userInfo:@{NSLocalizedDescriptionKey: @"XPF 未编入，无法解析偏移"}];
        OWLog(@"偏移: XPF 缺失");
        return NO;
    }

    // ★ 顺序很重要：sptm/txm 由 libgrabkernel2 的 grab_images 下载生成，
    //   所以必须先 resolveKernelCache（会触发 grab_images），再找这两个文件。
    //   原来写在前面，导致首次运行时永远找不到 sptm/txm。
    NSError *kerr = nil;
    NSString *kernelPath = [self resolveKernelCache:&kerr];
    if (!kernelPath) { if (error) *error = kerr; return NO; }

    NSString *sptm = nil, *txm = nil;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = docs.firstObject ?: NSTemporaryDirectory();
    for (NSString *nm in @[@"sptm.im4p", @"sptm.img4"]) {
        NSString *p = [docDir stringByAppendingPathComponent:nm];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { sptm = p; break; }
    }
    for (NSString *nm in @[@"txm.im4p", @"txm.img4"]) {
        NSString *p = [docDir stringByAppendingPathComponent:nm];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { txm = p; break; }
    }

    // 注意：sptm/txm 可以为 nil（A12–A15 多数没有 SPTM）。
    // 传 nil.fileSystemRepresentation 会崩，必须判空后传 NULL。
    const char *sptmPath = sptm.length ? sptm.fileSystemRepresentation : NULL;
    const char *txmPath  = txm.length  ? txm.fileSystemRepresentation  : NULL;
    OWLog(@"偏移: kernel=%s sptm=%s txm=%s",
          kernelPath.lastPathComponent.UTF8String,
          sptmPath ? sptm.lastPathComponent.UTF8String : "(无)",
          txmPath  ? txm.lastPathComponent.UTF8String  : "(无)");

    int r = xpf_start(kernelPath.fileSystemRepresentation, sptmPath, txmPath);
    if (r != 0) {
        const char *e = xpf_error ? xpf_error() : "unknown";
        NSString *msg = [NSString stringWithFormat:@"patchfind 失败: %s", e];
        OWLog(@"%@", msg);
        if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:11
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
    }

    const char *sets[] = {"translation", "trustcache", "sandbox", "physmap",
                          "struct", "physrw", "IOSurface", NULL};
    xpc_object_t dict = (xpc_object_t)xpf_construct((const char **)sets);
    _offsetsResolved = dict != NULL;

    if (!_offsetsResolved) {
        const char *e = xpf_error ? xpf_error() : "unknown";
        NSString *msg = [NSString stringWithFormat:@"偏移字典构造失败: %s", e];
        OWLog(@"%@", msg);
        if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:12
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
        // 失败也要停掉 patchfind 上下文，否则下次 xpf_start 会因状态残留失败
        ow_xpf_stop_fn xpf_stop = (ow_xpf_stop_fn)ow_xpf_sym("xpf_stop");
        if (xpf_stop) xpf_stop();
        return NO;
    }

    // 把 XPF 解出的内核基址回填给原语层：后面提权、脱沙箱、RemoteCall 都要用
    uint64_t base  = xpc_dictionary_get_uint64(dict, "kernelConstant.base");
    uint64_t slide = xpc_dictionary_get_uint64(dict, "kernelConstant.slide");
    if (!base) base = xpc_dictionary_get_uint64(dict, "kernelConstant.staticBase");
    if (slide && !base) base = 0xfffffff007004000ULL + slide;
    ow_set_kernel_base(base);
    ow_set_kernel_slide(slide);
    _kernelBase = base;
    _kernelSlide = slide;
    OWLog(@"偏移: 解析完成 base=0x%llx slide=0x%llx", base, slide);

    // ---- proc 链入口：allproc ----
    // lara 的 resolvekernoffsets() 靠 "kernelSymbol.kernproc"，但上游 XPF 只注册了
    // "kernelSymbol.allproc"，没有 kernproc 的 finder。照搬调用会必然失败，
    // 随后 procbypid() 会退到 utils.m 里那个硬编码 0xfffffff0079fd9c8，
    // 在 17/18 上基本是错的地址 —— 提权链就是断在这里。
    // 遍历 allproc 单链表已足够找到任意 pid，所以直接把 allproc 偏移落盘。
    ow_xpf_item_fn item = (ow_xpf_item_fn)ow_xpf_sym("xpf_item_resolve");
    if (item && base) {
        uint64_t allproc = item("kernelSymbol.allproc");
        if (allproc > base && allproc - base < 0x40000000ULL) {
            [[NSUserDefaults standardUserDefaults] setObject:@(allproc - base)
                                                      forKey:@"lara.allprocoff"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            OWLog(@"偏移: allproc off=0x%llx", allproc - base);
        } else {
            OWLog(@"偏移: allproc 未解析（%s）", (xpf_error ? xpf_error() : "unknown"));
        }

        // kernproc 若有 finder 就一并落盘，缺失不影响（procbypid 两条链表任一可用即可）
        uint64_t kernproc = item("kernelSymbol.kernproc");
        if (kernproc > base && kernproc - base < 0x40000000ULL) {
            [[NSUserDefaults standardUserDefaults] setObject:@(kernproc - base)
                                                      forKey:@"lara.kernprocoff"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            OWLog(@"偏移: kernproc off=0x%llx", kernproc - base);
        }
    }

    return YES;
}

#pragma mark 内核尝试（带预算与失败落盘）

- (BOOL)runKernelPass:(NSError **)error {
    NSArray<OWExploitEntry *> *cands = [self candidatesOfType:OWExploitTypeKernel];
    if (!cands.count) {
        OWLog(@"内核: 无可用候选（静态门未过）");
        if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:20
                                userInfo:@{NSLocalizedDescriptionKey: @"无可用 kernel exploit"}];
        return NO;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:self.totalBudget];
    OWState *state = [OWState shared];
    NSUInteger tried = 0;

    for (OWExploitEntry *e in cands) {
        if (tried >= self.maxCandidates) break;
        if ([[NSDate date] compare:deadline] == NSOrderedDescending) {
            OWLog(@"内核: 总预算耗尽");
            break;
        }

        // 一次性利用作废后不再尝试
        if (e.oneShot && [state isExploitExhausted:e.identifier]) {
            OWLog(@"内核: %@ 为一次性利用且已作废，跳过", e.identifier);
            continue;
        }
        if ([state attemptsForExploit:e.identifier] >= 3) {
            OWLog(@"内核: %@ 尝试次数已达上限", e.identifier);
            continue;
        }

        tried++;
        [state bumpAttemptForExploit:e.identifier];
        if (e.requirements.count) {
            OWLog(@"内核: %@ 声明依赖 %@（当前未做运行时校验）", e.identifier,
                  [e.requirements componentsJoinedByString:@","]);
        }
        OWLog(@"内核: 尝试 %@(%@) 第 %lu 次", e.identifier, e.flavorName,
              (unsigned long)[state attemptsForExploit:e.identifier]);

        int r = [self _runOne:e];
        if (r == 0) {
            // exploit 成功后 gPrimitives 才被填充，这里立刻重新绑定一次
            ow_bind_primitives();
            _hasKernelRW = ow_primitives_available();
            if (_hasKernelRW) {
                OWLog(@"内核: %@ 成功，内核读写=YES", e.identifier);
                return YES;
            }
            // 返回 0 但原语没填充：多见于 libjailbreak 没加载/ABI 不匹配，
            // 不能当成成功直接退出，换下一个候选再试。
            OWLog(@"内核: %@ 返回成功但原语未填充，继续下一个候选", e.identifier);
            [e cleanup];
            if (e.oneShot) {
                [state markExploitExhausted:e.identifier];
                OWLog(@"内核: %@ 一次性机会已消耗，标记作废", e.identifier);
            }
            continue;
        }

        OWLog(@"内核: %@ 失败 r=%d", e.identifier, r);
        [e cleanup];
        if (e.oneShot) {
            [state markExploitExhausted:e.identifier];
            OWLog(@"内核: %@ 一次性机会已消耗，标记作废", e.identifier);
        }
    }

    NSString *msg = @"kernel exploit 全部失败";
    _lastError = msg;
    if (error) *error = [NSError errorWithDomain:@"OWKernelChain" code:21
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
    return NO;
}

#pragma mark 支撑利用（PAC / PPL）

// 上游 Dopamine 的顺序是 PAC → PPL → Kernel：
//   badRecovery(PAC) / dmaFail、Titan、momentarius(PPL) 只负责绕过保护，
//   不产生 gPrimitives，所以成功判据只有 exploit_init 返回 0。
// 缺这段时，依赖 PPL 的内核 exploit 会直接失败（甚至 panic）。
- (NSUInteger)runSupportPass:(NSError **)error {
    OWState *state = [OWState shared];
    NSUInteger success = 0;

    NSArray<NSNumber *> *order = @[@(OWExploitTypePAC), @(OWExploitTypePPL)];
    for (NSNumber *n in order) {
        OWExploitType type = (OWExploitType)n.unsignedIntegerValue;
        NSString *typeName = (type == OWExploitTypePAC) ? @"PAC" : @"PPL";
        NSArray<OWExploitEntry *> *cands = [self candidatesOfType:type];
        if (!cands.count) {
            OWLog(@"支撑: %@ 无可用候选", typeName);
            continue;
        }
        OWLog(@"支撑: %@ 候选 %lu 个", typeName, (unsigned long)cands.count);

        NSUInteger tried = 0;
        for (OWExploitEntry *e in cands) {
            if (tried >= self.maxCandidates) break;
            if (e.oneShot && [state isExploitExhausted:e.identifier]) {
                OWLog(@"支撑: %@ 为一次性利用且已作废，跳过", e.identifier);
                continue;
            }
            tried++;
            OWLog(@"支撑: 尝试 %@(%@)", e.identifier, e.flavorName);

            int r = [self _runOne:e];
            if (r == 0) {
                success++;
                OWLog(@"支撑: %@ 成功", e.identifier);
                continue;   // 同类再试一个没有意义，但允许下一个 type
            }
            OWLog(@"支撑: %@ 失败 r=%d", e.identifier, r);
            [e cleanup];
            if (e.oneShot) [state markExploitExhausted:e.identifier];
        }
    }

    if (error && success == 0) {
        *error = [NSError errorWithDomain:@"OWKernelChain" code:22
                    userInfo:@{NSLocalizedDescriptionKey: @"PAC/PPL 支撑利用均不可用"}];
    }
    return success;
}

- (int)_runOne:(OWExploitEntry *)e {
    if ([e load] != 0) { OWLog(@"内核: %@ dlopen 失败", e.identifier); return -1; }

    __block int result = -2;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create("ow.exploit", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        result = [e run];
        dispatch_semaphore_signal(sem);
    });

    // exploit 卡死时线程无法安全中断，只能超时放弃并继续下一个候选；
    // 悬挂线程随进程退出回收。
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(self.perAttemptTimeout * NSEC_PER_SEC)));
    if (waited != 0) {
        OWLog(@"内核: %@ 超时 %.0fs，放弃", e.identifier, self.perAttemptTimeout);
        return -3;
    }
    return result;
}

@end
