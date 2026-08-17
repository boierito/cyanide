#import "StorageRescueGuideViewController.h"

@interface StorageRescueGuideViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@end

@implementation StorageRescueGuideViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"How It Works";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneTapped)];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    self.scrollView = scroll;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 14.0;
    stack.layoutMargins = UIEdgeInsetsMake(24.0, 20.0, 34.0, 20.0);
    stack.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:stack];
    self.stackView = stack;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];

    UIImageView *heroIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"externaldrive.badge.checkmark"]];
    heroIcon.translatesAutoresizingMaskIntoConstraints = NO;
    heroIcon.contentMode = UIViewContentModeScaleAspectFit;
    heroIcon.tintColor = UIColor.systemBlueColor;
    [heroIcon.heightAnchor constraintEqualToConstant:54.0].active = YES;
    [stack addArrangedSubview:heroIcon];

    UILabel *title = [self labelWithText:@"You stay in control of every cleanup"
                                    font:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]
                                   color:UIColor.labelColor];
    title.font = [UIFont systemFontOfSize:title.font.pointSize weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:title];

    UILabel *intro = [self labelWithText:@"Storage Rescue does not clean anything automatically. First enable access, then review what is using space, select what you want to remove, and confirm the cleanup."
                                    font:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                                   color:UIColor.secondaryLabelColor];
    intro.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:intro];

    [stack setCustomSpacing:24.0 afterView:intro];

    [stack addArrangedSubview:[self cardWithIcon:@"shield.lefthalf.filled"
                                          title:@"1. Enable access"
                                           body:@"This is required once each time the app is opened. It only allows Storage Rescue to inspect cache locations. No files are removed at this step."
                                          color:UIColor.systemBlueColor]];

    [stack addArrangedSubview:[self cardWithIcon:@"magnifyingglass"
                                          title:@"2. Review what is taking space"
                                           body:@"The cleanup screen shows three areas: Apps for normal temporary cache, iOS Leftovers for cache already abandoned by the system, and Rescue for protected cleanup when normal deletion is blocked."
                                          color:UIColor.systemIndigoColor]];

    [stack addArrangedSubview:[self cardWithIcon:@"checkmark.circle.fill"
                                          title:@"3. Select only what you want"
                                           body:@"Tap individual apps or leftover items to select them. Storage Rescue shows the amount of storage associated with your selection before any destructive action is available."
                                          color:UIColor.systemGreenColor]];

    [stack addArrangedSubview:[self cardWithIcon:@"trash.fill"
                                          title:@"4. Confirm the cleanup"
                                           body:@"Normal app cache is removed directly. iOS leftovers are moved to Rescue first, where deletion is verified before the full protected cleanup can run."
                                          color:UIColor.systemOrangeColor]];

    [stack setCustomSpacing:22.0 afterView:stack.arrangedSubviews.lastObject];

    [stack addArrangedSubview:[self cardWithIcon:@"checkmark.shield.fill"
                                          title:@"What Storage Rescue does not touch"
                                           body:@"App cleanup stays inside temporary cache folders. Photos, documents, messages, logins and normal app data are outside the cleanup scope. Rescue is restricted to its dedicated staging area."
                                          color:UIColor.systemGreenColor]];

    UILabel *tip = [self labelWithText:@"Tip: close an app before clearing its cache. Some apps immediately recreate temporary files while they are running."
                                  font:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]
                                 color:UIColor.secondaryLabelColor];
    tip.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:tip];

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"?";
    UILabel *versionLabel = [self labelWithText:[NSString stringWithFormat:@"Storage Rescue %@ (%@)\n%@", version, build, bundleID]
                                            font:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]
                                           color:UIColor.tertiaryLabelColor];
    versionLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:versionLabel];
}

- (UILabel *)labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (UIView *)cardWithIcon:(NSString *)iconName title:(NSString *)title body:(NSString *)body color:(UIColor *)color
{
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 18.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = color;
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *titleLabel = [self labelWithText:title
                                         font:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]
                                        color:UIColor.labelColor];
    UILabel *bodyLabel = [self labelWithText:body
                                        font:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]
                                       color:UIColor.secondaryLabelColor];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, bodyLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 4.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, textStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 13.0;
    row.layoutMargins = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    row.layoutMarginsRelativeArrangement = YES;
    [card addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:30.0],
        [icon.heightAnchor constraintEqualToConstant:30.0],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:card.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    return card;
}

- (void)doneTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
