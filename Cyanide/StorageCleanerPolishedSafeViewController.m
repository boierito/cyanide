#import "StorageCleanerPolishedSafeViewController.h"
#import "StorageRescueGuideViewController.h"

#import <dlfcn.h>
#import <objc/message.h>

@interface StorageRescueDedicatedViewController (StorageCleanerPolishedSafeBackend)
- (void)prepareAccess;
@end

@interface StorageRescueCleanupViewController (StorageCleanerPolishedSafePrivate)
- (NSArray *)cleanerVisibleRecords;
@end

static NSMutableDictionary<NSString *, NSString *> *SCPolishedSafeNameCache(void)
{
    static NSMutableDictionary<NSString *, NSString *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSString *SCPolishedSafeFirstName(NSDictionary *info)
{
    if (![info isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName", @"CFBundleExecutable"]) {
        id value = info[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *SCPolishedSafeBundleName(NSString *bundlePath, NSString **bundleIDOut)
{
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (!bundle) return nil;

    NSDictionary *localized = bundle.localizedInfoDictionary;
    NSDictionary *info = bundle.infoDictionary;
    NSString *bundleID = bundle.bundleIdentifier;
    if (!bundleID.length) {
        id value = info[@"CFBundleIdentifier"];
        if ([value isKindOfClass:NSString.class]) bundleID = value;
    }
    if (bundleIDOut) *bundleIDOut = bundleID;
    if (!bundleID.length) return nil;

    NSString *name = SCPolishedSafeFirstName(localized);
    if (!name.length) name = SCPolishedSafeFirstName(info);
    return name;
}

static void SCPolishedSafeCollectBundles(NSString *root,
                                         NSUInteger maxDepth,
                                         NSMutableDictionary<NSString *, NSString *> *catalog)
{
    if (!root.length || !catalog) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) return;

    NSMutableArray<NSDictionary *> *stack = [NSMutableArray arrayWithObject:@{
        @"path": root,
        @"depth": @0,
    }];

    while (stack.count) {
        @autoreleasepool {
            NSDictionary *item = stack.lastObject;
            [stack removeLastObject];
            NSString *path = item[@"path"];
            NSUInteger depth = [item[@"depth"] unsignedIntegerValue];

            BOOL childIsDirectory = NO;
            if (![fm fileExistsAtPath:path isDirectory:&childIsDirectory] || !childIsDirectory) continue;

            if ([path.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame) {
                NSString *bundleID = nil;
                NSString *name = SCPolishedSafeBundleName(path, &bundleID);
                if (bundleID.length && name.length && ![name isEqualToString:bundleID]) {
                    catalog[bundleID] = name;
                }
                continue; // Never recurse inside an application bundle.
            }

            if (depth >= maxDepth) continue;
            NSError *error = nil;
            NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:&error];
            if (!children.count) continue;

            for (NSString *child in children) {
                if ([child hasPrefix:@"."]) continue;
                NSString *childPath = [path stringByAppendingPathComponent:child];
                [stack addObject:@{
                    @"path": childPath,
                    @"depth": @(depth + 1),
                }];
            }
        }
    }
}

static NSString *SCPolishedSafeLaunchServicesName(NSString *bundleID)
{
    if (!bundleID.length) return nil;

    static dispatch_once_t frameworksOnce;
    dispatch_once(&frameworksOnce, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    });

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySelector]) return nil;

    id (*sendID)(id, SEL, id) = (void *)objc_msgSend;
    id proxy = sendID((id)proxyClass, proxySelector, bundleID);
    if (!proxy) return nil;

    id (*sendNoArg)(id, SEL) = (void *)objc_msgSend;
    for (NSString *selectorName in @[@"localizedName", @"itemName", @"bundleDisplayName"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![proxy respondsToSelector:selector]) continue;
        id value = sendNoArg(proxy, selector);
        if ([value isKindOfClass:NSString.class] && [value length] && ![value isEqualToString:bundleID]) {
            return value;
        }
    }

    SEL bundleURLSelector = NSSelectorFromString(@"bundleURL");
    if ([proxy respondsToSelector:bundleURLSelector]) {
        id value = sendNoArg(proxy, bundleURLSelector);
        if ([value isKindOfClass:NSURL.class]) {
            NSString *resolvedBundleID = nil;
            NSString *name = SCPolishedSafeBundleName([value path], &resolvedBundleID);
            if (name.length) return name;
        }
    }

    return nil;
}

@interface StorageCleanerPolishedSafeViewController ()
@property (nonatomic, assign) BOOL scStartupScheduled;
@property (nonatomic, assign) BOOL scAutoAccessStarted;
@property (nonatomic, assign) BOOL scNameCatalogStarted;
@property (nonatomic, strong) UIView *scStartupOverlay;
@property (nonatomic, strong) UILabel *scStartupStatusLabel;
@property (nonatomic, strong) UILabel *scStartupCountdownLabel;
@end

@implementation StorageCleanerPolishedSafeViewController

#pragma mark - Safe automatic startup

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (self.scStartupScheduled) return;
    self.scStartupScheduled = YES;

    BOOL prepared = [[self valueForKey:@"prepared"] boolValue];
    BOOL busy = [[self valueForKey:@"busy"] boolValue];
    if (prepared) {
        [self scWaitForIdleThenResolveNames];
        return;
    }
    if (busy) {
        [self scMonitorAutomaticAccess];
        return;
    }

    [self scShowStartupOverlay];
    [self scRunCountdown:5];
}

