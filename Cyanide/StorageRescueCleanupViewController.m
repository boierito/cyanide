#import "StorageRescueCleanupViewController.h"
#import "StorageRescueGuideViewController.h"

@interface StorageRescueDedicatedViewController (StorageCleanerBackend)
- (void)prepareAccess;
- (void)scanCurrentMode;
- (void)cleanSelectedApps;
- (void)stageSelectedDiscarded;
- (void)openSolver;
- (void)updateChrome;
@end

typedef NS_ENUM(NSInteger, SCSortMode) {
    SCSortModeSizeDescending = 0,
    SCSortModeSizeAscending,
    SCSortModeNameAscending,
    SCSortModeNameDescending,
};

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
@property (nonatomic, strong) UISegmentedControl *cleanerAreaControl;
@property (nonatomic, strong) UISearchController *cleanerSearchController;
@property (nonatomic, strong) UILabel *cleanerStatusLabel;
@property (nonatomic, strong) UILabel *cleanerSummaryLabel;
@property (nonatomic, strong) UIBarButtonItem *cleanerAccessItem;
@property (nonatomic, strong) UIBarButtonItem *cleanerSelectionItem;
@property (nonatomic, strong) UIBarButtonItem *cleanerCleanItem;
@property (nonatomic, strong) UIButton *cleanerSortButton;
@property (nonatomic, strong) UIButton *cleanerMoreButton;
@property (nonatomic, assign) SCSortMode cleanerSortMode;
@end

@implementation StorageRescueCleanupViewController

- (instancetype)init
{
    if ((self = [super init])) {
        _cleanerSortMode = SCSortModeSizeDescending;
    }
    return self;
}

- (void)viewDidLoad
{
    // IMPORTANT: super initializes the exact backend state and controls used by
    // main. This subclass only replaces presentation; it does not replace the
    // access, scan, cleanup, staging or solver implementations.
    [super viewDidLoad];

    self.title = @"Storage Cleaner";
    self.navigationItem.titleView = nil;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;

    self.cleanerAreaControl = [[UISegmentedControl alloc] initWithItems:@[@"Apps", @"System Cache"]];
    self.cleanerAreaControl.selectedSegmentIndex = 0;
    [self.cleanerAreaControl addTarget:self
                                action:@selector(cleanerAreaChanged:)
                      forControlEvents:UIControlEventValueChanged];
    [self setValue:@0 forKey:@"browserMode"];

    self.cleanerSearchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.cleanerSearchController.obscuresBackgroundDuringPresentation = NO;
    self.cleanerSearchController.searchResultsUpdater = self;
    self.cleanerSearchController.searchBar.placeholder = @"Search apps";
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.cleanerSortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cleanerSortButton setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                            forState:UIControlStateNormal];
    self.cleanerSortButton.showsMenuAsPrimaryAction = YES;
    self.cleanerSortButton.accessibilityLabel = @"Sort";

    self.cleanerMoreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cleanerMoreButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                            forState:UIControlStateNormal];
    self.cleanerMoreButton.showsMenuAsPrimaryAction = YES;
    self.cleanerMoreButton.accessibilityLabel = @"More";

    self.cleanerAccessItem = [[UIBarButtonItem alloc] initWithTitle:@"Enable Access"
                                                              style:UIBarButtonItemStyleDone
                                                             target:self
                                                             action:@selector(cleanerAccessTapped)];

    self.cleanerSelectionItem = [[UIBarButtonItem alloc] initWithTitle:@"0 selected"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:nil
                                                                 action:nil];
    self.cleanerCleanItem = [[UIBarButtonItem alloc] initWithTitle:@"Clean Selected"
                                                              style:UIBarButtonItemStyleDone
                                                             target:self
                                                             action:@selector(cleanerCleanTapped)];
    self.cleanerCleanItem.tintColor = UIColor.systemRedColor;

    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
        target:nil
        action:nil];
    self.toolbarItems = @[self.cleanerSelectionItem, flex, self.cleanerCleanItem];

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(cleanerRefreshPulled:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self buildCleanerHeader];
    [self applyCleanerChrome];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self applyCleanerChrome];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

#pragma mark - Main backend state bridge

- (BOOL)cleanerPrepared
{
    return [[self valueForKey:@"prepared"] boolValue];
}

- (BOOL)cleanerBusy
{
    return [[self valueForKey:@"busy"] boolValue];
}

