#import "StorageCleanerPolishedSafeViewController.h"
#import "StorageCleanerIntroViewController.h"
#import "StorageRescueGuideViewController.h"

#import <dlfcn.h>
#import <objc/message.h>

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
    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
        id value = info[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *SCPolishedSafeResolveName(NSString *bundleID)
{
    if (!bundleID.length) return nil;

    NSString *cached = SCPolishedSafeNameCache()[bundleID];
    if (cached.length) return cached;

    // IMPORTANT: this function is only called after Gain Access has completely
    // finished (prepared == YES and busy == NO). Nothing here runs before or
    // concurrently with the Cyanide/DarkSword access path.
    static dispatch_once_t frameworksOnce;
    dispatch_once(&frameworksOnce, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    });

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    id proxy = nil;
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        id (*sendID)(id, SEL, id) = (void *)objc_msgSend;
        proxy = sendID((id)proxyClass, proxySelector, bundleID);
    }

    if (!proxy) return nil;

    id (*sendNoArg)(id, SEL) = (void *)objc_msgSend;
    for (NSString *selectorName in @[@"localizedName", @"itemName", @"bundleDisplayName"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![proxy respondsToSelector:selector]) continue;
        id value = sendNoArg(proxy, selector);
        if ([value isKindOfClass:NSString.class] && [value length] && ![value isEqualToString:bundleID]) {
            SCPolishedSafeNameCache()[bundleID] = value;
            return value;
        }
    }

    SEL bundleURLSelector = NSSelectorFromString(@"bundleURL");
    if ([proxy respondsToSelector:bundleURLSelector]) {
        id value = sendNoArg(proxy, bundleURLSelector);
        if ([value isKindOfClass:NSURL.class]) {
            NSBundle *bundle = [NSBundle bundleWithURL:value];
            NSString *name = SCPolishedSafeFirstName(bundle.localizedInfoDictionary);
            if (!name.length) name = SCPolishedSafeFirstName(bundle.infoDictionary);
            if (name.length && ![name isEqualToString:bundleID]) {
                SCPolishedSafeNameCache()[bundleID] = name;
                return name;
            }
        }
    }

    return nil;
}

@interface StorageCleanerPolishedSafeViewController ()
@property (nonatomic, assign) BOOL scPolishedDidAttemptIntro;
@end

@implementation StorageCleanerPolishedSafeViewController

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (self.scPolishedDidAttemptIntro) return;
    self.scPolishedDidAttemptIntro = YES;

    BOOL prepared = [[self valueForKey:@"prepared"] boolValue];
    BOOL busy = [[self valueForKey:@"busy"] boolValue];
    if (prepared || busy || self.presentedViewController || ![StorageCleanerIntroViewController shouldShow]) return;

    // Static UIKit only: no filesystem walk, LaunchServices query or background
    // task is started before Gain Access.
    StorageCleanerIntroViewController *intro = [[StorageCleanerIntroViewController alloc] init];
    intro.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:intro animated:YES completion:nil];
}

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

    // Never query LaunchServices or app bundle metadata while Gain Access or a
    // scan/cleanup operation is running. This is the key regression fix versus
    // the broken 1.2.1 (11) implementation.
    BOOL prepared = [[self valueForKey:@"prepared"] boolValue];
    BOOL busy = [[self valueForKey:@"busy"] boolValue];
    if (!prepared || busy) return cell;

    UISegmentedControl *areaControl = [self valueForKey:@"cleanerAreaControl"];
    if (areaControl.selectedSegmentIndex != 0) return cell;

    NSArray *records = [self cleanerVisibleRecords];
    if (indexPath.row >= records.count) return cell;

    id record = records[indexPath.row];
    NSString *bundleID = [record valueForKey:@"bundleID"] ?: @"";
    NSString *resolved = SCPolishedSafeResolveName(bundleID);
    if (resolved.length) cell.textLabel.text = resolved;
    return cell;
}

@end
