#import "StorageRescueDedicatedViewController.h"
#import "StorageRescueSolverViewController.h"

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
    NSString *last = safe.lastPathComponent;
    return [[NSUUID alloc] initWithUUIDString:last] != nil;
}

static BOOL SREnsureDirectory(NSString *path, NSError **error)
{
    NSString *safe = SRStandardPath(path);
    if (!safe.length || ![safe hasPrefix:@"/var/mobile/Documents/test"]) {
        if (error) {
            *error = [NSError errorWithDomain:@"StorageRescue"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unsafe staging path"}];
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
    return path.lastPathComponent.length ? path.lastPathComponent : @"Discarded cache";
}

@interface StorageRescueDedicatedViewController ()
@property (nonatomic, assign) SRBrowserMode browserMode;
@property (nonatomic, assign) BOOL prepared;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL targetExists;
@property (nonatomic, assign) BOOL discardedRootExists;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, strong) NSArray<SRCacheRecord *> *appRecords;
@property (nonatomic, strong) NSArray<SRCacheRecord *> *discardedRecords;
@property (nonatomic, assign) SRBrowseUsage stagingUsage;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIdentifiers;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UISearchController *cacheSearchController;
@property (nonatomic, strong) UIBarButtonItem *primaryItem;
@property (nonatomic, strong) UIBarButtonItem *refreshItem;
@property (nonatomic, strong) UILabel *introLabel;
@end

@implementation StorageRescueDedicatedViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _browserMode = SRBrowserModeApps;
        _statusText = @"Run Prepare Access first";
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
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 62.0;

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Apps", @"Discarded", @"Staging"]];
    self.modeControl.selectedSegmentIndex = SRBrowserModeApps;
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.modeControl;

    self.cacheSearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.cacheSearchController.obscuresBackgroundDuringPresentation = NO;
    self.cacheSearchController.searchResultsUpdater = self;
    self.cacheSearchController.searchBar.placeholder = @"Search app or bundle ID";
    self.definesPresentationContext = YES;

    self.primaryItem = [[UIBarButtonItem alloc] initWithTitle:@"Clean"
                                                        style:UIBarButtonItemStylePlain
                                                       target:self
                                                       action:@selector(primaryAction)];
    self.refreshItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                     target:self
                                                                     action:@selector(scanCurrentMode)];
    self.navigationItem.rightBarButtonItems = @[self.primaryItem, self.refreshItem];

    [self buildIntroHeader];
    [self updateChrome];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (!self.introLabel) return;
    CGFloat width = self.tableView.bounds.size.width;
    CGFloat horizontal = 20.0;
    CGFloat contentWidth = MAX(0.0, width - horizontal * 2.0);
    CGSize size = [self.introLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    self.introLabel.frame = CGRectMake(horizontal, 14.0, contentWidth, size.height);
    UIView *header = self.introLabel.superview;
    CGRect frame = header.frame;
    CGFloat height = size.height + 28.0;
    if (fabs(frame.size.height - height) > 0.5 || fabs(frame.size.width - width) > 0.5) {
        header.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableHeaderView = header;
    }
}

- (void)buildIntroHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 150)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;
    label.text = @"Recommended workflow: remove normal per-app cache in place. Storage Rescue only touches each app's Library/Caches and tmp. Protected CacheDelete/discarded data is staged with rename() into /var/mobile/Documents/test and then removed by the Solver. Moving data alone does not free storage. The staging folder is created automatically after Prepare Access if it is missing.";
    [header addSubview:label];
    self.introLabel = label;
    self.tableView.tableHeaderView = header;
}

#pragma mark - Access

- (BOOL)prepareAccessSync:(NSString **)errorText
{
    if (!kexploit_krw_ready()) {
        int result = kexploit_opa334();
        if (result != 0 || !kexploit_krw_ready()) {
            if (errorText) *errorText = [NSString stringWithFormat:@"DarkSword KRW failed (%d)", result];
            return NO;
        }
    }

    if (check_sandbox_var_rw() != 0) {
        int result = escape_sbx_demo2();
        if (result != 0 || check_sandbox_var_rw() != 0) {
            if (errorText) *errorText = [NSString stringWithFormat:@"Root R/W extension failed (%d)", result];
            return NO;
        }
    }

    NSError *folderError = nil;
    if (!SREnsureDirectory(SRTargetPath, &folderError)) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Could not create %@: %@", SRTargetPath, folderError.localizedDescription ?: @"unknown error"];
        return NO;
    }

    DIR *appRoot = opendir(SRAppDataRoot.fileSystemRepresentation);
    if (!appRoot) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Cannot enumerate app containers: errno=%d (%s)", errno, strerror(errno)];
        return NO;
    }
    closedir(appRoot);
    return YES;
}

