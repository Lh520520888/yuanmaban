//
//  OWSelfTest.h
//  OPENsrc
//
//  通道自检：不依赖内核、不产生数据，只回答「哪一层通、哪一层断」。
//
//  用法：启动时自动跑一次，或从 UI 手动触发。
//  输出落到 Documents/ow_selftest.log，可直接判断问题归属：
//    B0  MCM 库加载
//    B1  符号绑定
//    B2  签名身份
//    B3  容器枚举
//    B4  sandbox token
//    B5  实际文件读取
//    A0  kernelcache 获取
//    A1  XPF 偏移解析
//    A2  exploit 候选
//    A3  KRW 原语
//    A4  提权
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OWSelfTestLayer) {
    OWSelfTestLayerMCM        = 0,   // B0–B5
    OWSelfTestLayerKernel     = 1,   // A0–A4
    OWSelfTestLayerKeychain   = 2,
};

@interface OWSelfTestResult : NSObject
@property (nonatomic, copy) NSString *code;        // "B0" / "A2" ...
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL passed;
@property (nonatomic, copy, nullable) NSString *detail;
@property (nonatomic, assign) NSTimeInterval elapsed;
@end

@interface OWSelfTest : NSObject

+ (instancetype)shared;

/// 跑通道 B 自检（不需要内核）
- (NSArray<OWSelfTestResult *> *)runChannelB;

/// 跑通道 A 自检（需要 exploit framework 入包）
- (NSArray<OWSelfTestResult *> *)runChannelA;

/// 跑 keychain 自检（需要 A 通过）
- (NSArray<OWSelfTestResult *> *)runKeychain;

/// 全部跑一遍并写日志
- (void)runAll;

/// 最近一次结果
@property (nonatomic, copy, readonly) NSArray<OWSelfTestResult *> *lastResults;

@end

NS_ASSUME_NONNULL_END
