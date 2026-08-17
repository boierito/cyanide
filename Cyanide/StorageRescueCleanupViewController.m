#import "StorageRescueCleanupViewController.h"
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

static BOOL SCDirectoryExists(NSString *path)
{
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 &&
           S_ISDIR(st.st_mode) &&
           !S_ISLNK(st.st_mode);
}

static NSArray<NSString *> *SCTopLevelEntries(NSString *root)
{
    DIR *directory = opendir(root.fileSystemRepresentation);
    if (!directory) return @[];

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = SCNameFromDirent(entry);
        if (!name.length) continue;
        [entries addObject:[root stringByAppendingPathComponent:name]];
    }
    closedir(directory);
    return entries;
}

static SCUsage SCScanPath(NSString *root)
{
    SCUsage usage = {0};
    struct stat rootStat;
    if (lstat(root.fileSystemRepresentation, &rootStat) != 0) return usage;

    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        @autoreleasepool {
            NSString *path = stack.lastObject;
            [stack removeLastObject];

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
                [stack addObject:[path stringByAppendingPathComponent:name]];
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

    NSDictionary *info = [metadata[@"MCMMetadataInfo"] isKindOfClass:NSDictionary.class]
        ? metadata[@"MCMMetadataInfo"] : nil;
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
    SCUsage usage = SCScanPath(path);
    if (usage.allocatedBytes == 0 && usage.files == 0 && usage.dirs == 0) return nil;

    NSString *bundleID = SCBundleIdentifierForContainer(path);
    NSString *identifier = bundleID.length ? bundleID : path.lastPathComponent;
    NSString *displayName = nil;
    if (bundleID.length) {
        displayName = [NSString stringWithFormat:@"%@ (System)", SCApplicationDisplayName(bundleID)];
    } else {
        NSString *shortID = path.lastPathComponent ?: @"Item";
        if (shortID.length > 10) shortID = [shortID substringToIndex:10];
        displayName = [NSString stringWithFormat:@"System Item %@", shortID];
    }

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

@interface StorageRescueCleanupViewController ()
@property (nonatomic, strong) UISegmentedControl *areaControl;
@property (nonatomic, strong) UISearchController *friendlySearchController;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIBarButtonItem *selectionItem;
@property (nonatomic, strong) UIBarButtonItem *cleanItem;
@property (nonatomic, strong) UIButton *sortButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, assign) BOOL scanning;
@property (nonatomic, assign) BOOL didStartAutomatically;
@property (nonatomic, assign) NSUInteger scanGeneration;
@property (nonatomic, assign) NSUInteger scannedCandidates;
@property (nonatomic, assign) NSUInteger totalCandidates;
@property (nonatomic, assign) SCSortMode sortMode;
@end

@implementation StorageRescueCleanupViewController

- (instancetype)init
{
    if ((self = [super init])) {
        _sortMode = SCSortModeSizeDescending;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Storage Cleaner";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self setValue:nil forKey:@"introLabel"];

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;

    self.areaControl = [[UISegmentedControl alloc] initWithItems:@[@"Apps", @"System Cache"]];
    self.areaControl.selectedSegmentIndex = 0;
    [self.areaControl addTarget:self action:@selector(areaChanged:) forControlEvents:UIControlEventValueChanged];
    [self setValue:@0 forKey:@"browserMode"];

    self.friendlySearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.friendlySearchController.obscuresBackgroundDuringPresentation = NO;
    self.friendlySearchController.searchResultsUpdater = self;
    self.friendlySearchController.searchBar.placeholder = @"Search apps";
    self.navigationItem.searchController = self.friendlySearchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.sortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sortButton setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] forState:UIControlStateNormal];
    self.sortButton.showsMenuAsPrimaryAction = YES;
    self.sortButton.accessibilityLabel = @"Sort";
    self.sortButton.menu = [self sortMenu];

    self.moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.moreButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    self.moreButton.showsMenuAsPrimaryAction = YES;
    self.moreButton.accessibilityLabel = @"More";
    self.moreButton.menu = [self moreMenu];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.moreButton],
        [[UIBarButtonItem alloc] initWithCustomView:self.sortButton],
    ];

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(refreshPulled:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    self.selectionItem = [[UIBarButtonItem alloc] initWithTitle:@"0 selected"
                                                          style:UIBarButtonItemStylePlain
                                                         target:nil
                                                         action:nil];
    self.cleanItem = [[UIBarButtonItem alloc] initWithTitle:@"Clean Selected"
                                                      style:UIBarButtonItemStyleDone
                                                     target:self
                                                     action:@selector(cleanTapped)];
    self.cleanItem.tintColor = UIColor.systemRedColor;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil
                                                                          action:nil];
    self.toolbarItems = @[self.selectionItem, flex, self.cleanItem];

    [self buildHeader];
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
    if (self.didStartAutomatically) return;
    self.didStartAutomatically = YES;

    // Keep the proven access backend untouched. The UI simply starts the same
    // Prepare Access flow automatically on first appearance; that method calls
    // our progressive scan when access is ready.
    if ([self respondsToSelector:NSSelectorFromString(@"prepareAccess")]) {
        [self performSelector:NSSelectorFromString(@"prepareAccess")];
    }
}

