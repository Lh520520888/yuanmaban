#import "OWCleanup.h"
#import "OWCommon.h"

@implementation OWCleanup

- (void)execute {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"VarCleanRules" ofType:@"json"];
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d.length) { OWLog(@"清理: 规则文件缺失，跳过"); return; }

    NSDictionary *rules = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = docs.firstObject ?: NSTemporaryDirectory();

    // 1) 越狱痕迹绝对路径
    for (NSString *path in rules[@"black"] ?: @[]) {
        if (![fm fileExistsAtPath:path]) continue;
        NSError *e = nil;
        if ([fm removeItemAtPath:path error:&e]) OWLog(@"清理: 删除 %@", path);
        else OWLog(@"清理: %@ 删除失败 %@", path, e.localizedDescription);
    }

    // 2) 自身痕迹（相对 Documents）
    for (NSString *rel in rules[@"selfTraces"] ?: @[]) {
        NSString *full = [docDir stringByAppendingPathComponent:
                          [rel stringByReplacingOccurrencesOfString:@"Documents/" withString:@""]];
        if (![fm fileExistsAtPath:full]) continue;
        [fm removeItemAtPath:full error:nil];
        OWLog(@"清理: 删除自身痕迹 %@", rel);
    }

    // 3) 关键字扫描（兜底，防止路径变化）
    NSArray *kw = rules[@"blackKeywords"] ?: @[];
    NSArray *preserve = rules[@"preserve"] ?: @[];
    if (kw.count) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:docDir];
        NSMutableArray *hits = [NSMutableArray new];
        for (NSString *rel in en) {
            if ([rel hasPrefix:@"pending"]) continue;   // 未上传完的数据不能删
            BOOL keep = NO;
            for (NSString *pk in preserve) if ([rel hasSuffix:pk.lastPathComponent]) keep = YES;
            if (keep) continue;
            for (NSString *k in kw) {
                if ([rel.lowercaseString rangeOfString:k.lowercaseString].location != NSNotFound) {
                    [hits addObject:[docDir stringByAppendingPathComponent:rel]];
                    break;
                }
            }
        }
        for (NSString *h in hits) { [fm removeItemAtPath:h error:nil]; OWLog(@"清理: 命中关键字删除 %@", h.lastPathComponent); }
    }

    OWLog(@"清理: 完成");
}

@end
