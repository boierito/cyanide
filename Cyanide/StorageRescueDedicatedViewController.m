#import "StorageRescueDedicatedViewController.h"
#import "StorageRescueGuideViewController.h"
#import "StorageRescueRecoveryViewController.h"

#import "kexploit/kexploit_opa334.h"
#import "utils/sandbox.h"

#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

extern int escape_sbx_demo2(void);

static NSString * const SRTargetPath = @"/var/mobile/Documents/test";
static NSString * const SRAppDataRoot = @"/var/mobile/Containers/Data/Application";
static NSString * const SRDiscardedRoot = @"/var/mobile/Library/Caches/com.apple.cache_delete/com.apple.CacheDeleteAppContainerCaches.discardedCaches";
static NSString * const SRGuideSeenKey = @"storageRescue.guideSeen.1_1";

typedef NS_ENUM(NSInteger, SRBrowserMode) {
    SRBrowserModeApps = 0,
    SRBrowserModeDiscarded = 1,
    SRBrowserModeStaging = 2,
};

typedef struct {
    uint64_t allocatedBytes;
    uint64_t logicalBytes;
    NSUInteger files;
    NSUInteger dirs;
    NSUInteger errors;
} SRBrowseUsage;

typedef struct {
    uint64_t removedAllocatedBytes;
    NSUInteger removedFiles;
    NSUInteger removedDirs;
    NSUInteger failures;
} SRBrowseDeleteSummary;

typedef struct {
    NSUInteger movedItems;
    NSUInteger failures;
} SRMoveSummary;

@interface SRCacheRecord : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic, copy) NSString *sourcePath;
@property (nonatomic, assign) uint64_t cacheBytes;
@property (nonatomic, assign) uint64_t temporaryBytes;
@property (nonatomic, assign) NSUInteger itemCount;
@property (nonatomic, assign) BOOL discarded;
@property (nonatomic, assign) BOOL cacheDirectoryExists;
@property (nonatomic, assign) BOOL temporaryDirectoryExists;
@end

@implementation SRCacheRecord
- (uint64_t)totalBytes { return self.cacheBytes + self.temporaryBytes; }
@end

static NSString *SRNameFromDirent(const struct dirent *entry)
{
    if (!entry || !entry->d_name[0]) return nil;
    return [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:entry->d_name
            length:strlen(entry->d_name)];
}

static NSString *SRFormatBytes(uint64_t bytes)
{
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseKB |
                             NSByteCountFormatterUseMB |
                             NSByteCountFormatterUseGB |
                             NSByteCountFormatterUseTB;
    return [formatter stringFromByteCount:(long long)bytes];
}

static NSString *SRStandardPath(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) return @"";
    return [path stringByStandardizingPath];
}

static BOOL SRPathWithinRoot(NSString *path, NSString *root, BOOL allowRoot)
{
    NSString *safePath = SRStandardPath(path);
    NSString *safeRoot = SRStandardPath(root);
    if (!safePath.length || !safeRoot.length || [safePath containsString:@".."] || [safeRoot containsString:@".."]) return NO;
    if (allowRoot && [safePath isEqualToString:safeRoot]) return YES;
    return [safePath hasPrefix:[safeRoot stringByAppendingString:@"/"]];
}

static BOOL SRDirectoryExists(NSString *path)
{
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode);
}

static BOOL SRIsApplicationContainerPath(NSString *path)
{
    NSString *safe = SRStandardPath(path);
    if (!SRPathWithinRoot(safe, SRAppDataRoot, NO)) return NO;
    return [[NSUUID alloc] initWithUUIDString:safe.lastPathComponent] != nil;
}

static BOOL SREnsureDirectory(NSString *path, NSError **error)
{
    NSString *safe = SRStandardPath(path);
    if (!SRPathWithinRoot(safe, SRTargetPath, YES)) {
        if (error) {
            *error = [NSError errorWithDomain:@"StorageRescue"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Storage Rescue refused an unsafe rescue path."}];
        }
        return NO;
    }
    if (SRDirectoryExists(safe)) return YES;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:safe
                                        withIntermediateDirectories:YES
                                                         attributes:@{NSFilePosixPermissions: @(0755)}
                                                              error:error];
    return ok && SRDirectoryExists(safe);
}

static SRBrowseUsage SRScanPath(NSString *root)
{
    SRBrowseUsage usage = {0};
    NSString *safeRoot = SRStandardPath(root);
    struct stat rootStat;
    if (lstat(safeRoot.fileSystemRepresentation, &rootStat) != 0) return usage;

    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:safeRoot];
    while (stack.count) {
        @autoreleasepool {
            NSString *path = stack.lastObject;
            [stack removeLastObject];
            if (!SRPathWithinRoot(path, safeRoot, YES)) {
                usage.errors++;
                continue;
            }

            struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) != 0) {
                if (errno != ENOENT) usage.errors++;
                continue;
            }

            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                usage.files++;
                usage.logicalBytes += st.st_size > 0 ? (uint64_t)st.st_size : 0;
                usage.allocatedBytes += (uint64_t)st.st_blocks * 512ULL;
                continue;
            }

            usage.dirs++;
            DIR *directory = opendir(path.fileSystemRepresentation);
            if (!directory) {
                usage.errors++;
                continue;
            }
            struct dirent *entry;
            while ((entry = readdir(directory))) {
                if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                NSString *name = SRNameFromDirent(entry);
                if (!name.length) continue;
                NSString *child = [path stringByAppendingPathComponent:name];
                if (SRPathWithinRoot(child, safeRoot, NO)) [stack addObject:child];
            }
            closedir(directory);
        }
    }
    return usage;
}

static NSArray<NSString *> *SRTopLevelEntries(NSString *root)
{
    NSString *safeRoot = SRStandardPath(root);
    DIR *directory = opendir(safeRoot.fileSystemRepresentation);
    if (!directory) return @[];

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = SRNameFromDirent(entry);
        if (!name.length) continue;
        NSString *child = [safeRoot stringByAppendingPathComponent:name];
        if (SRPathWithinRoot(child, safeRoot, NO)) [paths addObject:child];
    }
    closedir(directory);
    return paths;
}

