#import "StorageCleanerViewController.h"
#import "StorageRescueGuideViewController.h"

#import <dirent.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/stat.h>

@interface StorageRescueDedicatedViewController (StorageCleanerPrivate)
- (void)prepareAccess;
- (void)cleanSelectedApps;
- (void)stageSelectedDiscarded;
- (void)openSolver;
@end

static NSString * const SCAppDataRoot = @"/var/mobile/Containers/Data/Application";
static NSString * const SCSystemCacheRoot = @"/var/mobile/Library/Caches/com.apple.cache_delete/com.apple.CacheDeleteAppContainerCaches.discardedCaches";

typedef NS_ENUM(NSInteger, SCSortMode) {
    SCSortModeSizeDescending = 0,
    SCSortModeSizeAscending,
    SCSortModeNameAscending,
    SCSortModeNameDescending,
};

typedef struct {
    uint64_t allocatedBytes;
    NSUInteger files;
    NSUInteger dirs;
} SCUsage;

static NSString *SCNameFromDirent(const struct dirent *entry)
{
    if (!entry || !entry->d_name[0]) return nil;
    return [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:entry->d_name
            length:strlen(entry->d_name)];
}

static NSString *SCStandardPath(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) return @"";
    return [path stringByStandardizingPath];
}

static BOOL SCPathWithinRoot(NSString *path, NSString *root, BOOL allowRoot)
{
    NSString *safePath = SCStandardPath(path);
    NSString *safeRoot = SCStandardPath(root);
    if (!safePath.length || !safeRoot.length) return NO;
    if (allowRoot && [safePath isEqualToString:safeRoot]) return YES;
    return [safePath hasPrefix:[safeRoot stringByAppendingString:@"/"]];
}

static BOOL SCDirectoryExists(NSString *path)
{
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode);
}

static BOOL SCIsAppContainer(NSString *path)
{
    NSString *safe = SCStandardPath(path);
    if (!SCPathWithinRoot(safe, SCAppDataRoot, NO)) return NO;
    return [[NSUUID alloc] initWithUUIDString:safe.lastPathComponent] != nil;
}

static NSArray<NSString *> *SCTopLevelEntries(NSString *root)
{
    NSString *safeRoot = SCStandardPath(root);
    DIR *directory = opendir(safeRoot.fileSystemRepresentation);
    if (!directory) return @[];

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = SCNameFromDirent(entry);
        if (!name.length) continue;
        NSString *child = [safeRoot stringByAppendingPathComponent:name];
        if (SCPathWithinRoot(child, safeRoot, NO)) [entries addObject:child];
    }
    closedir(directory);
    return entries;
}

static SCUsage SCScanPath(NSString *root)
{
    SCUsage usage = {0};
    NSString *safeRoot = SCStandardPath(root);
    struct stat rootStat;
    if (lstat(safeRoot.fileSystemRepresentation, &rootStat) != 0) return usage;

    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:safeRoot];
    while (stack.count) {
        @autoreleasepool {
            NSString *path = stack.lastObject;
            [stack removeLastObject];
            if (!SCPathWithinRoot(path, safeRoot, YES)) continue;

            struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) != 0) continue;

            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                usage.files++;
                usage.allocatedBytes += (uint64_t)st.st_blocks * 512ULL;
                continue;
            }

            usage.dirs++;
            DIR *directory = opendir(path.fileSystemRepresentation);
            if (!directory) continue;

            struct dirent *entry;
            while ((entry = readdir(directory))) {
                if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                NSString *name = SCNameFromDirent(entry);
                if (!name.length) continue;
                NSString *child = [path stringByAppendingPathComponent:name];
                if (SCPathWithinRoot(child, safeRoot, NO)) [stack addObject:child];
            }
            closedir(directory);
        }
    }
    return usage;
}