- (void)prepareAccess
{
    if (self.busy) return;
    self.busy = YES;
    self.statusText = @"Preparing access…";
    [self updateChrome];
    [self.tableView reloadData];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *errorText = nil;
        BOOL ok = [self prepareAccessSync:&errorText];
        BOOL targetExists = SRDirectoryExists(SRTargetPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.prepared = ok;
            self.targetExists = targetExists;
            self.statusText = ok ? @"Prepared" : (errorText ?: @"Prepare failed");
            [self updateChrome];
            [self.tableView reloadData];
            if (ok) [self scanCurrentMode];
            else [self showSimpleAlert:@"Prepare Access Failed" message:self.statusText];
        });
    });
}

- (BOOL)requirePrepared
{
    if (self.prepared) return YES;
    [self showSimpleAlert:@"Prepare Access First" message:@"Scanning and filesystem changes never start DarkSword automatically. Run Prepare Access first."];
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
        uint64_t leftSize = left.cacheBytes + left.temporaryBytes;
        uint64_t rightSize = right.cacheBytes + right.temporaryBytes;
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
    self.statusText = @"Scanning…";
    [self updateChrome];
    [self.tableView reloadData];

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
                for (SRCacheRecord *record in apps) total += record.cacheBytes + record.temporaryBytes;
                self.statusText = [NSString stringWithFormat:@"%lu apps • %@", (unsigned long)apps.count, SRFormatBytes(total)];
            } else if (mode == SRBrowserModeDiscarded && discarded) {
                self.discardedRecords = discarded;
                self.discardedRootExists = discardedExists;
                uint64_t total = 0;
                for (SRCacheRecord *record in discarded) total += record.cacheBytes;
                self.statusText = discardedExists
                    ? [NSString stringWithFormat:@"%lu discarded entries • %@", (unsigned long)discarded.count, SRFormatBytes(total)]
                    : @"discardedCaches is not present on this device";
            } else if (mode == SRBrowserModeStaging) {
                self.stagingUsage = staging;
                self.statusText = [NSString stringWithFormat:@"Staging • %@ • %lu files", SRFormatBytes(staging.allocatedBytes), (unsigned long)staging.files];
            }
            [self updateChrome];
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Filtering and UI state

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
    for (SRCacheRecord *record in [self selectedRecords]) total += record.cacheBytes + record.temporaryBytes;
    return total;
}

- (void)updateChrome
{
    NSString *title = @"Clean";
    BOOL enabled = !self.busy;
    if (self.browserMode == SRBrowserModeApps) {
        title = @"Clean";
        enabled = enabled && self.prepared && self.selectedIdentifiers.count > 0;
        self.navigationItem.searchController = self.cacheSearchController;
    } else if (self.browserMode == SRBrowserModeDiscarded) {
        title = @"Stage";
        enabled = enabled && self.prepared && self.selectedIdentifiers.count > 0;
        self.navigationItem.searchController = self.cacheSearchController;
    } else {
        title = @"Solver";
        enabled = enabled && self.prepared;
        self.navigationItem.searchController = nil;
    }
    self.primaryItem.title = title;
    self.primaryItem.enabled = enabled;
    self.refreshItem.enabled = self.prepared && !self.busy;
    self.modeControl.enabled = !self.busy;
}