static SRBrowseDeleteSummary SRDeleteDirectoryContents(NSString *root)
{
    SRBrowseDeleteSummary summary = {0};
    NSString *safeRoot = SRStandardPath(root);
    if (!SRDirectoryExists(safeRoot)) return summary;

    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithArray:SRTopLevelEntries(safeRoot)];
    NSMutableArray<NSString *> *directories = [NSMutableArray array];

    while (stack.count) {
        @autoreleasepool {
            NSString *path = stack.lastObject;
            [stack removeLastObject];
            if (!SRPathWithinRoot(path, safeRoot, NO)) {
                summary.failures++;
                continue;
            }

            struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) != 0) {
                if (errno != ENOENT) summary.failures++;
                continue;
            }

            if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
                [directories addObject:path];
                DIR *directory = opendir(path.fileSystemRepresentation);
                if (!directory) {
                    summary.failures++;
                    continue;
                }
                struct dirent *entry;
                while ((entry = readdir(directory))) {
                    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                    NSString *name = SRNameFromDirent(entry);
                    if (!name.length) continue;
                    NSString *child = [path stringByAppendingPathComponent:name];
                    if (SRPathWithinRoot(child, safeRoot, NO)) [stack addObject:child];
                }
                closedir(directory);
                continue;
            }

            uint64_t allocated = (uint64_t)st.st_blocks * 512ULL;
            errno = 0;
            if (unlink(path.fileSystemRepresentation) == 0 || errno == ENOENT) {
                summary.removedFiles++;
                summary.removedAllocatedBytes += allocated;
            } else {
                summary.failures++;
            }
        }
    }

    [directories sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSInteger leftDepth = left.pathComponents.count;
        NSInteger rightDepth = right.pathComponents.count;
        if (leftDepth > rightDepth) return NSOrderedAscending;
        if (leftDepth < rightDepth) return NSOrderedDescending;
        return [right compare:left];
    }];

    for (NSString *directory in directories) {
        if (!SRPathWithinRoot(directory, safeRoot, NO)) {
            summary.failures++;
            continue;
        }
        errno = 0;
        if (rmdir(directory.fileSystemRepresentation) == 0 || errno == ENOENT) {
            summary.removedDirs++;
        } else if (errno != ENOTEMPTY) {
            summary.failures++;
        }
    }

    return summary;
}

static NSString *SRUniqueDestination(NSString *directory, NSString *name)
{
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    struct stat st;
    if (lstat(candidate.fileSystemRepresentation, &st) != 0 && errno == ENOENT) return candidate;

    NSString *base = name.stringByDeletingPathExtension;
    NSString *extension = name.pathExtension;
    NSString *suffix = [NSUUID UUID].UUIDString.lowercaseString;
    NSString *uniqueName = extension.length
        ? [NSString stringWithFormat:@"%@-%@.%@", base, suffix, extension]
        : [NSString stringWithFormat:@"%@-%@", base, suffix];
    return [directory stringByAppendingPathComponent:uniqueName];
}

static SRMoveSummary SRMoveTopLevelContents(NSString *sourceRoot, NSString *destinationRoot)
{
    SRMoveSummary summary = {0};
    NSString *safeSource = SRStandardPath(sourceRoot);
    NSString *safeDestination = SRStandardPath(destinationRoot);
    if (!SRDirectoryExists(safeSource) || !SRPathWithinRoot(safeDestination, SRTargetPath, YES)) return summary;

    NSError *directoryError = nil;
    if (!SREnsureDirectory(safeDestination, &directoryError)) {
        summary.failures++;
        return summary;
    }

    for (NSString *source in SRTopLevelEntries(safeSource)) {
        @autoreleasepool {
            if (!SRPathWithinRoot(source, safeSource, NO)) {
                summary.failures++;
                continue;
            }
            NSString *destination = SRUniqueDestination(safeDestination, source.lastPathComponent);
            errno = 0;
            if (rename(source.fileSystemRepresentation, destination.fileSystemRepresentation) == 0) {
                summary.movedItems++;
            } else {
                summary.failures++;
            }
        }
    }
    return summary;
}

static BOOL SRMoveWholePathToDirectory(NSString *source, NSString *destinationDirectory)
{
    NSString *safeSource = SRStandardPath(source);
    NSString *safeDestinationDirectory = SRStandardPath(destinationDirectory);
    if (!SRPathWithinRoot(safeSource, SRDiscardedRoot, NO) ||
        !SRPathWithinRoot(safeDestinationDirectory, SRTargetPath, YES)) return NO;

    NSError *error = nil;
    if (!SREnsureDirectory(safeDestinationDirectory, &error)) return NO;
    NSString *destination = SRUniqueDestination(safeDestinationDirectory, safeSource.lastPathComponent);
    errno = 0;
    return rename(safeSource.fileSystemRepresentation, destination.fileSystemRepresentation) == 0;
}

