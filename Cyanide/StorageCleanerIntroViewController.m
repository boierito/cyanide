#import "StorageCleanerIntroViewController.h"

static NSString * const SCIntroSeenKey = @"storageCleaner.introSeen.1_2_1_fix";

@implementation StorageCleanerIntroViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    stack.layoutMargins = UIEdgeInsetsMake(28.0, 22.0, 28.0, 22.0);
    stack.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:stack];

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

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"externaldrive.badge.checkmark"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.systemBlueColor;
    [icon.heightAnchor constraintEqualToConstant:58.0].active = YES;
    [stack addArrangedSubview:icon];

    UILabel *title = [self label:@"Storage Cleaner" style:UIFontTextStyleTitle1 weight:UIFontWeightBold color:UIColor.labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:title];

    UILabel *subtitle = [self label:@"Free temporary storage without touching your personal files."
                               style:UIFontTextStyleBody
                              weight:UIFontWeightRegular
                               color:UIColor.secondaryLabelColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:subtitle];

    [stack setCustomSpacing:24.0 afterView:subtitle];

    [stack addArrangedSubview:[self card:@"1. Enable Access"
                                   body:@"Required once after opening the app. It enables scanning; nothing is deleted yet."]];
    [stack addArrangedSubview:[self card:@"2. Review Apps or System Cache"
                                   body:@"Apps shows temporary cache app by app. System Cache appears only when iOS has compatible leftovers."]];
    [stack addArrangedSubview:[self card:@"3. Select and Clean"
                                   body:@"Choose exactly what you want to remove, then confirm the cleanup."]];

    [stack addArrangedSubview:[self card:@"Before you clean"
                                   body:@"Close the apps you select, review the list carefully, and remember that cleanup is permanent. Cache may be recreated later."]];

    UIButton *continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = @"Continue";
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(13.0, 18.0, 13.0, 18.0);
    continueButton.configuration = configuration;
    [continueButton addTarget:self action:@selector(continueTapped) forControlEvents:UIControlEventTouchUpInside];
    [continueButton.heightAnchor constraintGreaterThanOrEqualToConstant:52.0].active = YES;
    [stack addArrangedSubview:continueButton];
}

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style weight:(UIFontWeight)weight color:(UIColor *)color
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    UIFont *preferred = [UIFont preferredFontForTextStyle:style];
    label.font = [UIFont systemFontOfSize:preferred.pointSize weight:weight];
    label.text = text;
    label.textColor = color;
    label.numberOfLines = 0;
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (UIView *)card:(NSString *)title body:(NSString *)body
{
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *titleLabel = [self label:title style:UIFontTextStyleHeadline weight:UIFontWeightSemibold color:UIColor.labelColor];
    UILabel *bodyLabel = [self label:body style:UIFontTextStyleSubheadline weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, bodyLabel]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 5.0;
    content.layoutMargins = UIEdgeInsetsMake(15.0, 16.0, 15.0, 16.0);
    content.layoutMarginsRelativeArrangement = YES;
    [card addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:card.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    return card;
}

- (void)continueTapped
{
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:SCIntroSeenKey];
    [self dismissViewControllerAnimated:YES completion:nil];
}

+ (BOOL)shouldShow
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:SCIntroSeenKey];
}

@end