- (void)modeChanged:(UISegmentedControl *)sender
{
    self.browserMode = (SRBrowserMode)sender.selectedSegmentIndex;
    [self.selectedIdentifiers removeAllObjects];
    self.cacheSearchController.searchBar.text = @"";
    [self updateChrome];
    [self.tableView reloadData];
    if (self.prepared) [self scanCurrentMode];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Cleaning normal app caches

- (void)cleanSelectedApps
{
    NSArray<SRCacheRecord *> *selected = [self selectedRecords];
    if (!selected.count) return;
    uint64_t bytes = [self selectedBytes];
    NSString *message = [NSString stringWithFormat:@"Remove only Library/Caches and tmp contents for %lu selected apps (%@)? Close those apps first. Their cache directories remain in place and may be recreated by iOS/apps.", (unsigned long)selected.count, SRFormatBytes(bytes)];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clean Selected App Caches"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clean In Place"
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
    self.statusText = @"Cleaning app caches…";
    [self updateChrome];
    [self.tableView reloadData];

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
            self.statusText = [NSString stringWithFormat:@"Removed %lu items • %@ estimated", (unsigned long)(total.removedFiles + total.removedDirs), SRFormatBytes(total.removedAllocatedBytes)];
            [self updateChrome];
            [self.tableView reloadData];

            if (total.failures > 0 && failedRecords.count > 0) {
                NSString *message = [NSString stringWithFormat:@"%lu filesystem operations were denied. Storage Rescue can stage the remaining top-level cache entries into %@ with rename(), then the proven Solver can remove them there.", (unsigned long)total.failures, SRTargetPath];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Some Cache Was Protected"
                                                                               message:message
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"Stage Remaining"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
                    [self stageAppRecords:failedRecords];
                }]];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                [self showSimpleAlert:@"Cleanup Complete"
                              message:[NSString stringWithFormat:@"Removed %lu files/directories. Estimated allocated space removed: %@.", (unsigned long)(total.removedFiles + total.removedDirs), SRFormatBytes(total.removedAllocatedBytes)]];
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
    self.statusText = @"Staging protected app cache…";
    [self updateChrome];
    [self.tableView reloadData];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *targetError = nil;
        if (!SREnsureDirectory(SRTargetPath, &targetError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Staging failed";
                [self updateChrome];
                [self.tableView reloadData];
                [self showSimpleAlert:@"Staging Failed" message:targetError.localizedDescription ?: @"Could not create test folder"];
            });
            return;
        }

        NSString *session = [self newStagingSessionWithPrefix:@"AppCaches"];
        NSError *sessionError = nil;
        if (!SREnsureDirectory(session, &sessionError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Staging failed";
                [self updateChrome];
                [self.tableView reloadData];
                [self showSimpleAlert:@"Staging Failed" message:sessionError.localizedDescription ?: @"Could not create staging session"];
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
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.appRecords = updated;
            self.targetExists = SRDirectoryExists(SRTargetPath);
            self.statusText = [NSString stringWithFormat:@"Staged %lu items • %lu failures", (unsigned long)total.movedItems, (unsigned long)total.failures];
            [self updateChrome];
            [self.tableView reloadData];
            if (total.movedItems > 0) {
                [self offerOpenSolverWithTitle:@"Cache Staged"
                                       message:[NSString stringWithFormat:@"Moved %lu top-level cache entries into %@. This move does not free storage; run the Solver to actually unlink the staged data.%@", (unsigned long)total.movedItems, SRTargetPath, total.failures ? [NSString stringWithFormat:@"\n\n%lu entries could not be moved.", (unsigned long)total.failures] : @""]];
            } else {
                [self showSimpleAlert:@"Nothing Was Staged" message:[NSString stringWithFormat:@"No remaining cache entry could be moved. Failures: %lu.", (unsigned long)total.failures]];
            }
        });
    });
}

#pragma mark - Discarded CacheDelete staging

- (void)stageSelectedDiscarded
{
    NSArray<SRCacheRecord *> *selected = [self selectedRecords];
    if (!selected.count) return;
    uint64_t bytes = [self selectedBytes];
    NSString *message = [NSString stringWithFormat:@"Stage %lu selected discarded-cache entries (%@) into %@? rename() on the same /var filesystem is used; it does not duplicate the data and does not free space until the Solver deletes it.", (unsigned long)selected.count, SRFormatBytes(bytes), SRTargetPath];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stage Discarded Cache"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Stage"
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
    self.statusText = @"Staging discarded cache…";
    [self updateChrome];
    [self.tableView reloadData];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *targetError = nil;
        if (!SREnsureDirectory(SRTargetPath, &targetError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Staging failed";
                [self updateChrome];
                [self.tableView reloadData];
                [self showSimpleAlert:@"Staging Failed" message:targetError.localizedDescription ?: @"Could not create test folder"];
            });
            return;
        }

        NSString *session = [self newStagingSessionWithPrefix:@"DiscardedCaches"];
        NSError *sessionError = nil;
        if (!SREnsureDirectory(session, &sessionError)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.statusText = @"Staging failed";
                [self updateChrome];
                [self.tableView reloadData];
                [self showSimpleAlert:@"Staging Failed" message:sessionError.localizedDescription ?: @"Could not create staging session"];
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
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.discardedRecords = updated;
            self.discardedRootExists = rootExists;
            self.targetExists = SRDirectoryExists(SRTargetPath);
            [self.selectedIdentifiers removeAllObjects];
            self.statusText = [NSString stringWithFormat:@"Staged %lu discarded entries • %lu failures", (unsigned long)moved, (unsigned long)failed];
            [self updateChrome];
            [self.tableView reloadData];
            if (moved > 0) {
                [self offerOpenSolverWithTitle:@"Discarded Cache Staged"
                                       message:[NSString stringWithFormat:@"Moved %lu entries into %@. Run the Solver now to actually free the space.%@", (unsigned long)moved, SRTargetPath, failed ? [NSString stringWithFormat:@"\n\n%lu entries could not be moved.", (unsigned long)failed] : @""]];
            } else {
                [self showSimpleAlert:@"Nothing Was Staged" message:[NSString stringWithFormat:@"All %lu selected entries failed to move.", (unsigned long)failed]];
            }
        });
    });
}

#pragma mark - Solver and alerts