static NSString *SRBundleIdentifierForContainer(NSString *containerPath)
{
    NSString *metadataPath = [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;

    NSArray<NSString *> *keys = @[@"MCMMetadataIdentifier", @"Identifier", @"CFBundleIdentifier"];
    for (NSString *key in keys) {
        id value = metadata[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }

    NSDictionary *info = [metadata[@"MCMMetadataInfo"] isKindOfClass:NSDictionary.class]
        ? metadata[@"MCMMetadataInfo"] : nil;
    for (NSString *key in keys) {
        id value = info[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *SRApplicationDisplayName(NSString *bundleID)
{
    if (!bundleID.length) return @"Unknown App";

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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

    if (proxy) {
        id (*sendNoArg)(id, SEL) = (void *)objc_msgSend;
        for (NSString *selectorName in @[@"localizedName", @"itemName", @"bundleDisplayName"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![proxy respondsToSelector:selector]) continue;
            id value = sendNoArg(proxy, selector);
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        }
    }

    NSString *last = bundleID.pathExtension;
    return last.length ? last : bundleID;
}

static NSString *SRDiscardedDisplayName(NSString *path, NSString **identifierOut)
{
    NSString *bundleID = SRBundleIdentifierForContainer(path);
    if (bundleID.length) {
        if (identifierOut) *identifierOut = bundleID;
        return SRApplicationDisplayName(bundleID);
    }

    DIR *directory = opendir(path.fileSystemRepresentation);
    if (directory) {
        struct dirent *entry;
        while ((entry = readdir(directory))) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            NSString *name = SRNameFromDirent(entry);
            if (!name.length || [name hasPrefix:@"."]) continue;
            closedir(directory);
            if (identifierOut) *identifierOut = name;
            return name;
        }
        closedir(directory);
    }

    if (identifierOut) *identifierOut = path.lastPathComponent;
    return path.lastPathComponent.length ? path.lastPathComponent : @"Protected cache";
}

@interface StorageRescueDedicatedViewController ()
@property (nonatomic, assign) SRBrowserMode browserMode;
@property (nonatomic, assign) BOOL prepared;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL targetExists;
@property (nonatomic, assign) BOOL discardedRootExists;
@property (nonatomic, assign) BOOL guidePresentedThisLaunch;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, strong) NSArray<SRCacheRecord *> *appRecords;
@property (nonatomic, strong) NSArray<SRCacheRecord *> *discardedRecords;
@property (nonatomic, assign) SRBrowseUsage stagingUsage;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIdentifiers;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UISearchController *cacheSearchController;
@property (nonatomic, strong) UIBarButtonItem *refreshItem;
@property (nonatomic, strong) UIBarButtonItem *infoItem;
@property (nonatomic, strong) UIBarButtonItem *selectionItem;
@property (nonatomic, strong) UIView *modeHeader;
@property (nonatomic, strong) UIImageView *modeIcon;
@property (nonatomic, strong) UILabel *modeTitleLabel;
@property (nonatomic, strong) UILabel *modeBodyLabel;
@end

@implementation StorageRescueDedicatedViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _browserMode = SRBrowserModeApps;
        _statusText = @"Storage access is not enabled";
        _appRecords = @[];
        _discardedRecords = @[];
        _selectedIdentifiers = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Storage Rescue";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;

    self.cacheSearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.cacheSearchController.obscuresBackgroundDuringPresentation = NO;
    self.cacheSearchController.searchResultsUpdater = self;
    self.cacheSearchController.searchBar.placeholder = @"Search apps";
    self.definesPresentationContext = YES;

    self.refreshItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self
        action:@selector(scanCurrentMode)];
    self.refreshItem.accessibilityLabel = @"Refresh cache scan";

    self.infoItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"info.circle"]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(showGuide)];
    self.infoItem.accessibilityLabel = @"How Storage Rescue works";

    self.selectionItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"checklist"]
        style:UIBarButtonItemStylePlain
        target:nil
        action:nil];
    self.selectionItem.accessibilityLabel = @"Selection options";

    self.navigationItem.rightBarButtonItems = @[self.refreshItem, self.infoItem];
    [self buildModeHeader];
    [self updateInterface];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.guidePresentedThisLaunch) return;
    self.guidePresentedThisLaunch = YES;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:SRGuideSeenKey]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SRGuideSeenKey];
        [self showGuide];
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self sizeModeHeaderIfNeeded];
}

#pragma mark - Friendly header