static NSString *SCBundleIdentifierForContainer(NSString *containerPath)
{
    NSString *metadataPath = [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;

    NSArray<NSString *> *keys = @[@"MCMMetadataIdentifier", @"Identifier", @"CFBundleIdentifier"];
    for (NSString *key in keys) {
        id value = metadata[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }

    NSDictionary *info = [metadata[@"MCMMetadataInfo"] isKindOfClass:NSDictionary.class] ? metadata[@"MCMMetadataInfo"] : nil;
    for (NSString *key in keys) {
        id value = info[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *SCApplicationDisplayName(NSString *bundleID)
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

    NSString *fallback = bundleID.pathExtension;
    return fallback.length ? fallback : bundleID;
}

static id SCNewRecord(void)
{
    Class recordClass = NSClassFromString(@"SRCacheRecord");
    return recordClass ? [[recordClass alloc] init] : nil;
}

static id SCBuildAppRecord(NSString *containerPath, NSString *ownBundleID)
{
    if (!SCIsAppContainer(containerPath)) return nil;

    NSString *bundleID = SCBundleIdentifierForContainer(containerPath);
    if (!bundleID.length || [bundleID isEqualToString:ownBundleID]) return nil;

    NSString *cachePath = [containerPath stringByAppendingPathComponent:@"Library/Caches"];
    NSString *tmpPath = [containerPath stringByAppendingPathComponent:@"tmp"];
    BOOL cacheExists = SCDirectoryExists(cachePath);
    BOOL tmpExists = SCDirectoryExists(tmpPath);

    SCUsage cacheUsage = cacheExists ? SCScanPath(cachePath) : (SCUsage){0};
    SCUsage tmpUsage = tmpExists ? SCScanPath(tmpPath) : (SCUsage){0};
    uint64_t total = cacheUsage.allocatedBytes + tmpUsage.allocatedBytes;
    if (total == 0) return nil;

    id record = SCNewRecord();
    if (!record) return nil;

    [record setValue:bundleID forKey:@"identifier"];
    [record setValue:bundleID forKey:@"bundleID"];
    [record setValue:SCApplicationDisplayName(bundleID) forKey:@"displayName"];
    [record setValue:containerPath forKey:@"containerPath"];
    [record setValue:containerPath forKey:@"sourcePath"];
    [record setValue:@(cacheUsage.allocatedBytes) forKey:@"cacheBytes"];
    [record setValue:@(tmpUsage.allocatedBytes) forKey:@"temporaryBytes"];
    [record setValue:@(cacheUsage.files + tmpUsage.files) forKey:@"itemCount"];
    [record setValue:@(cacheExists) forKey:@"cacheDirectoryExists"];
    [record setValue:@(tmpExists) forKey:@"temporaryDirectoryExists"];
    [record setValue:@NO forKey:@"discarded"];
    return record;
}

static id SCBuildSystemRecord(NSString *path)
{
    if (!SCPathWithinRoot(path, SCSystemCacheRoot, NO)) return nil;

    SCUsage usage = SCScanPath(path);
    if (usage.allocatedBytes == 0 && usage.files == 0 && usage.dirs == 0) return nil;

    NSString *bundleID = SCBundleIdentifierForContainer(path);
    NSString *identifier = bundleID.length ? bundleID : path.lastPathComponent;
    NSString *displayName = bundleID.length ? SCApplicationDisplayName(bundleID) : @"System Cache Item";

    id record = SCNewRecord();
    if (!record) return nil;

    [record setValue:path forKey:@"identifier"];
    [record setValue:identifier ?: path.lastPathComponent forKey:@"bundleID"];
    [record setValue:displayName forKey:@"displayName"];
    [record setValue:path forKey:@"sourcePath"];
    [record setValue:@(usage.allocatedBytes) forKey:@"cacheBytes"];
    [record setValue:@0 forKey:@"temporaryBytes"];
    [record setValue:@(usage.files) forKey:@"itemCount"];
    [record setValue:@YES forKey:@"discarded"];
    return record;
}

static uint64_t SCRecordBytes(id record)
{
    return [[record valueForKey:@"cacheBytes"] unsignedLongLongValue] +
           [[record valueForKey:@"temporaryBytes"] unsignedLongLongValue];
}

static NSString *SCFormatBytes(uint64_t bytes)
{
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseKB |
                             NSByteCountFormatterUseMB |
                             NSByteCountFormatterUseGB |
                             NSByteCountFormatterUseTB;
    return [formatter stringFromByteCount:(long long)bytes];
}

@interface StorageCleanerViewController ()
@property (nonatomic, strong) UISegmentedControl *areaControl;
@property (nonatomic, strong) UISearchController *cleanerSearchController;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIBarButtonItem *selectionItem;
@property (nonatomic, strong) UIBarButtonItem *cleanItem;
@property (nonatomic, strong) UIButton *sortButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, assign) BOOL scScanning;
@property (nonatomic, assign) BOOL scDidStartAutomatically;
@property (nonatomic, assign) NSUInteger scScanGeneration;
@property (nonatomic, assign) NSUInteger scScannedCandidates;
@property (nonatomic, assign) NSUInteger scTotalCandidates;
@property (nonatomic, assign) SCSortMode scSortMode;
@end

@implementation StorageCleanerViewController

- (instancetype)init
{
    if ((self = [super init])) {
        _scSortMode = SCSortModeSizeDescending;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Storage Cleaner";
    self.navigationItem.titleView = nil;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;

    self.areaControl = [[UISegmentedControl alloc] initWithItems:@[@"Apps", @"System Cache"]];
    self.areaControl.selectedSegmentIndex = 0;
    [self.areaControl addTarget:self action:@selector(scAreaChanged:) forControlEvents:UIControlEventValueChanged];
    [self setValue:@0 forKey:@"browserMode"];

    self.cleanerSearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.cleanerSearchController.obscuresBackgroundDuringPresentation = NO;
    self.cleanerSearchController.searchResultsUpdater = self;
    self.cleanerSearchController.searchBar.placeholder = @"Search apps";
    self.navigationItem.searchController = self.cleanerSearchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.sortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sortButton setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] forState:UIControlStateNormal];
    self.sortButton.showsMenuAsPrimaryAction = YES;
    self.sortButton.accessibilityLabel = @"Sort";

    self.moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.moreButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    self.moreButton.showsMenuAsPrimaryAction = YES;
    self.moreButton.accessibilityLabel = @"More";

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.moreButton],
        [[UIBarButtonItem alloc] initWithCustomView:self.sortButton],
    ];

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(scRefreshPulled:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    self.selectionItem = [[UIBarButtonItem alloc] initWithTitle:@"0 selected"
                                                          style:UIBarButtonItemStylePlain
                                                         target:nil
                                                         action:nil];
    self.cleanItem = [[UIBarButtonItem alloc] initWithTitle:@"Clean Selected"
                                                      style:UIBarButtonItemStyleDone
                                                     target:self
                                                     action:@selector(scCleanTapped)];
    self.cleanItem.tintColor = UIColor.systemRedColor;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil
                                                                          action:nil];
    self.toolbarItems = @[self.selectionItem, flex, self.cleanItem];

    [self scBuildHeader];
    [self updateChrome];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.scDidStartAutomatically) return;
    self.scDidStartAutomatically = YES;

    // Start on the next run loop so the interface is visible before the existing
    // Cyanide/DarkSword access path begins. No backend implementation is changed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self scPrepared]) {
            [self scanCurrentMode];
        } else if (![self scBusy]) {
            [self prepareAccess];
        }
    });
}