- (void)openSolver
{
    if (![self requirePrepared]) return;
    StorageRescueSolverViewController *solver = [[StorageRescueSolverViewController alloc] init];
    [self.navigationController pushViewController:solver animated:YES];
}

- (void)offerOpenSolverWithTitle:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open Solver" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self openSolver];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSimpleAlert:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)primaryAction
{
    if (self.browserMode == SRBrowserModeApps) [self cleanSelectedApps];
    else if (self.browserMode == SRBrowserModeDiscarded) [self stageSelectedDiscarded];
    else [self openSolver];
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 4;
    if (self.browserMode == SRBrowserModeStaging) return 1;
    NSArray *records = [self recordsForCurrentMode];
    return MAX((NSInteger)records.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"Access & Safety";
    if (self.browserMode == SRBrowserModeApps) return @"Apps with cache";
    if (self.browserMode == SRBrowserModeDiscarded) return @"CacheDelete discarded entries";
    return @"Staging target";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) {
        return [NSString stringWithFormat:@"Hard staging target: %@. It is created automatically by Prepare Access if missing.", SRTargetPath];
    }
    if (self.browserMode == SRBrowserModeApps) {
        return @"Only each validated app container's Library/Caches and tmp contents are eligible. The cache root directories themselves are preserved.";
    }
    if (self.browserMode == SRBrowserModeDiscarded) {
        return [NSString stringWithFormat:@"Optional system-managed source: %@. If iOS has not created it, Storage Rescue reports it as absent and does not fabricate that system directory.", SRDiscardedRoot];
    }
    return @"Staged bytes still occupy storage until the Solver verifies a real unlink and deletes the staged tree.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Prepare Access";
            cell.detailTextLabel.text = self.statusText;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Target Folder";
            cell.detailTextLabel.text = self.targetExists ? @"Ready" : @"Missing";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = self.browserMode == SRBrowserModeApps ? @"Scan App Caches" : (self.browserMode == SRBrowserModeDiscarded ? @"Scan Discarded Caches" : @"Scan Staging Folder");
            cell.detailTextLabel.text = self.busy ? @"Working…" : @"Refresh";
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"Open Solver";
            cell.detailTextLabel.text = @"Verified unlink";
        }
        return cell;
    }

    if (self.browserMode == SRBrowserModeStaging) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = SRTargetPath;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ allocated • %lu files • %lu dirs", SRFormatBytes(self.stagingUsage.allocatedBytes), (unsigned long)self.stagingUsage.files, (unsigned long)self.stagingUsage.dirs];
        cell.detailTextLabel.numberOfLines = 2;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    NSArray<SRCacheRecord *> *records = [self recordsForCurrentMode];
    if (records.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = self.busy ? @"Scanning…" : (self.browserMode == SRBrowserModeDiscarded && !self.discardedRootExists ? @"discardedCaches not present" : @"No cache found");
        cell.detailTextLabel.text = self.busy ? @"Please wait" : (self.prepared ? @"Use Refresh to scan again" : @"Run Prepare Access first");
        return cell;
    }

    SRCacheRecord *record = records[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = record.displayName;
    if (self.browserMode == SRBrowserModeApps) {
        NSString *cache = record.cacheDirectoryExists ? SRFormatBytes(record.cacheBytes) : @"not present";
        NSString *tmp = record.temporaryDirectoryExists ? SRFormatBytes(record.temporaryBytes) : @"not present";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nCaches %@ • tmp %@ • %lu files", record.bundleID, cache, tmp, (unsigned long)record.itemCount];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@ • %lu files", record.bundleID, SRFormatBytes(record.cacheBytes), (unsigned long)record.itemCount];
    }
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = [self.selectedIdentifiers containsObject:record.identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self prepareAccess];
        else if (indexPath.row == 1) {
            if (!self.prepared) [self prepareAccess];
            else {
                NSError *error = nil;
                BOOL ok = SREnsureDirectory(SRTargetPath, &error);
                self.targetExists = ok;
                [self.tableView reloadData];
                if (!ok) [self showSimpleAlert:@"Target Folder" message:error.localizedDescription ?: @"Could not create target folder"];
            }
        } else if (indexPath.row == 2) [self scanCurrentMode];
        else [self openSolver];
        return;
    }

    if (self.browserMode == SRBrowserModeStaging) {
        [self openSolver];
        return;
    }

    NSArray<SRCacheRecord *> *records = [self recordsForCurrentMode];
    if (indexPath.row >= records.count) return;
    SRCacheRecord *record = records[indexPath.row];
    if ([self.selectedIdentifiers containsObject:record.identifier]) [self.selectedIdentifiers removeObject:record.identifier];
    else [self.selectedIdentifiers addObject:record.identifier];
    [self updateChrome];
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
