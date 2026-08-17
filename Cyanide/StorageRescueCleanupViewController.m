#import "StorageRescueCleanupViewController.h"

@interface StorageRescueCleanupViewController ()
@property (nonatomic, weak) UISegmentedControl *friendlyModeControl;
@end

@implementation StorageRescueCleanupViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Cleanup";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.friendlyModeControl = [self findSegmentedControlInView:self.navigationItem.titleView];
    if (!self.friendlyModeControl) {
        self.friendlyModeControl = [self findSegmentedControlInView:self.tableView.tableHeaderView];
    }
    [self applyFriendlyModeLabels];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!self.friendlyModeControl) {
        self.friendlyModeControl = [self findSegmentedControlInView:self.navigationItem.titleView];
    }
    if (!self.friendlyModeControl) {
        self.friendlyModeControl = [self findSegmentedControlInView:self.tableView.tableHeaderView];
    }
    [self applyFriendlyModeLabels];
}

- (UISegmentedControl *)findSegmentedControlInView:(UIView *)view
{
    if ([view isKindOfClass:UISegmentedControl.class]) return (UISegmentedControl *)view;
    for (UIView *subview in view.subviews) {
        UISegmentedControl *found = [self findSegmentedControlInView:subview];
        if (found) return found;
    }
    return nil;
}

- (void)applyFriendlyModeLabels
{
    UISegmentedControl *control = self.friendlyModeControl;
    if (!control || control.numberOfSegments < 3) return;
    [control setTitle:@"Apps" forSegmentAtIndex:0];
    [control setTitle:@"iOS Leftovers" forSegmentAtIndex:1];
    [control setTitle:@"Rescue" forSegmentAtIndex:2];
    control.accessibilityLabel = @"Cleanup type";
}

- (NSInteger)friendlyMode
{
    UISegmentedControl *control = self.friendlyModeControl;
    return control ? control.selectedSegmentIndex : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSInteger mode = [self friendlyMode];
    if (section == 0) return @"STEP 1 · ENABLE ACCESS";
    if (section == 1) return mode == 2 ? @"STEP 2 · FINISH RESCUE" : @"STEP 2 · REVIEW & CLEAN";
    if (mode == 0) return @"STEP 3 · CHOOSE APPS";
    if (mode == 1) return @"STEP 3 · CHOOSE LEFTOVERS";
    return @"RESCUE AREA";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSInteger mode = [self friendlyMode];
    if (section == 0) {
        return @"Required once per launch. Enabling access does not remove any files.";
    }
    if (section == 1 && mode == 0) {
        return @"Select one or more apps below, then use Clean Selected Apps. Only temporary cache folders are included.";
    }
    if (section == 1 && mode == 1) {
        return @"These are cache leftovers already separated by iOS. Moving them to Rescue does not free space until Rescue finishes deletion.";
    }
    if (section == 1 && mode == 2) {
        return @"Rescue verifies that deletion works before full cleanup becomes available.";
    }
    if (section == 2 && mode == 0) {
        return @"Tap an app to select it. Photos, documents, messages, logins and normal app data are not part of this list.";
    }
    if (section == 2 && mode == 1) {
        return @"Tap an item to select it. Selected leftovers are moved into the dedicated Rescue area before deletion.";
    }
    if (section == 2 && mode == 2) {
        return @"Data shown here still occupies storage until the protected cleanup completes successfully.";
    }
    return [super tableView:tableView titleForFooterInSection:section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    NSInteger mode = [self friendlyMode];

    if (indexPath.section == 0) {
        if (cell.userInteractionEnabled && ![cell.textLabel.text containsString:@"Ready"] && ![cell.textLabel.text containsString:@"Enabling"]) {
            cell.textLabel.text = @"Enable Storage Access";
            cell.detailTextLabel.text = @"Needed once after opening Storage Rescue. Nothing is deleted during this step.";
        } else if ([cell.textLabel.text containsString:@"Ready"]) {
            cell.textLabel.text = @"Access Ready";
            cell.detailTextLabel.text = @"You can scan and clean storage for this launch.";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        if (mode == 0) {
            if (indexPath.row == 0) cell.textLabel.text = @"Cache Available";
            else if (indexPath.row == 1) cell.textLabel.text = @"Your Selection";
            else if (indexPath.row == 2) {
                if (cell.userInteractionEnabled) cell.textLabel.text = @"Clean Selected Apps";
                cell.detailTextLabel.text = @"Removes only temporary cache from the apps you selected.";
            }
        } else if (mode == 1) {
            if (indexPath.row == 0) cell.textLabel.text = @"iOS Leftovers Found";
            else if (indexPath.row == 1) cell.textLabel.text = @"Your Selection";
            else if (indexPath.row == 2) {
                if (cell.userInteractionEnabled) cell.textLabel.text = @"Move Selected to Rescue";
                cell.detailTextLabel.text = @"Stages selected leftovers for protected cleanup. This move alone does not free space.";
            }
        } else {
            if (indexPath.row == 0) cell.textLabel.text = @"Waiting for Rescue";
            else if (indexPath.row == 1 && cell.userInteractionEnabled) {
                cell.textLabel.text = @"Open Protected Cleanup";
                cell.detailTextLabel.text = @"Verify deletion first, then free the staged storage.";
            }
        }
        return cell;
    }

    if (indexPath.section == 2 && mode != 2 && cell.detailTextLabel.text.length) {
        NSArray<NSString *> *lines = [cell.detailTextLabel.text componentsSeparatedByString:@"\n"];
        if (lines.count > 1) {
            NSString *friendlyDetail = lines.lastObject;
            if (mode == 1) {
                friendlyDetail = [friendlyDetail stringByReplacingOccurrencesOfString:@"waiting for Rescue" withString:@"ready to move to Rescue"];
            }
            cell.detailTextLabel.text = friendlyDetail;
            cell.detailTextLabel.numberOfLines = 1;
        }
    }

    return cell;
}

@end