- (void)scShowStartupOverlay
{
    UIView *host = self.navigationController.view ?: self.view;
    if (!host || self.scStartupOverlay) return;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = UIColor.systemBackgroundColor;
    overlay.accessibilityViewIsModal = YES;
    [host addSubview:overlay];
    self.scStartupOverlay = overlay;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"externaldrive.badge.checkmark"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.systemBlueColor;
    [icon.heightAnchor constraintEqualToConstant:64.0].active = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.text = @"Storage Cleaner";
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *descriptionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    descriptionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    descriptionLabel.textColor = UIColor.secondaryLabelColor;
    descriptionLabel.numberOfLines = 0;
    descriptionLabel.textAlignment = NSTextAlignmentCenter;
    descriptionLabel.text = @"Scans temporary app cache and compatible iOS cache. Nothing is deleted automatically.";

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    [spinner startAnimating];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    status.textAlignment = NSTextAlignmentCenter;
    status.text = @"Getting ready…";
    self.scStartupStatusLabel = status;

    UILabel *countdown = [[UILabel alloc] initWithFrame:CGRectZero];
    countdown.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    countdown.textColor = UIColor.secondaryLabelColor;
    countdown.textAlignment = NSTextAlignmentCenter;
    self.scStartupCountdownLabel = countdown;

    UILabel *warning = [[UILabel alloc] initWithFrame:CGRectZero];
    warning.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    warning.textColor = UIColor.tertiaryLabelColor;
    warning.numberOfLines = 0;
    warning.textAlignment = NSTextAlignmentCenter;
    warning.text = @"Close apps before cleaning them. Cleanup is permanent, but apps and iOS may recreate cache later.";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon,
        title,
        descriptionLabel,
        spinner,
        status,
        countdown,
        warning,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;
    [overlay addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:host.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],

        [stack.leadingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.leadingAnchor constant:28.0],
        [stack.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-28.0],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.centerYAnchor],
    ]];
}

- (void)scRunCountdown:(NSInteger)remaining
{
    if (self.scAutoAccessStarted) return;

    if (remaining <= 0) {
        self.scAutoAccessStarted = YES;
        self.scStartupStatusLabel.text = @"Enabling storage access…";
        self.scStartupCountdownLabel.text = @"This can take a moment.";

        // This is the exact inherited Gain Access path used by the working
        // 1.2.1 (12). The five-second delay is entirely on the main queue.
        [self prepareAccess];
        [self scMonitorAutomaticAccess];
        return;
    }

    self.scStartupCountdownLabel.text = [NSString stringWithFormat:@"Storage access starts automatically in %ld…",
                                         (long)remaining];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self scRunCountdown:remaining - 1];
    });
}

- (void)scMonitorAutomaticAccess
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL prepared = [[self valueForKey:@"prepared"] boolValue];
        BOOL busy = [[self valueForKey:@"busy"] boolValue];

        if (prepared) {
            self.scStartupStatusLabel.text = busy ? @"Access enabled. Scanning…" : @"Access enabled.";
            [self scDismissStartupOverlay];
            [self scWaitForIdleThenResolveNames];
            return;
        }

        if (self.scAutoAccessStarted && !busy) {
            // The existing backend owns failure reporting. Do not wrap or alter
            // its alert/error path; simply uncover the normal interface.
            [self scDismissStartupOverlay];
            return;
        }

        [self scMonitorAutomaticAccess];
    });
}