- (void)buildModeHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 220.0)];

    UIStackView *rootStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    rootStack.axis = UILayoutConstraintAxisVertical;
    rootStack.spacing = 12.0;
    [header addSubview:rootStack];

    UISegmentedControl *segments = [[UISegmentedControl alloc] initWithItems:@[@"App Cache", @"Protected", @"Rescue"]];
    segments.selectedSegmentIndex = SRBrowserModeApps;
    [segments addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    self.modeControl = segments;
    [rootStack addArrangedSubview:segments];

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"app.fill"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.systemBlueColor;
    self.modeIcon = icon;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;
    self.modeTitleLabel = title;

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectZero];
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    body.textColor = UIColor.secondaryLabelColor;
    body.numberOfLines = 0;
    body.adjustsFontForContentSizeCategory = YES;
    self.modeBodyLabel = body;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[title, body]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 4.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, text]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 12.0;
    row.layoutMargins = UIEdgeInsetsMake(15, 15, 15, 15);
    row.layoutMarginsRelativeArrangement = YES;
    [card addSubview:row];
    [rootStack addArrangedSubview:card];

    [NSLayoutConstraint activateConstraints:@[
        [rootStack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [rootStack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [rootStack.topAnchor constraintEqualToAnchor:header.topAnchor constant:8.0],
        [rootStack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12.0],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:card.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [icon.widthAnchor constraintEqualToConstant:30.0],
        [icon.heightAnchor constraintEqualToConstant:30.0],
    ]];

    self.modeHeader = header;
    self.tableView.tableHeaderView = header;
    [self updateModeHeaderContent];
}

- (void)sizeModeHeaderIfNeeded
{
    if (!self.modeHeader) return;
    CGFloat width = self.tableView.bounds.size.width;
    CGRect frame = self.modeHeader.frame;
    frame.size.width = width;
    self.modeHeader.frame = frame;
    [self.modeHeader setNeedsLayout];
    [self.modeHeader layoutIfNeeded];

    CGSize fitting = [self.modeHeader systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                      withHorizontalFittingPriority:UILayoutPriorityRequired
                                            verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = MAX(150.0, fitting.height);
    if (fabs(frame.size.height - height) > 0.5) {
        frame.size.height = height;
        self.modeHeader.frame = frame;
        self.tableView.tableHeaderView = self.modeHeader;
    }
}

- (void)updateModeHeaderContent
{
    if (self.browserMode == SRBrowserModeApps) {
        self.modeIcon.image = [UIImage systemImageNamed:@"app.fill"];
        self.modeIcon.tintColor = UIColor.systemBlueColor;
        self.modeTitleLabel.text = @"Clear temporary app files";
        self.modeBodyLabel.text = @"Storage Rescue only scans each app's cache and temporary folders. Your documents and normal app data are outside this cleanup scope.";
    } else if (self.browserMode == SRBrowserModeDiscarded) {
        self.modeIcon.image = [UIImage systemImageNamed:@"archivebox.fill"];
        self.modeIcon.tintColor = UIColor.systemOrangeColor;
        self.modeTitleLabel.text = @"Recover cache iOS left behind";
        self.modeBodyLabel.text = @"Protected Cache shows CacheDelete leftovers when they exist. Selected items are moved into the Rescue area first; moving them alone does not free storage.";
    } else {
        self.modeIcon.image = [UIImage systemImageNamed:@"lifepreserver.fill"];
        self.modeIcon.tintColor = UIColor.systemRedColor;
        self.modeTitleLabel.text = @"Finish protected cleanup";
        self.modeBodyLabel.text = @"Rescue handles cache that normal deletion could not remove. It verifies one real deletion before full cleanup becomes available.";
    }
    [self sizeModeHeaderIfNeeded];
}

#pragma mark - Guide

- (void)showGuide
{
    StorageRescueGuideViewController *guide = [[StorageRescueGuideViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:guide];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

#pragma mark - Access

- (BOOL)prepareAccessSync:(NSString **)errorText
{
    if (!kexploit_krw_ready()) {
        int result = kexploit_opa334();
        if (result != 0 || !kexploit_krw_ready()) {
            if (errorText) *errorText = [NSString stringWithFormat:@"Storage access could not be initialized (%d).", result];
            return NO;
        }
    }

    if (check_sandbox_var_rw() != 0) {
        int result = escape_sbx_demo2();
        if (result != 0 || check_sandbox_var_rw() != 0) {
            if (errorText) *errorText = [NSString stringWithFormat:@"Storage access could not be granted (%d).", result];
            return NO;
        }
    }

    NSError *folderError = nil;
    if (!SREnsureDirectory(SRTargetPath, &folderError)) {
        if (errorText) *errorText = folderError.localizedDescription ?: @"The Rescue area could not be prepared.";
        return NO;
    }

    DIR *appRoot = opendir(SRAppDataRoot.fileSystemRepresentation);
    if (!appRoot) {
        if (errorText) *errorText = @"Installed app storage could not be enumerated.";
        return NO;
    }
    closedir(appRoot);
    return YES;
}

- (void)prepareAccess
{
    if (self.busy) return;
    self.busy = YES;
    self.statusText = @"Enabling storage access…";
    [self updateInterface];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *errorText = nil;
        BOOL ok = [self prepareAccessSync:&errorText];
        BOOL targetExists = SRDirectoryExists(SRTargetPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.prepared = ok;
            self.targetExists = targetExists;
            self.statusText = ok ? @"Storage access ready" : (errorText ?: @"Storage access failed");
            [self updateInterface];
            if (ok) {
                [self scanCurrentMode];
            } else {
                [self showSimpleAlert:@"Storage Access Failed" message:self.statusText];
            }
        });
    });
}

- (BOOL)requirePrepared
{
    if (self.prepared) return YES;
    [self showSimpleAlert:@"Enable Storage Access First"
                  message:@"Storage Rescue never starts low-level access automatically. Tap Enable Storage Access before scanning or cleaning."];
    return NO;
}

#pragma mark - Scanning

- (NSArray<SRCacheRecord *> *)loadAppRecords
{
    NSMutableArray<SRCacheRecord *> *records = [NSMutableArray array];
    DIR *directory = opendir(SRAppDataRoot.fileSystemRepresentation);
    if (!directory) return @[];

    NSString *ownBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        @autoreleasepool {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            NSString *name = SRNameFromDirent(entry);
            if (!name.length || ![[NSUUID alloc] initWithUUIDString:name]) continue;

            NSString *container = [SRAppDataRoot stringByAppendingPathComponent:name];
            if (!SRIsApplicationContainerPath(container)) continue;
            NSString *bundleID = SRBundleIdentifierForContainer(container);
            if (!bundleID.length || [bundleID isEqualToString:ownBundleID]) continue;

            NSString *cachePath = [container stringByAppendingPathComponent:@"Library/Caches"];
            NSString *tmpPath = [container stringByAppendingPathComponent:@"tmp"];
            BOOL cacheExists = SRDirectoryExists(cachePath);
            BOOL tmpExists = SRDirectoryExists(tmpPath);
            SRBrowseUsage cacheUsage = cacheExists ? SRScanPath(cachePath) : (SRBrowseUsage){0};
            SRBrowseUsage tmpUsage = tmpExists ? SRScanPath(tmpPath) : (SRBrowseUsage){0};
            uint64_t total = cacheUsage.allocatedBytes + tmpUsage.allocatedBytes;
            if (total == 0) continue;

            SRCacheRecord *record = [[SRCacheRecord alloc] init];
            record.identifier = bundleID;
            record.bundleID = bundleID;
            record.displayName = SRApplicationDisplayName(bundleID);
            record.containerPath = container;
            record.sourcePath = container;
            record.cacheBytes = cacheUsage.allocatedBytes;
            record.temporaryBytes = tmpUsage.allocatedBytes;
            record.itemCount = cacheUsage.files + tmpUsage.files;
            record.cacheDirectoryExists = cacheExists;
            record.temporaryDirectoryExists = tmpExists;
            [records addObject:record];
        }
    }
    closedir(directory);

    [records sortUsingComparator:^NSComparisonResult(SRCacheRecord *left, SRCacheRecord *right) {
        uint64_t leftSize = left.totalBytes;
        uint64_t rightSize = right.totalBytes;
        if (leftSize > rightSize) return NSOrderedAscending;
        if (leftSize < rightSize) return NSOrderedDescending;
        return [left.displayName localizedCaseInsensitiveCompare:right.displayName];
    }];
    return records;
}

- (NSArray<SRCacheRecord *> *)loadDiscardedRecordsRootExists:(BOOL *)rootExists
{
    BOOL exists = SRDirectoryExists(SRDiscardedRoot);
    if (rootExists) *rootExists = exists;
    if (!exists) return @[];

    NSMutableArray<SRCacheRecord *> *records = [NSMutableArray array];
    for (NSString *path in SRTopLevelEntries(SRDiscardedRoot)) {
        @autoreleasepool {
            if (!SRPathWithinRoot(path, SRDiscardedRoot, NO)) continue;
            SRBrowseUsage usage = SRScanPath(path);
            if (usage.allocatedBytes == 0 && usage.files == 0 && usage.dirs == 0) continue;

            NSString *derivedIdentifier = nil;
            NSString *displayName = SRDiscardedDisplayName(path, &derivedIdentifier);
            SRCacheRecord *record = [[SRCacheRecord alloc] init];
            record.identifier = path;
            record.bundleID = derivedIdentifier ?: path.lastPathComponent;
            record.displayName = displayName;
            record.sourcePath = path;
            record.cacheBytes = usage.allocatedBytes;
            record.temporaryBytes = 0;
            record.itemCount = usage.files;
            record.discarded = YES;
            [records addObject:record];
        }
    }

    [records sortUsingComparator:^NSComparisonResult(SRCacheRecord *left, SRCacheRecord *right) {
        if (left.cacheBytes > right.cacheBytes) return NSOrderedAscending;
        if (left.cacheBytes < right.cacheBytes) return NSOrderedDescending;
        return [left.displayName localizedCaseInsensitiveCompare:right.displayName];
    }];
    return records;
}

