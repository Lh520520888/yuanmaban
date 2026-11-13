#import "OWDebugPanel.h"
#import "OWCommon.h"
#import "OWSelfTest.h"
#import "OWExfil.h"

#import <unistd.h>

@interface OWDebugPanel ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong, nullable) NSTimer *timer;
@end

@implementation OWDebugPanel

+ (void)presentFrom:(UIViewController *)host {
    if (!host) return;
    OWDebugPanel *panel = [OWDebugPanel new];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:panel];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [host presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"调试面板";

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(onClose)];

    UILabel *status = [UILabel new];
    status.numberOfLines = 0;
    status.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    status.textColor = [UIColor secondaryLabelColor];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:status];
    self.statusLabel = status;

    NSArray<UIButton *> *buttons = @[
        [self makeButton:@"运行自检" action:@selector(onSelfTest)],
        [self makeButton:@"上传端点" action:@selector(onEditEndpoint)],
        [self makeButton:@"补传 pending" action:@selector(onFlushPending)],
        [self makeButton:@"分享日志" action:@selector(onShareLog)],
        [self makeButton:@"清 done 标记" action:@selector(onResetDone)],
    ];
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.distribution = UIStackViewDistributionFillEqually;
    bar.spacing = 6;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UITextView *tv = [UITextView new];
    tv.editable = NO;
    tv.alwaysBounceVertical = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    self.textView = tv;

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [status.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [status.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [status.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],

        [bar.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:8],
        [bar.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [bar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [bar.heightAnchor constraintEqualToConstant:34],

        [tv.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [tv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [tv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    ]];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

#pragma mark - UI

- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.7;
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 6;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refresh {
    OWDeviceProfile *dev = [OWDeviceProfile current];
    NSString *phase = [[OWState shared] objectForKey:@"phase"] ?: @"idle";
    NSString *endpoint = [OWUploader activeEndpoint];
    NSUInteger pending = [self pendingCount];

    self.statusLabel.text = [NSString stringWithFormat:
        @"phase=%@  uid=%d  done=%d\n"
        @"iOS %@ (%@)  %@\n"
        @"bundle=%@\n"
        @"endpoint=%@\n"
        @"pending=%lu 项",
        phase, getuid(), [[OWState shared] isDone] ? 1 : 0,
        dev.osVersion, dev.osBuild.length ? dev.osBuild : @"?",
        dev.machine ?: @"?",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
        endpoint.length ? endpoint : @"(空)",
        (unsigned long)pending];

    NSData *tail = [OWLogger tail:128 * 1024];
    NSString *log = tail.length ? [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding] : nil;
    if (!log.length) log = @"(暂无日志)";
    self.textView.text = log;
    if (log.length > 1) {
        [self.textView scrollRangeToVisible:NSMakeRange(log.length - 1, 1)];
    }
}

- (NSUInteger)pendingCount {
    NSString *dir = [OWUploader new].pendingDir;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSUInteger n = 0;
    for (NSString *f in items) {
        if ([f.pathExtension isEqualToString:@"meta"]) n++;
    }
    return n;
}

- (void)append:(NSString *)line {
    OWLog(@"调试面板: %@", line);
    [self refresh];
}

#pragma mark - 动作

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onSelfTest {
    [self append:@"开始分层自检（B0-B6 / A0-A4 / K0-K2）"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[OWSelfTest shared] runAll];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    });
}

- (void)onEditEndpoint {
    NSString *current = [OWUploader activeEndpoint];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"上传端点"
                         message:@"留空并保存 = 清除覆盖，回到 Info.plist 内置值"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current;
        tf.placeholder = @"https://host/path";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action) {
        NSString *text = ac.textFields.firstObject.text ?: @"";
        text = [text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (text.length) [d setObject:text forKey:@"OWUploadEndpointOverride"];
        else [d removeObjectForKey:@"OWUploadEndpointOverride"];
        [d synchronize];
        [weakSelf append:[NSString stringWithFormat:@"上传端点覆盖 = %@",
                          text.length ? text : @"(已清除，使用内置)"]];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onFlushPending {
    [self append:@"开始补传 pending"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OWUploader *up = [OWUploader new];
        NSError *error = nil;
        BOOL ok = [up flush:&error];
        OWLog(@"调试面板: 补传结束 ok=%d uploaded=%lu failed=%lu %@",
              ok, (unsigned long)up.uploadedCount, (unsigned long)up.failedCount,
              error.localizedDescription ?: @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    });
}

- (void)onShareLog {
    NSString *path = [OWLogger logPath];
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self append:@"日志文件不存在"];
        return;
    }
    UIActivityViewController *ac =
        [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                              applicationActivities:nil];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onResetDone {
    [[OWState shared] removeObjectForKey:OWStateKeyDone];
    [[OWState shared] synchronize];
    [self append:@"已清除 done 标记，下次启动会重新跑"];
}

@end
