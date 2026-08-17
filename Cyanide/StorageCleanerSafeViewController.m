#import "StorageCleanerSafeViewController.h"

@interface StorageCleanerViewController (StorageCleanerSafePrivate)
- (void)prepareAccess;
- (void)scanCurrentMode;
- (void)updateChrome;
@end

@interface StorageCleanerSafeViewController ()
@property (nonatomic, strong) UIBarButtonItem *safeAccessItem;
@property (nonatomic, assign) BOOL safeDeferFirstScan;
@property (nonatomic, assign) BOOL safeScanDelayScheduled;
@end

@implementation StorageCleanerSafeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.safeAccessItem = [[UIBarButtonItem alloc] initWithTitle:@"Enable Access"
                                                          style:UIBarButtonItemStyleDone
                                                         target:self
                                                         action:@selector(safeEnableAccessTapped)];
    self.navigationItem.leftBarButtonItem = self.safeAccessItem;
    [self safeRefreshAccessButton];
}

- (void)viewDidAppear:(BOOL)animated
{
    // Prevent StorageCleanerViewController from automatically starting the
    // kernel access path on appearance. The user must explicitly request it.
    [self setValue:@YES forKey:@"scDidStartAutomatically"];
    [super viewDidAppear:animated];
    [self safeRefreshAccessButton];
}

- (BOOL)safePrepared
{
    return [[self valueForKey:@"prepared"] boolValue];
}

- (BOOL)safeBusy
{
    return [[self valueForKey:@"busy"] boolValue];
}

- (void)safeRefreshAccessButton
{
    if (!self.safeAccessItem) return;

    BOOL prepared = [self safePrepared];
    BOOL busy = [self safeBusy];

    if (busy && !prepared) {
        self.safeAccessItem.title = @"Enabling…";
        self.safeAccessItem.enabled = NO;
    } else if (prepared) {
        self.safeAccessItem.title = @"Rescan";
        self.safeAccessItem.enabled = !busy;
    } else {
        self.safeAccessItem.title = @"Enable Access";
        self.safeAccessItem.enabled = !busy;
    }
}

- (void)safeEnableAccessTapped
{
    if ([self safeBusy]) return;

    if ([self safePrepared]) {
        [self scanCurrentMode];
        return;
    }

    // The access backend itself is unchanged. Only scheduling is changed:
    // access is explicit, then the first scan waits briefly after success.
    self.safeDeferFirstScan = YES;
    self.safeScanDelayScheduled = NO;
    [self safeRefreshAccessButton];
    [self prepareAccess];
}

- (void)updateChrome
{
    [super updateChrome];
    [self safeRefreshAccessButton];
}

- (void)scanCurrentMode
{
    if (![self safePrepared]) {
        [self safeRefreshAccessButton];
        return;
    }

    if (self.safeDeferFirstScan && !self.safeScanDelayScheduled) {
        self.safeScanDelayScheduled = YES;
        self.safeDeferFirstScan = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.safeScanDelayScheduled = NO;
            if (![self safePrepared] || [self safeBusy]) return;
            [super scanCurrentMode];
        });
        return;
    }

    [super scanCurrentMode];
}

@end