- (void)scanCurrentMode
{
    if (self.busy || ![self requirePrepared]) return;
    SRBrowserMode mode = self.browserMode;
    self.busy = YES;
    if (mode == SRBrowserModeApps) self.statusText = @"Scanning app cache…";
    else if (mode == SRBrowserModeDiscarded) self.statusText = @"Checking protected cache…";
    else self.statusText = @"Checking Rescue area…";
    [self updateInterface];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<SRCacheRecord *> *apps = nil;
        NSArray<SRCacheRecord *> *discarded = nil;
        BOOL discardedExists = NO;
        SRBrowseUsage staging = {0};

        if (mode == SRBrowserModeApps) {
            apps = [self loadAppRecords];
        } else if (mode == SRBrowserModeDiscarded) {
            discarded = [self loadDiscardedRecordsRootExists:&discardedExists];
        } else {
            staging = SRScanPath(SRTargetPath);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.targetExists = SRDirectoryExists(SRTargetPath);
            if (mode == SRBrowserModeApps && apps) {
                self.appRecords = apps;
                uint64_t total = 0;
                for (SRCacheRecord *record in apps) total += record.totalBytes;
                self.statusText = apps.count
                    ? [NSString stringWithFormat:@"%@ available across %lu apps", SRFormatBytes(total), (unsigned long)apps.count]
                    : @"No app cache found";
            } else if (mode == SRBrowserModeDiscarded && discarded) {
                self.discardedRecords = discarded;
                self.discardedRootExists = discardedExists;
                uint64_t total = 0;
                for (SRCacheRecord *record in discarded) total += record.cacheBytes;
                self.statusText = discardedExists
                    ? (discarded.count ? [NSString stringWithFormat:@"%@ protected cache found", SRFormatBytes(total)] : @"Protected cache is empty")
                    : @"No protected CacheDelete folder on this device";
            } else if (mode == SRBrowserModeStaging) {
                self.stagingUsage = staging;
                self.statusText = staging.files || staging.allocatedBytes
                    ? [NSString stringWithFormat:@"%@ waiting in Rescue", SRFormatBytes(staging.allocatedBytes)]
                    : @"Rescue area is empty";
            }
            [self updateInterface];
        });
    });
}

#pragma mark - Selection and summaries

- (NSArray<SRCacheRecord *> *)recordsForCurrentMode
{
    NSArray<SRCacheRecord *> *records = self.browserMode == SRBrowserModeApps ? self.appRecords : self.discardedRecords;
    NSString *query = self.cacheSearchController.searchBar.text ?: @"";
    if (!query.length) return records;

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(SRCacheRecord *record, NSDictionary *bindings) {
        return [record.displayName rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound ||
               [record.bundleID rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
    }];
    return [records filteredArrayUsingPredicate:predicate];
}

- (NSArray<SRCacheRecord *> *)selectedRecords
{
    NSArray<SRCacheRecord *> *source = self.browserMode == SRBrowserModeApps ? self.appRecords : self.discardedRecords;
    NSMutableArray<SRCacheRecord *> *selected = [NSMutableArray array];
    for (SRCacheRecord *record in source) {
        if ([self.selectedIdentifiers containsObject:record.identifier]) [selected addObject:record];
    }
    return selected;
}

- (uint64_t)selectedBytes
{
    uint64_t total = 0;
    for (SRCacheRecord *record in [self selectedRecords]) total += record.totalBytes;
    return total;
}

- (uint64_t)availableBytesForCurrentMode
{
    uint64_t total = 0;
    NSArray<SRCacheRecord *> *source = self.browserMode == SRBrowserModeApps ? self.appRecords : self.discardedRecords;
    for (SRCacheRecord *record in source) total += record.totalBytes;
    return total;
}

- (BOOL)hasStagedData
{
    return self.stagingUsage.files > 0 || self.stagingUsage.allocatedBytes > 0 || self.stagingUsage.dirs > 1;
}

- (void)updateSelectionMenu
{
    if (self.browserMode == SRBrowserModeStaging) {
        self.navigationItem.leftBarButtonItem = nil;
        return;
    }

    NSArray<SRCacheRecord *> *visible = [self recordsForCurrentMode];
    if (!visible.count || !self.prepared || self.busy) {
        self.navigationItem.leftBarButtonItem = nil;
        return;
    }

    __weak typeof(self) weakSelf = self;
    UIAction *selectAll = [UIAction actionWithTitle:@"Select All Visible"
                                              image:[UIImage systemImageNamed:@"checkmark.circle"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        for (SRCacheRecord *record in [self recordsForCurrentMode]) {
            [self.selectedIdentifiers addObject:record.identifier];
        }
        [self updateInterface];
    }];
    UIAction *clear = [UIAction actionWithTitle:@"Clear Selection"
                                          image:[UIImage systemImageNamed:@"circle"]
                                     identifier:nil
                                        handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        [self.selectedIdentifiers removeAllObjects];
        [self updateInterface];
    }];
    clear.attributes = self.selectedIdentifiers.count ? UIMenuElementAttributesNone : UIMenuElementAttributesDisabled;
    self.selectionItem.menu = [UIMenu menuWithTitle:@"Selection" children:@[selectAll, clear]];
    self.navigationItem.leftBarButtonItem = self.selectionItem;
}

- (void)updateInterface
{
    self.refreshItem.enabled = self.prepared && !self.busy;
    self.infoItem.enabled = !self.busy;
    self.modeControl.enabled = !self.busy;

    if (self.browserMode == SRBrowserModeApps || self.browserMode == SRBrowserModeDiscarded) {
        self.navigationItem.searchController = self.cacheSearchController;
    } else {
        self.navigationItem.searchController = nil;
    }

    [self updateModeHeaderContent];
    [self updateSelectionMenu];
    [self.tableView reloadData];
}

- (void)modeChanged:(UISegmentedControl *)sender
{
    self.browserMode = (SRBrowserMode)sender.selectedSegmentIndex;
    [self.selectedIdentifiers removeAllObjects];
    self.cacheSearchController.searchBar.text = @"";
    [self updateInterface];
    if (self.prepared) [self scanCurrentMode];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self updateSelectionMenu];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - App cache cleaning