- (void)scDismissStartupOverlay
{
    UIView *overlay = self.scStartupOverlay;
    if (!overlay) return;
    self.scStartupOverlay = nil;
    self.scStartupStatusLabel = nil;
    self.scStartupCountdownLabel = nil;

    [UIView animateWithDuration:0.20 animations:^{
        overlay.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

#pragma mark - Post-access real application names

- (void)scWaitForIdleThenResolveNames
{
    if (self.scNameCatalogStarted) return;

    BOOL prepared = [[self valueForKey:@"prepared"] boolValue];
    BOOL busy = [[self valueForKey:@"busy"] boolValue];
    if (!prepared) return;

    if (busy) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self scWaitForIdleThenResolveNames];
        });
        return;
    }

    // Critical ordering guarantee: this is the first point where extra app
    // bundle / LaunchServices lookup is permitted. Gain Access has completed and
    // the automatic progressive scan is idle.
    self.scNameCatalogStarted = YES;

    NSArray *recordsSnapshot = [[self valueForKey:@"appRecords"] copy] ?: @[];
    NSMutableArray<NSString *> *bundleIDs = [NSMutableArray array];
    for (id record in recordsSnapshot) {
        NSString *bundleID = [record valueForKey:@"bundleID"];
        if (bundleID.length) [bundleIDs addObject:bundleID];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary<NSString *, NSString *> *catalog = [NSMutableDictionary dictionary];

        // Third-party apps live under UUID directories here. System roots are
        // included as a fallback for Apple apps and unusual installations.
        SCPolishedSafeCollectBundles(@"/var/containers/Bundle/Application", 2, catalog);
        SCPolishedSafeCollectBundles(@"/Applications", 2, catalog);
        SCPolishedSafeCollectBundles(@"/System/Applications", 3, catalog);
        SCPolishedSafeCollectBundles(@"/System/Cryptexes/App/System/Applications", 3, catalog);

        for (NSString *bundleID in bundleIDs) {
            if (catalog[bundleID].length) continue;
            NSString *name = SCPolishedSafeLaunchServicesName(bundleID);
            if (name.length) catalog[bundleID] = name;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [SCPolishedSafeNameCache() addEntriesFromDictionary:catalog];
            [self scApplyCachedNamesToRecords];
        });
    });
}

- (void)scApplyCachedNamesToRecords
{
    BOOL changed = NO;
    NSArray *records = [self valueForKey:@"appRecords"];
    for (id record in records) {
        NSString *bundleID = [record valueForKey:@"bundleID"] ?: @"";
        NSString *resolved = SCPolishedSafeNameCache()[bundleID];
        NSString *current = [record valueForKey:@"displayName"] ?: @"";
        if (resolved.length && ![resolved isEqualToString:current]) {
            [record setValue:resolved forKey:@"displayName"];
            changed = YES;
        }
    }
    if (changed) [self.tableView reloadData];
}

#pragma mark - Cleaner presentation

- (UIMenu *)cleanerMoreMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *help = [UIAction actionWithTitle:@"FAQ, Tutorial & Credits"
                                         image:[UIImage systemImageNamed:@"questionmark.circle"]
                                    identifier:nil
                                       handler:^(__kindof UIAction *action) {
        StorageRescueGuideViewController *guide = [[StorageRescueGuideViewController alloc] init];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:guide];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [weakSelf presentViewController:navigation animated:YES completion:nil];
    }];

    // Protected Cleanup is intentionally not exposed as a normal user-facing
    // mode. The backend fallback remains untouched for contextual use.
    return [UIMenu menuWithTitle:@"" children:@[help]];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    UISegmentedControl *areaControl = [self valueForKey:@"cleanerAreaControl"];
    if (areaControl.selectedSegmentIndex == 1) {
        return @"System Cache shows compatible iOS CacheDelete leftovers. If this list is empty, there is currently nothing compatible to remove.";
    }
    return [super tableView:tableView titleForFooterInSection:section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

    BOOL prepared = [[self valueForKey:@"prepared"] boolValue];
    BOOL busy = [[self valueForKey:@"busy"] boolValue];
    if (!prepared || busy) return cell;

    UISegmentedControl *areaControl = [self valueForKey:@"cleanerAreaControl"];
    if (areaControl.selectedSegmentIndex != 0) return cell;

    NSArray *records = [self cleanerVisibleRecords];
    if (indexPath.row >= records.count) return cell;

    id record = records[indexPath.row];
    NSString *bundleID = [record valueForKey:@"bundleID"] ?: @"";
    NSString *resolved = SCPolishedSafeNameCache()[bundleID];
    if (resolved.length) {
        cell.textLabel.text = resolved;
        if (![[record valueForKey:@"displayName"] isEqualToString:resolved]) {
            [record setValue:resolved forKey:@"displayName"];
        }
    }
    return cell;
}

@end