- (NSString *)cleanerBackendStatus
{
    id value = [self valueForKey:@"statusText"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (NSMutableSet<NSString *> *)cleanerSelection
{
    id value = [self valueForKey:@"selectedIdentifiers"];
    return [value isKindOfClass:NSMutableSet.class] ? value : nil;
}

- (NSArray *)cleanerSourceRecords
{
    NSString *key = self.cleanerAreaControl.selectedSegmentIndex == 0
        ? @"appRecords"
        : @"discardedRecords";
    id value = [self valueForKey:key];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

#pragma mark - Branch frontend presentation

- (void)buildCleanerHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 112.0)];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    [header addSubview:stack];

    [stack addArrangedSubview:self.cleanerAreaControl];

    self.cleanerStatusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.cleanerStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.cleanerStatusLabel.textColor = UIColor.secondaryLabelColor;
    self.cleanerStatusLabel.numberOfLines = 1;
    [stack addArrangedSubview:self.cleanerStatusLabel];

    self.cleanerSummaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.cleanerSummaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.cleanerSummaryLabel.textColor = UIColor.tertiaryLabelColor;
    self.cleanerSummaryLabel.numberOfLines = 1;
    [stack addArrangedSubview:self.cleanerSummaryLabel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20.0],
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:10.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:header.bottomAnchor constant:-10.0],
    ]];

    self.tableView.tableHeaderView = header;
}

- (NSArray *)cleanerSortedRecords:(NSArray *)records
{
    SCSortMode mode = self.cleanerSortMode;
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
        if (mode == SCSortModeSizeDescending) {
            return leftBytes > rightBytes ? NSOrderedAscending : NSOrderedDescending;
        }
        return leftBytes < rightBytes ? NSOrderedAscending : NSOrderedDescending;
    }];
}

- (NSArray *)cleanerVisibleRecords
{
    NSArray *records = [self cleanerSortedRecords:[self cleanerSourceRecords]];
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

- (uint64_t)cleanerBytesForRecords:(NSArray *)records
{
    uint64_t total = 0;
    for (id record in records) total += SCRecordBytes(record);
    return total;
}

- (uint64_t)cleanerSelectedBytes
{
    NSMutableSet *selection = [self cleanerSelection];
    uint64_t total = 0;
    for (id record in [self cleanerSourceRecords]) {
        NSString *identifier = [record valueForKey:@"identifier"];
        if (identifier && [selection containsObject:identifier]) total += SCRecordBytes(record);
    }
    return total;
}

#pragma mark - Frontend actions -> main backend methods

- (void)cleanerAccessTapped
{
    if ([self cleanerBusy]) return;

    if ([self cleanerPrepared]) {
        [self scanCurrentMode];
    } else {
        [self prepareAccess];
    }
}

- (void)cleanerAreaChanged:(UISegmentedControl *)sender
{
    if ([self cleanerBusy]) return;

    [[self cleanerSelection] removeAllObjects];
    NSInteger mode = sender.selectedSegmentIndex == 0 ? 0 : 1;
    [self setValue:@(mode) forKey:@"browserMode"];

    self.cleanerSearchController.searchBar.text = @"";
    self.cleanerSearchController.searchBar.placeholder = mode == 0
        ? @"Search apps"
        : @"Search system cache";

    [self applyCleanerChrome];
    [self.tableView reloadData];

    if ([self cleanerPrepared]) [self scanCurrentMode];
}

- (void)cleanerRefreshPulled:(UIRefreshControl *)sender
{
    if ([self cleanerPrepared]) [self scanCurrentMode];
    else [self prepareAccess];
}

- (void)cleanerCleanTapped
{
    if ([self cleanerBusy] || [self cleanerSelection].count == 0) return;

    if (self.cleanerAreaControl.selectedSegmentIndex == 0) {
        [self cleanSelectedApps];
    } else {
        [self stageSelectedDiscarded];
    }
}

- (UIMenu *)cleanerSortMenu
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
            weakSelf.cleanerSortMode = mode;
            [weakSelf applyCleanerChrome];
            [weakSelf.tableView reloadData];
        }];
        action.state = self.cleanerSortMode == mode ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"Sort" children:actions];
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

    UIAction *advanced = [UIAction actionWithTitle:@"Protected Cleanup (Advanced)"
                                             image:[UIImage systemImageNamed:@"wrench.and.screwdriver"]
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
        [weakSelf openSolver];
    }];
    advanced.attributes = [self cleanerPrepared] && ![self cleanerBusy]
        ? (UIMenuElementAttributes)0
        : UIMenuElementAttributesDisabled;

    return [UIMenu menuWithTitle:@"" children:@[help, advanced]];
}