- (void)buildHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 122.0)];

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
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:12.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:header.bottomAnchor constant:-12.0],
    ]];

    self.tableView.tableHeaderView = header;
}

- (BOOL)prepared
{
    return [[self valueForKey:@"prepared"] boolValue];
}

- (BOOL)backendBusy
{
    return [[self valueForKey:@"busy"] boolValue];
}

- (NSMutableSet<NSString *> *)selectedIdentifiers
{
    id value = [self valueForKey:@"selectedIdentifiers"];
    return [value isKindOfClass:NSMutableSet.class] ? value : nil;
}

- (NSArray *)sourceRecords
{
    NSString *key = self.areaControl.selectedSegmentIndex == 0 ? @"appRecords" : @"discardedRecords";
    id value = [self valueForKey:key];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

- (NSArray *)sortedRecords:(NSArray *)records
{
    SCSortMode mode = self.sortMode;
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
        BOOL leftFirst = mode == SCSortModeSizeDescending ? leftBytes > rightBytes : leftBytes < rightBytes;
        return leftFirst ? NSOrderedAscending : NSOrderedDescending;
    }];
}

- (NSArray *)visibleRecords
{
    NSArray *records = [self sourceRecords];
    NSString *query = self.friendlySearchController.searchBar.text ?: @"";
    if (query.length) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id record, NSDictionary *bindings) {
            NSString *name = [record valueForKey:@"displayName"] ?: @"";
            NSString *bundleID = [record valueForKey:@"bundleID"] ?: @"";
            return [name rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound ||
                   [bundleID rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        records = [records filteredArrayUsingPredicate:predicate];
    }
    return [self sortedRecords:records];
}

- (uint64_t)bytesForRecords:(NSArray *)records
{
    uint64_t total = 0;
    for (id record in records) total += SCRecordBytes(record);
    return total;
}

- (uint64_t)selectedBytes
{
    NSSet *selected = [self selectedIdentifiers];
    uint64_t total = 0;
    for (id record in [self sourceRecords]) {
        NSString *identifier = [record valueForKey:@"identifier"];
        if (identifier && [selected containsObject:identifier]) total += SCRecordBytes(record);
    }
    return total;
}

- (void)setStatusText:(NSString *)text
{
    [self setValue:(text ?: @"") forKey:@"statusText"];
}

- (void)updateChrome
{
    NSArray *records = [self sourceRecords];
    BOOL prepared = [self prepared];
    BOOL busy = [self backendBusy];
    NSMutableSet *selected = [self selectedIdentifiers];
    NSUInteger selectedCount = selected.count;
    uint64_t selectedBytes = [self selectedBytes];

    NSString *backendStatus = [self valueForKey:@"statusText"];
    if (self.scanning) {
        NSString *area = self.areaControl.selectedSegmentIndex == 0 ? @"apps" : @"system cache";
        if (self.totalCandidates > 0) {
            self.statusLabel.text = [NSString stringWithFormat:@"Scanning %@… %lu/%lu checked",
                                     area,
                                     (unsigned long)self.scannedCandidates,
                                     (unsigned long)self.totalCandidates];
        } else {
            self.statusLabel.text = [NSString stringWithFormat:@"Scanning %@…", area];
        }
    } else if (busy) {
        self.statusLabel.text = backendStatus.length ? backendStatus : @"Working…";
    } else if (!prepared) {
        self.statusLabel.text = backendStatus.length ? backendStatus : @"Enabling storage access…";
    } else {
        self.statusLabel.text = backendStatus.length ? backendStatus : @"Ready";
    }

    uint64_t totalBytes = [self bytesForRecords:records];
    self.summaryLabel.text = [NSString stringWithFormat:@"%lu items • %@ removable",
                              (unsigned long)records.count,
                              SCFormatBytes(totalBytes)];

    self.selectionItem.title = selectedCount
        ? [NSString stringWithFormat:@"%lu selected • %@", (unsigned long)selectedCount, SCFormatBytes(selectedBytes)]
        : @"0 selected";

    self.cleanItem.title = self.areaControl.selectedSegmentIndex == 0 ? @"Clean Selected" : @"Clean System Cache";
    self.cleanItem.enabled = prepared && !busy && !self.scanning && selectedCount > 0;
    self.sortButton.enabled = records.count > 1;
    self.sortButton.menu = [self sortMenu];
    self.moreButton.menu = [self moreMenu];
}

- (void)areaChanged:(UISegmentedControl *)sender
{
    self.scanGeneration++;
    self.scanning = NO;
    [self.refreshControl endRefreshing];
    [[self selectedIdentifiers] removeAllObjects];

    NSInteger mode = sender.selectedSegmentIndex == 0 ? 0 : 1;
    [self setValue:@(mode) forKey:@"browserMode"];
    self.friendlySearchController.searchBar.text = @"";
    self.friendlySearchController.searchBar.placeholder = sender.selectedSegmentIndex == 0
        ? @"Search apps"
        : @"Search system cache";

    [self updateChrome];
    [self.tableView reloadData];
    [self scanCurrentMode];
}

- (void)refreshPulled:(UIRefreshControl *)sender
{
    [self scanCurrentMode];
}

- (void)scanCurrentMode
{
    if ([self backendBusy]) {
        [self.refreshControl endRefreshing];
        return;
    }

    if (![self prepared]) {
        [self.refreshControl endRefreshing];
        if ([self respondsToSelector:NSSelectorFromString(@"prepareAccess")]) {
            [self performSelector:NSSelectorFromString(@"prepareAccess")];
        }
        return;
    }

    NSUInteger generation = ++self.scanGeneration;
    NSInteger mode = self.areaControl.selectedSegmentIndex;
    self.scanning = YES;
    self.scannedCandidates = 0;
    self.totalCandidates = 0;
    [[self selectedIdentifiers] removeAllObjects];

    if (mode == 0) {
        [self setValue:@[] forKey:@"appRecords"];
        [self setStatusText:@"Scanning app cache…"];
        [self startProgressiveAppScan:generation];
    } else {
        [self setValue:@[] forKey:@"discardedRecords"];
        [self setStatusText:@"Scanning system cache…"];
        [self startProgressiveSystemScan:generation];
    }

    [self updateChrome];
    [self.tableView reloadData];
}

- (void)startProgressiveAppScan:(NSUInteger)generation
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
                if (SCDirectoryExists(container)) [containers addObject:container];
            }
            closedir(directory);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.scanGeneration || self.areaControl.selectedSegmentIndex != 0) return;
            self.totalCandidates = containers.count;
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
                    if (generation != self.scanGeneration || self.areaControl.selectedSegmentIndex != 0) return;
                    self.scannedCandidates++;

                    if (record) {
                        NSMutableArray *updated = [[self valueForKey:@"appRecords"] mutableCopy] ?: [NSMutableArray array];
                        [updated addObject:record];
                        [self setValue:[self sortedRecords:updated] forKey:@"appRecords"];
                        [self.tableView reloadData];
                    }
                    [self updateChrome];
                });
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (generation != self.scanGeneration || self.areaControl.selectedSegmentIndex != 0) return;
            [self finishScanForMode:0];
        });
    });
}