- (void)scBuildHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 112.0)];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    [header addSubview:stack];

    [stack addArrangedSubview:self.areaControl];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 1;
    [stack addArrangedSubview:self.statusLabel];

    self.summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.summaryLabel.textColor = UIColor.tertiaryLabelColor;
    self.summaryLabel.numberOfLines = 1;
    [stack addArrangedSubview:self.summaryLabel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20.0],
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:10.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:header.bottomAnchor constant:-10.0],
    ]];

    self.tableView.tableHeaderView = header;
}

#pragma mark - Backend state bridge

- (BOOL)scPrepared
{
    return [[self valueForKey:@"prepared"] boolValue];
}

- (BOOL)scBusy
{
    return [[self valueForKey:@"busy"] boolValue];
}

- (NSMutableSet<NSString *> *)scSelection
{
    id value = [self valueForKey:@"selectedIdentifiers"];
    return [value isKindOfClass:NSMutableSet.class] ? value : nil;
}

- (NSArray *)scSourceRecords
{
    NSString *key = self.areaControl.selectedSegmentIndex == 0 ? @"appRecords" : @"discardedRecords";
    id value = [self valueForKey:key];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

- (void)scSetStatus:(NSString *)status
{
    [self setValue:(status ?: @"") forKey:@"statusText"];
}

- (NSString *)scBackendStatus
{
    id value = [self valueForKey:@"statusText"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

#pragma mark - Sorting / filtering

- (NSArray *)scSortedRecords:(NSArray *)records
{
    SCSortMode mode = self.scSortMode;
    return [records sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        NSString *leftName = [left valueForKey:@"displayName"] ?: @"";
        NSString *rightName = [right valueForKey:@"displayName"] ?: @"";
        uint64_t leftBytes = SCRecordBytes(left);
        uint64_t rightBytes = SCRecordBytes(right);

        if (mode == SCSortModeNameAscending || mode == SCSortModeNameDescending) {
            NSComparisonResult result = [leftName localizedCaseInsensitiveCompare:rightName];
            if (mode == SCSortModeNameAscending) return result;
            if (result == NSOrderedAscending) return NSOrderedDescending;
            if (result == NSOrderedDescending) return NSOrderedAscending;
            return NSOrderedSame;
        }

        if (leftBytes == rightBytes) return [leftName localizedCaseInsensitiveCompare:rightName];
        if (mode == SCSortModeSizeDescending) return leftBytes > rightBytes ? NSOrderedAscending : NSOrderedDescending;
        return leftBytes < rightBytes ? NSOrderedAscending : NSOrderedDescending;
    }];
}

- (NSArray *)scVisibleRecords
{
    NSArray *records = [self scSortedRecords:[self scSourceRecords]];
    NSString *query = self.cleanerSearchController.searchBar.text ?: @"";
    if (!query.length) return records;

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id record, NSDictionary *bindings) {
        NSString *name = [record valueForKey:@"displayName"] ?: @"";
        NSString *bundleID = [record valueForKey:@"bundleID"] ?: @"";
        return [name rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound ||
               [bundleID rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
    }];
    return [records filteredArrayUsingPredicate:predicate];
}

- (uint64_t)scBytesForRecords:(NSArray *)records
{
    uint64_t total = 0;
    for (id record in records) total += SCRecordBytes(record);
    return total;
}

- (uint64_t)scSelectedBytes
{
    NSMutableSet *selection = [self scSelection];
    uint64_t total = 0;
    for (id record in [self scSourceRecords]) {
        NSString *identifier = [record valueForKey:@"identifier"];
        if (identifier && [selection containsObject:identifier]) total += SCRecordBytes(record);
    }
    return total;
}

#pragma mark - Progressive scanning

- (void)scanCurrentMode
{
    if ([self scBusy]) {
        [self.refreshControl endRefreshing];
        return;
    }

    if (![self scPrepared]) {
        [self.refreshControl endRefreshing];
        [self prepareAccess];
        return;
    }

    NSUInteger generation = ++self.scScanGeneration;
    NSInteger mode = self.areaControl.selectedSegmentIndex;
    self.scScanning = YES;
    self.scScannedCandidates = 0;
    self.scTotalCandidates = 0;
    [[self scSelection] removeAllObjects];

    if (mode == 0) {
        [self setValue:@[] forKey:@"appRecords"];
        [self scSetStatus:@"Scanning app cache…"];
        [self scStartProgressiveAppScan:generation];
    } else {
        [self setValue:@[] forKey:@"discardedRecords"];
        [self scSetStatus:@"Scanning system cache…"];
        [self scStartProgressiveSystemScan:generation];
    }

    [self updateChrome];
    [self.tableView reloadData];
}

- (void)scStartProgressiveAppScan:(NSUInteger)generation
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *containers = [NSMutableArray array];
        DIR *directory = opendir(SCAppDataRoot.fileSystemRepresentation);
        if (directory) {
            struct dirent *entry;
            while ((entry = readdir(directory))) {
                if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                NSString *name = SCNameFromDirent(entry);
                if (!name.length || ![[NSUUID alloc] initWithUUIDString:name]) continue;
                NSString *container = [SCAppDataRoot stringByAppendingPathComponent:name];
                if (SCIsAppContainer(container) && SCDirectoryExists(container)) [containers addObject:container];
            }
            closedir(directory);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.scScanGeneration || self.areaControl.selectedSegmentIndex != 0) return;
            self.scTotalCandidates = containers.count;
            [self updateChrome];
        });

        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t gate = dispatch_semaphore_create(3);
        NSString *ownBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";

        for (NSString *container in containers) {
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
                id record = SCBuildAppRecord(container, ownBundleID);
                dispatch_semaphore_signal(gate);

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.scScanGeneration || self.areaControl.selectedSegmentIndex != 0) return;
                    self.scScannedCandidates++;
                    if (record) {
                        NSMutableArray *updated = [[self valueForKey:@"appRecords"] mutableCopy] ?: [NSMutableArray array];
                        [updated addObject:record];
                        [self setValue:[self scSortedRecords:updated] forKey:@"appRecords"];
                        [self.tableView reloadData];
                    }
                    [self updateChrome];
                });
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (generation != self.scScanGeneration || self.areaControl.selectedSegmentIndex != 0) return;
            [self scFinishScanForMode:0];
        });
    });
}