#pragma mark - Chrome

- (void)updateChrome
{
    // Preserve main's state transitions first, then re-apply only the branch UI.
    [super updateChrome];
    [self applyCleanerChrome];
}

- (void)applyCleanerChrome
{
    if (!self.isViewLoaded || !self.cleanerAreaControl) return;

    BOOL prepared = [self cleanerPrepared];
    BOOL busy = [self cleanerBusy];
    NSArray *records = [self cleanerSourceRecords];
    NSUInteger selected = [self cleanerSelection].count;
    uint64_t total = [self cleanerBytesForRecords:records];

    NSString *status = [self cleanerBackendStatus];
    if (busy) {
        self.cleanerStatusLabel.text = status.length ? status : @"Working…";
    } else if (prepared) {
        self.cleanerStatusLabel.text = status.length ? status : @"Storage access ready";
    } else {
        self.cleanerStatusLabel.text = @"Storage access is not enabled";
    }

    self.cleanerSummaryLabel.text = [NSString stringWithFormat:@"%lu items • %@",
                                     (unsigned long)records.count,
                                     SCFormatBytes(total)];

    if (busy && !prepared) {
        self.cleanerAccessItem.title = @"Enabling…";
    } else if (prepared) {
        self.cleanerAccessItem.title = @"Rescan";
    } else {
        self.cleanerAccessItem.title = @"Enable Access";
    }
    self.cleanerAccessItem.enabled = !busy;

    self.cleanerSelectionItem.title = [NSString stringWithFormat:@"%lu selected • %@",
                                       (unsigned long)selected,
                                       SCFormatBytes([self cleanerSelectedBytes])];
    self.cleanerCleanItem.title = self.cleanerAreaControl.selectedSegmentIndex == 0
        ? @"Clean Selected"
        : @"Stage Selected";
    self.cleanerCleanItem.enabled = prepared && !busy && selected > 0;

    self.cleanerAreaControl.enabled = !busy;
    self.cleanerSortButton.enabled = records.count > 1;
    self.cleanerSortButton.menu = [self cleanerSortMenu];
    self.cleanerMoreButton.menu = [self cleanerMoreMenu];

    self.navigationItem.titleView = nil;
    self.navigationItem.leftBarButtonItem = self.cleanerAccessItem;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.cleanerMoreButton],
        [[UIBarButtonItem alloc] initWithCustomView:self.cleanerSortButton],
    ];
    self.navigationItem.searchController = self.cleanerSearchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    if (!busy) [self.refreshControl endRefreshing];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self.tableView reloadData];
}

#pragma mark - Table frontend

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return MAX((NSInteger)[self cleanerVisibleRecords].count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (self.cleanerAreaControl.selectedSegmentIndex == 0) {
        return @"Only Library/Caches and tmp are included for each app.";
    }
    return @"System Cache is kept separate from app cache and temporary files.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *records = [self cleanerVisibleRecords];

    if (records.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        if ([self cleanerBusy] && ![self cleanerPrepared]) {
            cell.textLabel.text = @"Enabling storage access…";
            cell.detailTextLabel.text = @"The main backend is preparing access.";
        } else if ([self cleanerBusy]) {
            cell.textLabel.text = @"Scanning…";
            cell.detailTextLabel.text = @"Storage Rescue is checking the selected area.";
        } else if (![self cleanerPrepared]) {
            cell.textLabel.text = @"Enable storage access to begin";
            cell.detailTextLabel.text = @"Use Enable Access above. Nothing is deleted by this step.";
        } else {
            cell.textLabel.text = self.cleanerAreaControl.selectedSegmentIndex == 0
                ? @"No app cache found"
                : @"No system cache found";
            cell.detailTextLabel.text = @"Pull down or tap Rescan to check again.";
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

    if (self.cleanerAreaControl.selectedSegmentIndex == 0) {
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

    cell.accessoryType = identifier && [[self cleanerSelection] containsObject:identifier]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self cleanerBusy]) return;

    NSArray *records = [self cleanerVisibleRecords];
    if (indexPath.row >= records.count) return;

    id record = records[indexPath.row];
    NSString *identifier = [record valueForKey:@"identifier"];
    if (!identifier.length) return;

    NSMutableSet *selection = [self cleanerSelection];
    if ([selection containsObject:identifier]) [selection removeObject:identifier];
    else [selection addObject:identifier];

    [self applyCleanerChrome];
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