- (void)startProgressiveSystemScan:(NSUInteger)generation
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL exists = SCDirectoryExists(SCSystemCacheRoot);
        NSArray<NSString *> *entries = exists ? SCTopLevelEntries(SCSystemCacheRoot) : @[];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.scanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
            [self setValue:@(exists) forKey:@"discardedRootExists"];
            self.totalCandidates = entries.count;
            [self updateChrome];
        });

        if (!exists || entries.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.scanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
                [self finishScanForMode:1];
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
                    if (generation != self.scanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
                    self.scannedCandidates++;

                    if (record) {
                        NSMutableArray *updated = [[self valueForKey:@"discardedRecords"] mutableCopy] ?: [NSMutableArray array];
                        [updated addObject:record];
                        [self setValue:[self sortedRecords:updated] forKey:@"discardedRecords"];
                        [self.tableView reloadData];
                    }
                    [self updateChrome];
                });
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (generation != self.scanGeneration || self.areaControl.selectedSegmentIndex != 1) return;
            [self finishScanForMode:1];
        });
    });
}

- (void)finishScanForMode:(NSInteger)mode
{
    self.scanning = NO;
    [self.refreshControl endRefreshing];

    NSArray *records = [self sourceRecords];
    uint64_t totalBytes = [self bytesForRecords:records];
    if (mode == 0) {
        [self setStatusText:[NSString stringWithFormat:@"%lu apps • %@ removable",
                             (unsigned long)records.count,
                             SCFormatBytes(totalBytes)]];
    } else {
        BOOL exists = [[self valueForKey:@"discardedRootExists"] boolValue];
        if (!exists) {
            [self setStatusText:@"No System CacheDelete area is present"];
        } else {
            [self setStatusText:[NSString stringWithFormat:@"%lu system items • %@ removable",
                                 (unsigned long)records.count,
                                 SCFormatBytes(totalBytes)]];
        }
    }

    [self updateChrome];
    [self.tableView reloadData];
}