- (void)cleanSelectedApps
{
    NSArray<SRCacheRecord *> *selected = [self selectedRecords];
    if (!selected.count) return;
    uint64_t bytes = [self selectedBytes];
    NSString *message = [NSString stringWithFormat:
        @"Clear %@ of temporary cache from %lu selected app%@?\n\nOnly Library/Caches and tmp are touched. Close the selected apps first so they do not immediately recreate files while cleaning.",
        SRFormatBytes(bytes), (unsigned long)selected.count, selected.count == 1 ? @"" : @"s"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Selected Cache?"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear Cache"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self performCleanAppRecords:selected];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performCleanAppRecords:(NSArray<SRCacheRecord *> *)records
{
    if (self.busy) return;
    self.busy = YES;
    self.statusText = @"Clearing selected app cache…";
    [self updateInterface];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SRBrowseDeleteSummary total = {0};
        NSMutableArray<SRCacheRecord *> *failedRecords = [NSMutableArray array];

        for (SRCacheRecord *record in records) {
            if (!SRIsApplicationContainerPath(record.containerPath)) {
                total.failures++;
                [failedRecords addObject:record];
                continue;
            }

            NSUInteger failuresBefore = total.failures;
            for (NSString *relative in @[@"Library/Caches", @"tmp"]) {
                NSString *root = [record.containerPath stringByAppendingPathComponent:relative];
                if (!SRPathWithinRoot(root, record.containerPath, NO)) {
                    total.failures++;
                    continue;
                }
                SRBrowseDeleteSummary result = SRDeleteDirectoryContents(root);
                total.removedAllocatedBytes += result.removedAllocatedBytes;
                total.removedFiles += result.removedFiles;
                total.removedDirs += result.removedDirs;
                total.failures += result.failures;
            }
            if (total.failures > failuresBefore) [failedRecords addObject:record];
        }

        NSArray<SRCacheRecord *> *updated = [self loadAppRecords];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.appRecords = updated;
            [self.selectedIdentifiers removeAllObjects];
            self.statusText = [NSString stringWithFormat:@"%@ cleared", SRFormatBytes(total.removedAllocatedBytes)];
            [self updateInterface];

            if (total.failures > 0 && failedRecords.count > 0) {
                NSString *message = [NSString stringWithFormat:
                    @"Most removable cache was cleared, but %lu filesystem operation%@ were blocked. Storage Rescue can move the remaining cache into Rescue and use the protected cleanup flow there.",
                    (unsigned long)total.failures, total.failures == 1 ? @"" : @"s"];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Some Cache Is Protected"
                                                                               message:message
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Leave It" style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"Move to Rescue"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
                    [self stageAppRecords:failedRecords];
                }]];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                [self showSimpleAlert:@"Cache Cleared"
                              message:[NSString stringWithFormat:@"Estimated storage removed: %@. Apps may recreate cache as you use them again.", SRFormatBytes(total.removedAllocatedBytes)]];
            }
        });
    });
}

- (NSString *)newStagingSessionWithPrefix:(NSString *)prefix
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    NSString *name = [NSString stringWithFormat:@"%@-%@-%@", prefix, stamp, [[NSUUID UUID].UUIDString substringToIndex:8].lowercaseString];
    return [SRTargetPath stringByAppendingPathComponent:name];
}

- (void)stageAppRecords:(NSArray<SRCacheRecord *> *)records
{
    if (self.busy || !records.count) return;
    self.busy = YES;
    self.statusText = @"Moving blocked cache to Rescue…";
    [self updateInterface];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *targetError = nil;
        if (!SREnsureDirectory(SRTargetPath, &targetError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Rescue move failed";
                [self updateInterface];
                [self showSimpleAlert:@"Move Failed" message:targetError.localizedDescription ?: @"The Rescue area could not be prepared."];
            });
            return;
        }

        NSString *session = [self newStagingSessionWithPrefix:@"AppCaches"];
        NSError *sessionError = nil;
        if (!SREnsureDirectory(session, &sessionError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Rescue move failed";
                [self updateInterface];
                [self showSimpleAlert:@"Move Failed" message:sessionError.localizedDescription ?: @"A Rescue session could not be created."];
            });
            return;
        }

        SRMoveSummary total = {0};
        for (SRCacheRecord *record in records) {
            if (!SRIsApplicationContainerPath(record.containerPath)) {
                total.failures++;
                continue;
            }
            NSString *appDestination = [session stringByAppendingPathComponent:record.bundleID ?: record.identifier];
            NSError *error = nil;
            if (!SREnsureDirectory(appDestination, &error)) {
                total.failures++;
                continue;
            }
            NSString *cacheDestination = [appDestination stringByAppendingPathComponent:@"Caches"];
            NSString *tmpDestination = [appDestination stringByAppendingPathComponent:@"tmp"];
            SRMoveSummary cache = SRMoveTopLevelContents([record.containerPath stringByAppendingPathComponent:@"Library/Caches"], cacheDestination);
            SRMoveSummary tmp = SRMoveTopLevelContents([record.containerPath stringByAppendingPathComponent:@"tmp"], tmpDestination);
            total.movedItems += cache.movedItems + tmp.movedItems;
            total.failures += cache.failures + tmp.failures;
        }

        NSArray<SRCacheRecord *> *updated = [self loadAppRecords];
        SRBrowseUsage staging = SRScanPath(SRTargetPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.appRecords = updated;
            self.stagingUsage = staging;
            self.targetExists = SRDirectoryExists(SRTargetPath);
            self.statusText = [NSString stringWithFormat:@"%lu blocked cache item%@ moved to Rescue", (unsigned long)total.movedItems, total.movedItems == 1 ? @"" : @"s"];
            [self updateInterface];
            if (total.movedItems > 0) {
                [self offerOpenRescueWithTitle:@"Ready for Rescue"
                                       message:[NSString stringWithFormat:@"%lu blocked cache item%@ were moved into the Rescue area. This move does not free storage by itself; open Rescue to finish the cleanup.%@",
                                                (unsigned long)total.movedItems, total.movedItems == 1 ? @"" : @"s",
                                                total.failures ? [NSString stringWithFormat:@"\n\n%lu item%@ could not be moved.", (unsigned long)total.failures, total.failures == 1 ? @"" : @"s"] : @""]];
            } else {
                [self showSimpleAlert:@"Nothing Moved" message:@"The remaining cache could not be moved into Rescue."];
            }
        });
    });
}

#pragma mark - Protected Cache staging

