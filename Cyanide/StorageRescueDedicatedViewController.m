#import "StorageRescueDedicatedViewController.h"

static NSString * const SRDedicatedTarget = @"/var/mobile/Documents/test";
static NSString * const SRInstructionsSeenKey = @"storageRescue.dedicated.instructionsSeen.v1";

@interface StorageRescueDedicatedViewController ()
@property (nonatomic, strong) UIView *srIntroHeader;
@property (nonatomic, strong) UILabel *srIntroTitle;
@property (nonatomic, strong) UILabel *srIntroBody;
@property (nonatomic, strong) UILabel *srIntroPath;
@property (nonatomic, assign) BOOL srPresentedInstructionsThisLaunch;
@end

@implementation StorageRescueDedicatedViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Storage Rescue";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    [self sr_buildIntroHeader];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (self.srPresentedInstructionsThisLaunch) return;
    self.srPresentedInstructionsThisLaunch = YES;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:SRInstructionsSeenKey]) return;

    NSString *message = [NSString stringWithFormat:
        @"Before using Storage Rescue, use Filza or another filesystem manager to move ONLY the files or folders you want permanently removed into:\n\n%@\n\nDo not move /var/mobile/Documents itself, your whole Library, or unrelated data. Storage Rescue is intentionally restricted to this folder.",
        SRDedicatedTarget];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Prepare the target folder first"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"I Understand"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [defaults setBool:YES forKey:SRInstructionsSeenKey];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self sr_layoutIntroHeader];
}

- (void)sr_buildIntroHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 250)];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"Before you start";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.numberOfLines = 1;

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectZero];
    body.text = @"1. Use Filza or another compatible filesystem manager.\n2. Move only the data you want permanently deleted into the target folder below.\n3. Return here, run Prepare Access, Scan Target, and Prove One Real Delete.\n4. Full deletion stays locked until a real file deletion is verified.";
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    body.textColor = UIColor.secondaryLabelColor;
    body.numberOfLines = 0;

    UILabel *path = [[UILabel alloc] initWithFrame:CGRectZero];
    path.text = SRDedicatedTarget;
    if (@available(iOS 13.0, *)) {
        path.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    } else {
        path.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    }
    path.numberOfLines = 0;
    path.textColor = UIColor.labelColor;

    [header addSubview:title];
    [header addSubview:body];
    [header addSubview:path];

    self.srIntroHeader = header;
    self.srIntroTitle = title;
    self.srIntroBody = body;
    self.srIntroPath = path;
    self.tableView.tableHeaderView = header;
}

- (void)sr_layoutIntroHeader
{
    if (!self.srIntroHeader) return;

    CGFloat width = self.tableView.bounds.size.width;
    CGFloat horizontal = 20.0;
    CGFloat contentWidth = MAX(0.0, width - horizontal * 2.0);
    CGFloat y = 18.0;

    CGSize titleSize = [self.srIntroTitle sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    self.srIntroTitle.frame = CGRectMake(horizontal, y, contentWidth, titleSize.height);
    y += titleSize.height + 9.0;

    CGSize bodySize = [self.srIntroBody sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    self.srIntroBody.frame = CGRectMake(horizontal, y, contentWidth, bodySize.height);
    y += bodySize.height + 12.0;

    CGSize pathSize = [self.srIntroPath sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    self.srIntroPath.frame = CGRectMake(horizontal, y, contentWidth, pathSize.height);
    y += pathSize.height + 20.0;

    CGRect frame = self.srIntroHeader.frame;
    if (fabs(frame.size.width - width) > 0.5 || fabs(frame.size.height - y) > 0.5) {
        frame.size.width = width;
        frame.size.height = y;
        self.srIntroHeader.frame = frame;
        self.tableView.tableHeaderView = self.srIntroHeader;
    }
}

@end
