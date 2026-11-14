#import "OWArchive.h"
#import "OWCommon.h"
#include <archive.h>
#include <archive_entry.h>
#include <sys/stat.h>

@interface OWArchive ()
+ (BOOL)_addData:(NSData *)data named:(NSString *)name to:(struct archive *)a;
+ (BOOL)_addFileAtPath:(NSString *)path named:(NSString *)rel to:(struct archive *)a;
+ (BOOL)_writeArchive:(NSString *)zipPath
                error:(NSError **)error
              builder:(BOOL (^)(struct archive *a))builder;
@end

@implementation OWArchive

+ (BOOL)zipFiles:(NSArray<NSString *> *)files
      relativeTo:(NSString *)baseDir
              to:(NSString *)zipPath
           error:(NSError **)error {
    return [self _writeArchive:zipPath error:error builder:^BOOL(struct archive *a) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSUInteger n = 0;
        for (NSString *f in files) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:f isDirectory:&isDir] || isDir) continue;

            NSString *rel = f;
            if (baseDir.length && [f hasPrefix:baseDir]) {
                rel = [f substringFromIndex:baseDir.length];
                while ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
            }
            if (!rel.length) rel = f.lastPathComponent;
            if (![self _addFileAtPath:f named:rel to:a]) continue;
            n++;
        }
        OWLog(@"Archive: %@ 入包 %lu 项", zipPath.lastPathComponent, (unsigned long)n);
        return n > 0;
    }];
}

+ (BOOL)zipDirectory:(NSString *)dir
                  to:(NSString *)zipPath
            maxBytes:(uint64_t)maxBytes
            totalCap:(uint64_t)totalCap
               error:(NSError **)error {
    return [self _writeArchive:zipPath error:error builder:^BOOL(struct archive *a) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
        NSUInteger n = 0;
        uint64_t total = 0;
        NSUInteger skipped = 0, oversize = 0;

        for (NSString *rel in en) {
            NSString *full = [dir stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) continue;

            NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
            uint64_t sz = [attr fileSize];

            // 关键小文件（sqlite/plist/json）绝不因总体积被 skip —— 那正是要的东西
            NSString *ext = full.pathExtension.lowercaseString;
            BOOL keyFile = [@[@"sqlite", @"sqlite3", @"db", @"plist", @"json", @"realm", @"txt"] containsObject:ext];

            if (sz > maxBytes && !keyFile) { oversize++; continue; }
            if (total + sz > totalCap && !keyFile) { skipped++; continue; }

            if (![self _addFileAtPath:full named:rel to:a]) { skipped++; continue; }
            total += sz;
            n++;
        }
        OWLog(@"Archive: %@ 入包 %lu 项 / %llu B（skip %lu，oversize %lu）",
              zipPath.lastPathComponent, (unsigned long)n, total,
              (unsigned long)skipped, (unsigned long)oversize);
        return n > 0;
    }];
}

#pragma mark - 内部

+ (BOOL)zipDirectory:(NSString *)dir
                  to:(NSString *)zipPath
            manifest:(NSDictionary *)manifest
              subdir:(NSString *)subdir
            maxBytes:(uint64_t)maxBytes
            totalCap:(uint64_t)totalCap
               error:(NSError **)error {
    return [self _writeArchive:zipPath error:error builder:^BOOL(struct archive *a) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSUInteger realFiles = 0;
        uint64_t total = 0;
        NSUInteger skipped = 0, oversize = 0;

        // 1) 包根 _manifest.json：服务端只认这个文件名
        NSData *md = manifest ? [NSJSONSerialization dataWithJSONObject:manifest
                                                               options:0
                                                                 error:nil] : nil;
        if (md.length) {
            if (![self _addData:md named:@"_manifest.json" to:a]) {
                OWLog(@"Archive: _manifest.json 写入失败");
            }
        }

        // 2) 文件统一放进 <subdir>/，与 wql 的包结构一致
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
        for (NSString *rel in en) {
            if ([rel isEqualToString:@"_manifest.json"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) continue;

            NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
            uint64_t sz = [attr fileSize];

            NSString *ext = full.pathExtension.lowercaseString;
            BOOL keyFile = [@[@"sqlite", @"sqlite3", @"db", @"plist", @"json", @"realm", @"txt"] containsObject:ext];

            if (sz > maxBytes && !keyFile) { oversize++; continue; }
            if (total + sz > totalCap && !keyFile) { skipped++; continue; }

            NSString *name = subdir.length ? [subdir stringByAppendingPathComponent:rel] : rel;
            if (![self _addFileAtPath:full named:name to:a]) { skipped++; continue; }
            total += sz;
            realFiles++;
        }
        OWLog(@"Archive: %@ 入包 %lu 项 / %llu B（skip %lu，oversize %lu）",
              zipPath.lastPathComponent, (unsigned long)realFiles, total,
              (unsigned long)skipped, (unsigned long)oversize);
        return realFiles > 0;
    }];
}