- (void)scStartProgressiveSystemScan:(NSUInteger)generation
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL exists = SCDirectoryExists(SCSystemCacheRoot);
        NSArray<NSString *> *entries = exists ? SCTopLevelEntries(SCSystemCacheRoot) : @[];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.scScanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
            [self setValue:@(exists) forKey:@"discardedRootExists"];
            self.scTotalCandidates = entries.count;
            [self updateChrome];
        });

        if (!exists || entries.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.scScanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
                [self scFinishScanForMode:1];
            });
            return;
        }

        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t gate = dispatch_semaphore_create(3);

        for (NSString *path in entries) {
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
                id record = SCBuildSystemRecord(path);
                dispatch_semaphore_signal(gate);

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.scScanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
                    self.scScannedCandidates++;
                    if (record) {
                        NSMutableArray *updated = [[self valueForKey:@"discardedRecords"] mutableCopy] ?: [NSMutableArray array];
                        [updated addObject:record];
                        [self setValue:[self scSortedRecords:updated] forKey:@"discardedRecords"];
                        [self.tableView reloadData];
                    }
                    [self updateChrome];
                });
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (generation != self.scScanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
            [self scFinishScanForMode:1];
        });
    });
}

- (void)scFinishScanForMode:(NSInteger)mode
{
    self.scScanning = NO;
    [self.refreshControl endRefreshing];

    NSArray *records = [self scSourceRecords];
    uint64_t total = [self scBytesForRecords:records];
    if (mode == 0) {
        [self scSetStatus:[NSString stringWithFormat:@"%lu apps • %@ removable",
                           (unsigned long)records.count,
                           SCFormatBytes(total)]];
    } else {
        BOOL exists = [[self valueForKey:@"discardedRootExists"] boolValue];
        [self scSetStatus:exists
            ? [NSString stringWithFormat:@"%lu system items • %@ removable",
               (unsigned long)records.count,
               SCFormatBytes(total)]
            : @"No System CacheDelete area is present"];
    }

    [self updateChrome];
    [self.tableView reloadData];
}

