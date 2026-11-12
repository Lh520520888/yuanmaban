//
//  OWLaunchServices.m
//  OPENsrc
//

#import "OWLaunchServices.h"
#import "OWCommon.h"
#import <sqlite3.h>

static NSString * const kLSMapPath =
    @"/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist";
static NSString * const kAppStateDB =
    @"/var/mobile/Library/FrontBoard/applicationState.db";
static NSString * const kContainerMetaName = @".com.apple.mobile_container_manager.metadata.plist";

@interface OWLaunchServices ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *byUUID;   // uuid → bid
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *byBundle; // bid → uuid
@property (nonatomic, copy, readwrite) NSString *status;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation OWLaunchServices

+ (instancetype)shared {
    static OWLaunchServices *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OWLaunchServices new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _byUUID = [NSMutableDictionary dictionary];
        _byBundle = [NSMutableDictionary dictionary];
        _status = @"未加载";
    }
    return self;
}

#pragma mark 归一化

// UUID 有多种写法：大写带横线 / 小写 / 无横线。统一成大写无横线做 key。
- (NSString *)normalizeUUID:(NSString *)u {
    if (!u.length) return nil;
    NSString *s = [[u uppercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return s.length ? s : nil;
}

#pragma mark 数据源 1：LastLaunchServicesMap.plist

- (NSUInteger)loadFromLSMap {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kLSMapPath];
    if (![d isKindOfClass:[NSDictionary class]]) {
        OWLog(@"LS: %@ 不可读", kLSMapPath);
        return 0;
    }
    // 结构：{ "User" : { <bundleId> : { "Container" : "<uuid>", ... } }, "System" : {...} }
    NSUInteger n = 0;
    for (NSString *domain in @[@"User", @"System"]) {
        NSDictionary *sub = d[domain];
        if (![sub isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *bid in sub) {
            NSDictionary *info = sub[bid];
            if (![info isKindOfClass:[NSDictionary class]]) continue;
            NSString *uuid = info[@"Container"] ?: info[@"DataContainer"];
            NSString *norm = [self normalizeUUID:uuid];
            if (norm.length && bid.length) {
                _byUUID[norm] = bid;
                _byBundle[bid] = norm;
                n++;
            }
        }
    }
    OWLog(@"LS: LastLaunchServicesMap 载入 %lu 条 (domains=%lu)",
          (unsigned long)n, (unsigned long)d.count);
    return n;
}

#pragma mark 数据源 2：applicationState.db

- (NSUInteger)loadFromAppStateDB {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(kAppStateDB.UTF8String, &db,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        OWLog(@"LS: applicationState.db 打不开");
        return 0;
    }

    // 表结构随版本变化，先探测有哪些表
    NSMutableArray *tables = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *nm = sqlite3_column_text(st, 0);
            if (nm) [tables addObject:[NSString stringWithUTF8String:(const char *)nm]];
        }
        sqlite3_finalize(st);
    }

    NSUInteger n = 0;
    // 优先 application_identifier_tab（历史版本）
    for (NSString *tbl in @[@"application_identifier_tab", @"application_identifier"]) {
        if (![tables containsObject:tbl]) continue;
        NSString *sql = [NSString stringWithFormat:
                         @"SELECT application_identifier, application_identifier_uuid FROM %@", tbl];
        // 列名不一致时退回 SELECT *
        for (int attempt = 0; attempt < 2 && n == 0; attempt++) {
            NSString *use = attempt == 0 ? sql
                : [NSString stringWithFormat:@"SELECT * FROM %@", tbl];
            if (sqlite3_prepare_v2(db, use.UTF8String, -1, &st, NULL) != SQLITE_OK) continue;

            int ncol = sqlite3_column_count(st);
            int cBid = -1, cUuid = -1;
            for (int c = 0; c < ncol; c++) {
                const char *cn = sqlite3_column_name(st, c);
                if (!cn) continue;
                NSString *col = [NSString stringWithUTF8String:cn].lowercaseString;
                if ([col containsString:@"identifier"] && [col containsString:@"uuid"]) cUuid = c;
                else if ([col containsString:@"identifier"]) cBid = c;
            }
            while (sqlite3_step(st) == SQLITE_ROW) {
                int bi = cBid >= 0 ? cBid : 0;
                int ui = cUuid >= 0 ? cUuid : (ncol > 1 ? 1 : -1);
                if (ui < 0) break;
                const unsigned char *b = sqlite3_column_text(st, bi);
                const unsigned char *u = sqlite3_column_text(st, ui);
                if (!b || !u) continue;
                NSString *bid = [NSString stringWithUTF8String:(const char *)b];
                NSString *norm = [self normalizeUUID:[NSString stringWithUTF8String:(const char *)u]];
                if (bid.length && norm.length && !_byUUID[norm]) {
                    _byUUID[norm] = bid;
                    _byBundle[bid] = norm;
                    n++;
                }
            }
            sqlite3_finalize(st);
        }
        if (n) break;
    }
    sqlite3_close(db);
    OWLog(@"LS: applicationState.db 载入 %lu 条 (tables=%@)", (unsigned long)n, tables);
    return n;
}

#pragma mark 数据源 3：容器元数据兜底

// 每个 App Data 容器根目录有 .com.apple.mobile_container_manager.metadata.plist，
// 里面有 MCMMetadataIdentifier（= bundleId）。这是最直接的 UUID→bundleId 映射。
// 由调用方在拿到容器 path 后调用，不是全局扫描。
- (nullable NSString *)bundleIdFromContainerPath:(NSString *)path {
    if (!path.length) return nil;
    NSString *meta = [path stringByAppendingPathComponent:kContainerMetaName];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
    NSString *bid = d[@"MCMMetadataIdentifier"];
    if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
    return nil;
}

#pragma mark 公共

- (NSUInteger)load {
    if (_loaded) return _byUUID.count;
    _loaded = YES;

    NSUInteger a = [self loadFromLSMap];
    NSUInteger b = [self loadFromAppStateDB];
    // 直接把 metadata.plist 的读取能力暴露出去，调用方逐容器补充
    _status = [NSString stringWithFormat:@"LSMap=%lu appState=%lu 合计=%lu",
               (unsigned long)a, (unsigned long)b, (unsigned long)_byUUID.count];
    OWLog(@"LS: %@", _status);
    return _byUUID.count;
}

- (nullable NSString *)bundleIdForUUID:(NSString *)uuid {
    if (!_loaded) [self load];
    NSString *norm = [self normalizeUUID:uuid];
    if (!norm) return nil;
    return _byUUID[norm];
}

- (nullable NSString *)uuidForBundleId:(NSString *)bundleId {
    if (!_loaded) [self load];
    if (!bundleId.length) return nil;
    return _byBundle[bundleId];
}

- (NSDictionary<NSString *, NSString *> *)allMappings {
    if (!_loaded) [self load];
    return [_byBundle copy];
}

@end
