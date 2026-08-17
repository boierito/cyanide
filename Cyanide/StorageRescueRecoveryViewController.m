#import "StorageRescueRecoveryViewController.h"

@interface StorageRescueRecoveryViewController ()
@property (nonatomic, strong) UIView *friendlyHeader;
@property (nonatomic, strong) UILabel *friendlyBody;
@property (nonatomic, assign) BOOL diagnosticsExpanded;
@end

@implementation StorageRescueRecoveryViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Rescue";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self buildFriendlyHeader];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self sizeFriendlyHeaderIfNeeded];
}

- (void)buildFriendlyHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 170)];

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [header addSubview:card];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lifepreserver.fill"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.systemRedColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"Protected cleanup";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectZero];
    body.text = @"Use Rescue only for cache already moved into the rescue area. Storage Rescue first checks the contents, then removes one real cache file as a safety proof. Full cleanup stays locked until that proof succeeds.";
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    body.textColor = UIColor.secondaryLabelColor;
    body.numberOfLines = 0;
    body.adjustsFontForContentSizeCategory = YES;
    self.friendlyBody = body;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[title, body]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 5.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, text]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 12.0;
    row.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
    row.layoutMarginsRelativeArrangement = YES;
    [card addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:12.0],
        [card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12.0],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:card.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [icon.widthAnchor constraintEqualToConstant:30.0],
        [icon.heightAnchor constraintEqualToConstant:30.0],
    ]];

    self.friendlyHeader = header;
    self.tableView.tableHeaderView = header;
}

- (void)sizeFriendlyHeaderIfNeeded
{
    if (!self.friendlyHeader) return;
    CGFloat width = self.tableView.bounds.size.width;
    CGRect frame = self.friendlyHeader.frame;
    frame.size.width = width;
    self.friendlyHeader.frame = frame;
    [self.friendlyHeader setNeedsLayout];
    [self.friendlyHeader layoutIfNeeded];

    CGSize fitting = [self.friendlyHeader systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                          withHorizontalFittingPriority:UILayoutPriorityRequired
                                                verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = MAX(150.0, fitting.height);
    if (fabs(self.friendlyHeader.frame.size.height - height) > 0.5) {
        frame = self.friendlyHeader.frame;
        frame.size.height = height;
        self.friendlyHeader.frame = frame;
        self.tableView.tableHeaderView = self.friendlyHeader;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 2) {
        if (!self.diagnosticsExpanded) return 1;
        return 1 + [super tableView:tableView numberOfRowsInSection:section];
    }
    return [super tableView:tableView numberOfRowsInSection:section];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"Rescue Status";
    if (section == 1) return @"Safe Cleanup";
    return @"Technical Details";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) {
        return @"Full cleanup cannot start until Storage Rescue has successfully removed and verified one real staged cache file.";
    }
    if (section == 2) {
        return @"Technical logs are optional and mainly useful when troubleshooting a failed rescue.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = self.diagnosticsExpanded ? @"Hide Technical Details" : @"Show Technical Details";
            cell.imageView.image = [UIImage systemImageNamed:self.diagnosticsExpanded ? @"chevron.up.circle" : @"chevron.down.circle"];
            cell.imageView.tintColor = UIColor.secondaryLabelColor;
            return cell;
        }
        NSIndexPath *superPath = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
        return [super tableView:tableView cellForRowAtIndexPath:superPath];
    }

    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Rescue Area";
            cell.detailTextLabel.text = @"Private staging folder";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Status";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Staged Data";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        cell.imageView.tintColor = UIColor.systemBlueColor;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"1. Prepare Rescue";
            cell.detailTextLabel.text = @"Makes the rescue area available. Nothing is deleted.";
            cell.imageView.image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"2. Check Contents";
            cell.detailTextLabel.text = @"Counts staged files and the storage they occupy.";
            cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"3. Verify Safe Deletion";
            cell.detailTextLabel.text = @"Deletes one staged cache file and confirms it is really gone.";
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.shield"];
        } else if (indexPath.row == 3) {
            BOOL unlocked = [cell.detailTextLabel.text containsString:@"UNLOCKED"];
            cell.textLabel.text = @"4. Free Staged Storage";
            cell.detailTextLabel.text = unlocked
                ? @"Ready — deletion has been verified."
                : @"Locked until the verification step succeeds.";
            cell.textLabel.textColor = unlocked ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
            cell.imageView.image = [UIImage systemImageNamed:unlocked ? @"trash.fill" : @"lock.fill"];
            cell.imageView.tintColor = unlocked ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"Stop Current Operation";
            cell.detailTextLabel.text = @"Stops after the current filesystem operation finishes.";
            cell.imageView.image = [UIImage systemImageNamed:@"stop.circle"];
            cell.imageView.tintColor = UIColor.systemOrangeColor;
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 2) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (indexPath.row == 0) {
            self.diagnosticsExpanded = !self.diagnosticsExpanded;
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
        }
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end