#pragma mark - Controls

- (void)scAreaChanged:(UISegmentedControl *)sender
{
    self.scScanGeneration++;
    self.scScanning = NO;
    [self.refreshControl endRefreshing];
    [[self scSelection] removeAllObjects];

    NSInteger mode = sender.selectedSegmentIndex == 0 ? 0 : 1;
    [self setValue:@(mode) forKey:@"browserMode"];
    self.cleanerSearchController.searchBar.text = @"";
    self.cleanerSearchController.searchBar.placeholder = mode == 0 ? @"Search apps" : @"Search system cache";
    [self updateChrome];
    [self.tableView reloadData];
    [self scanCurrentMode];
}

- (void)scRefreshPulled:(UIRefreshControl *)sender
{
    [self scanCurrentMode];
}

- (void)scCleanTapped
{
    if ([self scSelection].count == 0 || [self scBusy] || self.scScanning) return;
    if (self.areaControl.selectedSegmentIndex == 0) [self cleanSelectedApps];
    else [self stageSelectedDiscarded];
}

- (UIMenu *)scSortMenu
{
    __weak typeof(self) weakSelf = self;
    NSArray<NSDictionary *> *items = @[
        @{@"title": @"Size: Largest First", @"mode": @(SCSortModeSizeDescending)},
        @{@"title": @"Size: Smallest First", @"mode": @(SCSortModeSizeAscending)},
        @{@"title": @"Name: A to Z", @"mode": @(SCSortModeNameAscending)},
        @{@"title": @"Name: Z to A", @"mode": @(SCSortModeNameDescending)},
    ];

    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSDictionary *item in items) {
        SCSortMode mode = [item[@"mode"] integerValue];
        UIAction *action = [UIAction actionWithTitle:item[@"title"] image:nil identifier:nil handler:^(__kindof UIAction *action) {
            weakSelf.scSortMode = mode;
            [weakSelf updateChrome];
            [weakSelf.tableView reloadData];
        }];
        action.state = self.scSortMode == mode ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"Sort" children:actions];
}

- (UIMenu *)scMoreMenu
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

    UIAction *advanced = [UIAction actionWithTitle:@"Protected Cleanup (Advanced)"
                                             image:[UIImage systemImageNamed:@"wrench.and.screwdriver"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
        [weakSelf openSolver];
    }];
    advanced.attributes = [self scPrepared] && ![self scBusy] ? (UIMenuElementAttributes)0 : UIMenuElementAttributesDisabled;

    return [UIMenu menuWithTitle:@"" children:@[help, advanced]];
}