- (void)stageSelectedDiscarded
{
    NSArray<SRCacheRecord *> *selected = [self selectedRecords];
    if (!selected.count) return;
    uint64_t bytes = [self selectedBytes];
    NSString *message = [NSString stringWithFormat:
        @"Move %@ of protected cache into Rescue?\n\nThis is a fast filesystem move, not a copy. It does not free storage until the Rescue cleanup finishes.", SRFormatBytes(bytes)];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Move Selected Cache to Rescue?"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Move to Rescue"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self performStageDiscarded:selected];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performStageDiscarded:(NSArray<SRCacheRecord *> *)records
{
    if (self.busy) return;
    self.busy = YES;
    self.statusText = @"Moving protected cache to Rescue…";
    [self updateInterface];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *targetError = nil;
        if (!SREnsureDirectory(SRTargetPath, &targetError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Rescue move failed";
                [self updateInterface];
                [self showSimpleAlert:@"Move Failed" message:targetError.localizedDescription ?: @"The Rescue area could not be prepared."];
            });
            return;
        }

        NSString *session = [self newStagingSessionWithPrefix:@"ProtectedCache"];
        NSError *sessionError = nil;
        if (!SREnsureDirectory(session, &sessionError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Rescue move failed";
                [self updateInterface];
                [self showSimpleAlert:@"Move Failed" message:sessionError.localizedDescription ?: @"A Rescue session could not be created."];
            });
            return;
        }

        NSUInteger moved = 0;
        NSUInteger failed = 0;
        for (SRCacheRecord *record in records) {
            if (SRMoveWholePathToDirectory(record.sourcePath, session)) moved++;
            else failed++;
        }

        BOOL rootExists = NO;
        NSArray<SRCacheRecord *> *updated = [self loadDiscardedRecordsRootExists:&rootExists];
        SRBrowseUsage staging = SRScanPath(SRTargetPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.discardedRecords = updated;
            self.discardedRootExists = rootExists;
            self.stagingUsage = staging;
            self.targetExists = SRDirectoryExists(SRTargetPath);
            [self.selectedIdentifiers removeAllObjects];
            self.statusText = [NSString stringWithFormat:@"%lu protected entr%@ moved to Rescue", (unsigned long)moved, moved == 1 ? @"y" : @"ies"];
            [self updateInterface];
            if (moved > 0) {
                [self offerOpenRescueWithTitle:@"Ready for Rescue"
                                       message:[NSString stringWithFormat:@"%@ is now waiting in the Rescue area. Open Rescue to actually free the storage.%@",
                                                SRFormatBytes(staging.allocatedBytes),
                                                failed ? [NSString stringWithFormat:@"\n\n%lu selected entr%@ could not be moved.", (unsigned long)failed, failed == 1 ? @"y" : @"ies"] : @""]];
            } else {
                [self showSimpleAlert:@"Nothing Moved" message:@"The selected protected cache could not be moved into Rescue."];
            }
        });
    });
}

#pragma mark - Rescue

- (void)openRescue
{
    if (![self requirePrepared]) return;
    StorageRescueRecoveryViewController *rescue = [[StorageRescueRecoveryViewController alloc] init];
    [self.navigationController pushViewController:rescue animated:YES];
}

- (void)offerOpenRescueWithTitle:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open Rescue" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self openRescue];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSimpleAlert:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table helpers