- (UIMenu *)sortMenu
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
        UIAction *action = [UIAction actionWithTitle:item[@"title"]
                                              image:nil
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
            weakSelf.sortMode = mode;
            weakSelf.sortButton.menu = [weakSelf sortMenu];
            [weakSelf.tableView reloadData];
        }];
        action.state = self.sortMode == mode ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"Sort" children:actions];
}

- (UIMenu *)moreMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *help = [UIAction actionWithTitle:@"FAQ, Tutorial & Credits"
                                         image:[UIImage systemImageNamed:@"questionmark.circle"]
                                    identifier:nil
                                       handler:^(__kindof UIAction *action) {
        [weakSelf showGuide];
    }];

    UIAction *advanced = [UIAction actionWithTitle:@"Protected Cleanup (Advanced)"
                                             image:[UIImage systemImageNamed:@"wrench.and.screwdriver"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
        if ([weakSelf respondsToSelector:NSSelectorFromString(@"openSolver")]) {
            [weakSelf performSelector:NSSelectorFromString(@"openSolver")];
        }
    }];
    advanced.attributes = [self prepared] && ![self backendBusy]
        ? (UIMenuElementAttributes)0
        : UIMenuElementAttributesDisabled;

    return [UIMenu menuWithTitle:@"" children:@[help, advanced]];
}