+ (BOOL)_addData:(NSData *)data named:(NSString *)name to:(struct archive *)a {
    if (!data.length || !name.length) return NO;

    struct archive_entry *entry = archive_entry_new();
    archive_entry_set_pathname(entry, name.fileSystemRepresentation);
    archive_entry_set_filetype(entry, AE_IFREG);
    archive_entry_set_perm(entry, 0644);
    archive_entry_set_size(entry, (int64_t)data.length);
    archive_entry_set_mtime(entry, 0, 0);

    if (archive_write_header(a, entry) != ARCHIVE_OK) {
        archive_entry_free(entry);
        return NO;
    }
    if (archive_write_data(a, data.bytes, data.length) < (ssize_t)data.length) {
        archive_entry_free(entry);
        return NO;
    }
    archive_entry_free(entry);
    return YES;
}

+ (BOOL)_addFileAtPath:(NSString *)path named:(NSString *)rel to:(struct archive *)a {
    FILE *fp = fopen(path.fileSystemRepresentation, "rb");
    if (!fp) return NO;

    struct archive_entry *entry = archive_entry_new();
    archive_entry_set_pathname(entry, rel.fileSystemRepresentation);
    archive_entry_set_filetype(entry, AE_IFREG);
    archive_entry_set_perm(entry, 0644);

    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0) {
        archive_entry_set_size(entry, st.st_size);
        archive_entry_set_mtime(entry, st.st_mtime, 0);
    }

    if (archive_write_header(a, entry) != ARCHIVE_OK) {
        archive_entry_free(entry);
        fclose(fp);
        return NO;
    }

    char buf[65536];
    size_t got;
    while ((got = fread(buf, 1, sizeof(buf), fp)) > 0) {
        if (archive_write_data(a, buf, got) < (ssize_t)got) {
            fclose(fp);
            archive_entry_free(entry);
            return NO;
        }
    }
    fclose(fp);
    archive_entry_free(entry);
    return YES;
}

+ (BOOL)_writeArchive:(NSString *)zipPath
                error:(NSError **)error
              builder:(BOOL (^)(struct archive *a))builder {
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];

    struct archive *a = archive_write_new();
    if (!a) {
        if (error) *error = [NSError errorWithDomain:@"OWArchive" code:60
                                userInfo:@{NSLocalizedDescriptionKey: @"archive_write_new 失败"}];
        return NO;
    }
    archive_write_set_format_zip(a);
    archive_write_set_options(a, "zip:compression=deflate");

    if (archive_write_open_filename(a, zipPath.fileSystemRepresentation) != ARCHIVE_OK) {
        NSString *msg = [NSString stringWithFormat:@"打开 zip 失败: %s", archive_error_string(a)];
        OWLog(@"Archive: %@", msg);
        if (error) *error = [NSError errorWithDomain:@"OWArchive" code:61
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
        archive_write_free(a);
        return NO;
    }

    BOOL any = builder(a);

    archive_write_close(a);
    archive_write_free(a);

    if (!any) {
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
        if (error) *error = [NSError errorWithDomain:@"OWArchive" code:62
                                userInfo:@{NSLocalizedDescriptionKey: @"无条目入包"}];
        return NO;
    }
    return YES;
}

@end