- (UITableViewCell *)accessCell
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    if (self.busy && !self.prepared) {
        cell.textLabel.text = @"Enabling Storage Access…";
        cell.detailTextLabel.text = @"Please wait. No files are being deleted.";
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        cell.imageView.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
        cell.imageView.tintColor = UIColor.systemBlueColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (self.prepared) {
        cell.textLabel.text = @"Storage Access Ready";
        cell.detailTextLabel.text = self.busy ? self.statusText : @"Scanning and cleanup are available for this launch.";
        cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield.fill"];
        cell.imageView.tintColor = UIColor.systemGreenColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Enable Storage Access";
        cell.detailTextLabel.text = @"Required once per launch before Storage Rescue can scan or clean. This step does not delete files.";
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.imageView.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
        cell.imageView.tintColor = UIColor.systemBlueColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (UITableViewCell *)summaryCellForRow:(NSInteger)row
{
    if (self.browserMode == SRBrowserModeStaging) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        if (row == 0) {
            cell.textLabel.text = @"Waiting in Rescue";
            cell.detailTextLabel.text = [self hasStagedData]
                ? [NSString stringWithFormat:@"%@ • %lu files", SRFormatBytes(self.stagingUsage.allocatedBytes), (unsigned long)self.stagingUsage.files]
                : @"Nothing is currently waiting for protected cleanup.";
            cell.imageView.image = [UIImage systemImageNamed:@"externaldrive.fill"];
            cell.imageView.tintColor = [self hasStagedData] ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            BOOL enabled = self.prepared && !self.busy && [self hasStagedData];
            cell.textLabel.text = enabled ? @"Open Rescue" : @"Nothing to Rescue";
            cell.detailTextLabel.text = enabled
                ? @"Verify deletion, then free all staged cache."
                : @"Move protected cache here first, or refresh after staging data.";
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            cell.textLabel.textColor = enabled ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
            cell.imageView.image = [UIImage systemImageNamed:enabled ? @"lifepreserver.fill" : @"checkmark.circle.fill"];
            cell.imageView.tintColor = enabled ? UIColor.systemRedColor : UIColor.systemGreenColor;
            cell.accessoryType = enabled ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
            cell.userInteractionEnabled = enabled;
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (row == 0) {
        uint64_t available = [self availableBytesForCurrentMode];
        cell.textLabel.text = self.browserMode == SRBrowserModeApps ? @"Recoverable Cache" : @"Protected Cache Found";
        cell.detailTextLabel.text = self.prepared ? SRFormatBytes(available) : @"Enable storage access to scan";
        cell.imageView.image = [UIImage systemImageNamed:@"internaldrive.fill"];
        cell.imageView.tintColor = UIColor.systemBlueColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (row == 1) {
        NSUInteger count = [self selectedRecords].count;
        cell.textLabel.text = @"Selected";
        cell.detailTextLabel.text = count
            ? [NSString stringWithFormat:@"%lu item%@ • %@", (unsigned long)count, count == 1 ? @"" : @"s", SRFormatBytes([self selectedBytes])]
            : @"Nothing selected";
        cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle"];
        cell.imageView.tintColor = count ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        BOOL enabled = self.prepared && !self.busy && [self selectedRecords].count > 0;
        if (self.browserMode == SRBrowserModeApps) {
            cell.textLabel.text = enabled ? @"Clear Selected Cache" : @"Select Apps to Clean";
            cell.detailTextLabel.text = @"Deletes only cache and temporary files from the selected apps.";
            cell.imageView.image = [UIImage systemImageNamed:@"trash.fill"];
            cell.textLabel.textColor = enabled ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
            cell.imageView.tintColor = enabled ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
        } else {
            cell.textLabel.text = enabled ? @"Move Selected to Rescue" : @"Select Protected Cache";
            cell.detailTextLabel.text = @"Moves selected leftovers into the protected Rescue area before deletion.";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.to.line.compact"];
            cell.textLabel.textColor = enabled ? UIColor.systemOrangeColor : UIColor.tertiaryLabelColor;
            cell.imageView.tintColor = enabled ? UIColor.systemOrangeColor : UIColor.tertiaryLabelColor;
        }
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.detailTextLabel.numberOfLines = 0;
        cell.userInteractionEnabled = enabled;
        cell.accessoryType = enabled ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    }
    return cell;
}

- (UIView *)accessoryForRecord:(SRCacheRecord *)record selected:(BOOL)selected
{
    UILabel *size = [[UILabel alloc] initWithFrame:CGRectZero];
    size.text = SRFormatBytes(record.totalBytes);
    size.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
    size.textColor = UIColor.secondaryLabelColor;

    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:selected ? @"checkmark.circle.fill" : @"circle"]];
    check.tintColor = selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    [check.widthAnchor constraintEqualToConstant:22.0].active = YES;
    [check.heightAnchor constraintEqualToConstant:22.0].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[size, check]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    return stack;
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return self.browserMode == SRBrowserModeStaging ? 2 : 3;
    if (self.browserMode == SRBrowserModeStaging) return 1;
    return MAX((NSInteger)[self recordsForCurrentMode].count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"Storage Access";
    if (section == 1) return @"Summary";
    if (self.browserMode == SRBrowserModeApps) return @"Applications";
    if (self.browserMode == SRBrowserModeDiscarded) return @"Protected Cache";
    return @"Rescue Area";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 && !self.prepared) {
        return @"Access is explicit by design. Scanning and cleanup never start it automatically.";
    }
    if (section == 2 && self.browserMode == SRBrowserModeApps) {
        return @"Only Library/Caches and tmp inside validated app containers are included. Cache root folders are preserved.";
    }
    if (section == 2 && self.browserMode == SRBrowserModeDiscarded) {
        return self.discardedRootExists
            ? @"These are CacheDelete leftovers managed by iOS. Storage Rescue moves selected entries into Rescue before deleting them."
            : @"This system-managed cache does not exist on every device. Storage Rescue never creates it when iOS has not created it.";
    }
    if (section == 2 && self.browserMode == SRBrowserModeStaging) {
        return @"Items in Rescue still occupy storage until protected cleanup successfully deletes them.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return [self accessCell];
    if (indexPath.section == 1) return [self summaryCellForRow:indexPath.row];

    if (self.browserMode == SRBrowserModeStaging) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        BOOL hasData = [self hasStagedData];
        cell.textLabel.text = hasData ? @"Staged Cache" : @"Rescue Area Is Empty";
        cell.detailTextLabel.text = hasData
            ? [NSString stringWithFormat:@"%@ • %lu files • %lu folders", SRFormatBytes(self.stagingUsage.allocatedBytes), (unsigned long)self.stagingUsage.files, (unsigned long)MAX((NSInteger)self.stagingUsage.dirs - 1, 0)]
            : @"Protected cache moved here will appear in this section.";
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.image = [UIImage systemImageNamed:hasData ? @"archivebox.fill" : @"checkmark.circle.fill"];
        cell.imageView.tintColor = hasData ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
        cell.accessoryType = hasData ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.userInteractionEnabled = hasData;
        return cell;
    }

    NSArray<SRCacheRecord *> *records = [self recordsForCurrentMode];
    if (records.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = self.busy
            ? @"Scanning…"
            : (self.browserMode == SRBrowserModeDiscarded && self.prepared && !self.discardedRootExists
               ? @"No Protected Cache Found"
               : @"Nothing to Clean");
        cell.detailTextLabel.text = self.busy
            ? @"Storage Rescue is measuring removable cache."
            : (self.prepared ? @"Refresh to scan again." : @"Enable Storage Access to begin.");
        cell.detailTextLabel.numberOfLines = 0;
        cell.imageView.image = [UIImage systemImageNamed:self.busy ? @"magnifyingglass" : @"checkmark.circle.fill"];
        cell.imageView.tintColor = self.busy ? UIColor.systemBlueColor : UIColor.systemGreenColor;
        return cell;
    }

    SRCacheRecord *record = records[indexPath.row];
    BOOL selected = [self.selectedIdentifiers containsObject:record.identifier];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = record.displayName;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    if (self.browserMode == SRBrowserModeApps) {
        NSString *cache = record.cacheDirectoryExists ? SRFormatBytes(record.cacheBytes) : @"—";
        NSString *temporary = record.temporaryDirectoryExists ? SRFormatBytes(record.temporaryBytes) : @"—";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nCache %@ • Temp %@", record.bundleID, cache, temporary];
        cell.imageView.image = [UIImage systemImageNamed:@"app.fill"];
        cell.imageView.tintColor = UIColor.systemBlueColor;
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%lu files waiting for Rescue", record.bundleID, (unsigned long)record.itemCount];
        cell.imageView.image = [UIImage systemImageNamed:@"archivebox.fill"];
        cell.imageView.tintColor = UIColor.systemOrangeColor;
    }
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = [self accessoryForRecord:record selected:selected];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;

    if (indexPath.section == 0) {
        if (!self.prepared) [self prepareAccess];
        return;
    }

    if (indexPath.section == 1) {
        if (self.browserMode == SRBrowserModeStaging) {
            if (indexPath.row == 1 && [self hasStagedData]) [self openRescue];
        } else if (indexPath.row == 2) {
            if (self.browserMode == SRBrowserModeApps) [self cleanSelectedApps];
            else [self stageSelectedDiscarded];
        }
        return;
    }

    if (self.browserMode == SRBrowserModeStaging) {
        if ([self hasStagedData]) [self openRescue];
        return;
    }

    NSArray<SRCacheRecord *> *records = [self recordsForCurrentMode];
    if (indexPath.row >= records.count) return;
    SRCacheRecord *record = records[indexPath.row];
    if ([self.selectedIdentifiers containsObject:record.identifier]) {
        [self.selectedIdentifiers removeObject:record.identifier];
    } else {
        [self.selectedIdentifiers addObject:record.identifier];
    }
    [self updateInterface];
}

@end