- (void)showGuide
{
    StorageRescueGuideViewController *guide = [[StorageRescueGuideViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:guide];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)cleanTapped
{
    if (self.scanning || [self backendBusy] || ![self prepared]) return;

    if (self.areaControl.selectedSegmentIndex == 0) {
        if ([self respondsToSelector:NSSelectorFromString(@"cleanSelectedApps")]) {
            [self performSelector:NSSelectorFromString(@"cleanSelectedApps")];
        }
    } else {
        if ([self respondsToSelector:NSSelectorFromString(@"stageSelectedDiscarded")]) {
            [self performSelector:NSSelectorFromString(@"stageSelectedDiscarded")];
        }
    }
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return MAX((NSInteger)[self visibleRecords].count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return self.areaControl.selectedSegmentIndex == 0 ? @"APP CACHE & TEMP" : @"SYSTEM CACHE";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.areaControl.selectedSegmentIndex == 0) {
        return @"Only Library/Caches and tmp are included. Documents, photos, messages, logins and normal app data are outside this cleanup scope.";
    }
    return @"System Cache contains CacheDelete leftovers managed by iOS. It is kept separate from app cache and temp files.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *records = [self visibleRecords];
    if (records.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        if ([self backendBusy] && ![self prepared]) {
            cell.textLabel.text = @"Enabling storage access…";
            cell.detailTextLabel.text = @"Scanning will start automatically when access is ready.";
        } else if (self.scanning) {
            cell.textLabel.text = @"Scanning…";
            cell.detailTextLabel.text = @"Items appear here as soon as each scan finishes.";
        } else if (![self prepared]) {
            cell.textLabel.text = @"Storage access unavailable";
            cell.detailTextLabel.text = @"Pull down to retry.";
        } else {
            cell.textLabel.text = @"No removable cache found";
            cell.detailTextLabel.text = @"Pull down to scan again.";
        }
        return cell;
    }

    id record = records[indexPath.row];
    NSString *name = [record valueForKey:@"displayName"] ?: @"Unknown";
    NSString *bundleID = [record valueForKey:@"bundleID"] ?: @"";
    uint64_t cacheBytes = [[record valueForKey:@"cacheBytes"] unsignedLongLongValue];
    uint64_t tempBytes = [[record valueForKey:@"temporaryBytes"] unsignedLongLongValue];
    NSUInteger files = [[record valueForKey:@"itemCount"] unsignedIntegerValue];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = name;
    cell.textLabel.numberOfLines = 1;

    if (self.areaControl.selectedSegmentIndex == 0) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %lu files\nCache %@ · Temp %@",
                                     SCFormatBytes(cacheBytes + tempBytes),
                                     (unsigned long)files,
                                     SCFormatBytes(cacheBytes),
                                     SCFormatBytes(tempBytes)];
    } else {
        NSString *identifier = bundleID.length ? bundleID : @"CacheDelete";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %lu files\n%@",
                                     SCFormatBytes(cacheBytes),
                                     (unsigned long)files,
                                     identifier];
    }
    cell.detailTextLabel.numberOfLines = 2;

    NSString *identifier = [record valueForKey:@"identifier"];
    cell.accessoryType = identifier && [[self selectedIdentifiers] containsObject:identifier]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSArray *records = [self visibleRecords];
    if (indexPath.row >= records.count) {
        if (![self prepared] && ![self backendBusy] && [self respondsToSelector:NSSelectorFromString(@"prepareAccess")]) {
            [self performSelector:NSSelectorFromString(@"prepareAccess")];
        }
        return;
    }

    id record = records[indexPath.row];
    NSString *identifier = [record valueForKey:@"identifier"];
    if (!identifier.length) return;

    NSMutableSet *selected = [self selectedIdentifiers];
    if ([selected containsObject:identifier]) [selected removeObject:identifier];
    else [selected addObject:identifier];

    [self updateChrome];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self.tableView reloadData];
}

@end