- (void)updateChrome
{
    if (!self.isViewLoaded) return;

    BOOL prepared = [self scPrepared];
    BOOL busy = [self scBusy];
    NSUInteger selected = [self scSelection].count;
    NSArray *records = [self scSourceRecords];
    uint64_t total = [self scBytesForRecords:records];

    if (busy && !prepared) {
        self.statusLabel.text = [self scBackendStatus].length ? [self scBackendStatus] : @"Enabling storage access…";
    } else if (self.scScanning) {
        self.statusLabel.text = self.areaControl.selectedSegmentIndex == 0 ? @"Scanning app cache…" : @"Scanning system cache…";
    } else if (prepared) {
        self.statusLabel.text = [self scBackendStatus].length ? [self scBackendStatus] : @"Ready";
    } else {
        self.statusLabel.text = @"Waiting for storage access…";
    }

    if (self.scScanning && self.scTotalCandidates > 0) {
        self.summaryLabel.text = [NSString stringWithFormat:@"%lu/%lu checked • %lu found • %@",
                                  (unsigned long)self.scScannedCandidates,
                                  (unsigned long)self.scTotalCandidates,
                                  (unsigned long)records.count,
                                  SCFormatBytes(total)];
    } else {
        self.summaryLabel.text = [NSString stringWithFormat:@"%lu items • %@",
                                  (unsigned long)records.count,
                                  SCFormatBytes(total)];
    }

    self.selectionItem.title = [NSString stringWithFormat:@"%lu selected • %@",
                                (unsigned long)selected,
                                SCFormatBytes([self scSelectedBytes])];
    self.cleanItem.title = self.areaControl.selectedSegmentIndex == 0 ? @"Clean Selected" : @"Stage Selected";
    self.cleanItem.enabled = prepared && !busy && !self.scScanning && selected > 0;
    self.areaControl.enabled = prepared && !busy;
    self.sortButton.enabled = records.count > 1;
    self.sortButton.menu = [self scSortMenu];
    self.moreButton.menu = [self scMoreMenu];
    self.navigationItem.searchController = self.cleanerSearchController;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return MAX((NSInteger)[self scVisibleRecords].count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.areaControl.selectedSegmentIndex == 0) {
        return @"Only Library/Caches and tmp are included for each app.";
    }
    return @"System Cache is kept separate from app cache and temporary files.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *records = [self scVisibleRecords];
    if (records.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([self scBusy] && ![self scPrepared]) {
            cell.textLabel.text = @"Enabling storage access…";
            cell.detailTextLabel.text = @"The cleaner will begin scanning automatically.";
        } else if (self.scScanning) {
            cell.textLabel.text = @"Scanning…";
            cell.detailTextLabel.text = @"Results will appear here as each item finishes.";
        } else {
            cell.textLabel.text = self.areaControl.selectedSegmentIndex == 0 ? @"No app cache found" : @"No system cache found";
            cell.detailTextLabel.text = @"Pull down to scan again.";
        }
        return cell;
    }

    id record = records[indexPath.row];
    NSString *displayName = [record valueForKey:@"displayName"] ?: @"Unknown";
    NSString *bundleID = [record valueForKey:@"bundleID"] ?: @"";
    uint64_t cacheBytes = [[record valueForKey:@"cacheBytes"] unsignedLongLongValue];
    uint64_t tmpBytes = [[record valueForKey:@"temporaryBytes"] unsignedLongLongValue];
    NSUInteger itemCount = [[record valueForKey:@"itemCount"] unsignedIntegerValue];
    NSString *identifier = [record valueForKey:@"identifier"];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = displayName;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if (self.areaControl.selectedSegmentIndex == 0) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nCache %@ • Temp %@ • %lu files",
                                     bundleID,
                                     SCFormatBytes(cacheBytes),
                                     SCFormatBytes(tmpBytes),
                                     (unsigned long)itemCount];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"System Cache\n%@ • %lu files",
                                     SCFormatBytes(cacheBytes),
                                     (unsigned long)itemCount];
    }

    cell.accessoryType = identifier && [[self scSelection] containsObject:identifier]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self scBusy] || self.scScanning) return;

    NSArray *records = [self scVisibleRecords];
    if (indexPath.row >= records.count) return;
    id record = records[indexPath.row];
    NSString *identifier = [record valueForKey:@"identifier"];
    if (!identifier.length) return;

    NSMutableSet *selection = [self scSelection];
    if ([selection containsObject:identifier]) [selection removeObject:identifier];
    else [selection addObject:identifier];

    [self updateChrome];
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
