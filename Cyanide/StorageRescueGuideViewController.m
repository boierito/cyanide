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
    stack.layoutMargins = UIEdgeInsetsMake(24, 20, 32, 20);
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
    [heroIcon.heightAnchor constraintEqualToConstant:52.0].active = YES;
    [stack addArrangedSubview:heroIcon];

    UILabel *title = [self labelWithText:@"Free storage without exposing filesystem internals"
                                    font:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]
                                   color:UIColor.labelColor];
    title.font = [UIFont systemFontOfSize:title.font.pointSize weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:title];

    UILabel *intro = [self labelWithText:@"Storage Rescue separates ordinary app cache from protected leftovers. Start with the safest cleanup path; the low-level rescue flow is only used when normal deletion is blocked."
                                    font:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                                   color:UIColor.secondaryLabelColor];
    intro.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:intro];

    [stack setCustomSpacing:24.0 afterView:intro];

    [stack addArrangedSubview:[self cardWithIcon:@"app.fill"
                                          title:@"1. App Cache"
                                           body:@"Temporary files created by apps. Storage Rescue only touches Library/Caches and tmp inside a validated app container. Documents, photos, logins and normal app data are outside this scope."
                                          color:UIColor.systemBlueColor]];

    [stack addArrangedSubview:[self cardWithIcon:@"archivebox.fill"
                                          title:@"2. Protected Cache"
                                           body:@"Leftover cache already set aside by iOS. If it exists, you can select it and move it into the private Rescue area. Moving it is fast, but space is not freed until Rescue deletes it."
                                          color:UIColor.systemOrangeColor]];

    [stack addArrangedSubview:[self cardWithIcon:@"lifepreserver.fill"
                                          title:@"3. Rescue"
                                           body:@"For staged data that still refuses normal deletion. Rescue first proves that one real cache file can be removed, then unlocks the full cleanup."
                                          color:UIColor.systemRedColor]];

    [stack setCustomSpacing:22.0 afterView:stack.arrangedSubviews.lastObject];

    UIView *safety = [self cardWithIcon:@"checkmark.shield.fill"
                                  title:@"Safety boundaries"
                                   body:@"App cleanup stays inside cache folders. Protected cleanup only stages known CacheDelete leftovers. Rescue only operates inside its dedicated staging folder. Close apps before clearing their cache and review your selection before confirming."
                                  color:UIColor.systemGreenColor];
    [stack addArrangedSubview:safety];

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
    card.layer.cornerRadius = 16.0;
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
    row.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
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
