#import "StorageCleanerIntroViewController.h"

static NSString * const SCIntroSeenKey = @"storageCleaner.onboardingSeen";

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
    stack.layoutMargins = UIEdgeInsetsMake(40.0, 24.0, 30.0, 24.0);
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
    [icon.heightAnchor constraintEqualToConstant:64.0].active = YES;
    [stack addArrangedSubview:icon];

    UILabel *title = [self label:@"Storage Cleaner" style:UIFontTextStyleTitle1 weight:UIFontWeightBold color:UIColor.labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:title];

    UILabel *subtitle = [self label:@"Free temporary storage without digging through every app yourself."
                               style:UIFontTextStyleBody
                              weight:UIFontWeightRegular
                               color:UIColor.secondaryLabelColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:subtitle];

    [stack setCustomSpacing:26.0 afterView:subtitle];

    [stack addArrangedSubview:[self card:@"Automatic access"
                                   body:@"After this guide, Storage Cleaner waits 5 seconds and enables the proven Cyanide/DarkSword access path automatically. Nothing is deleted during access."]];

    [stack addArrangedSubview:[self card:@"Apps & System Cache"
                                   body:@"Apps scans temporary Library/Caches and tmp data app by app. System Cache only shows compatible iOS leftovers when they exist."]];

    [stack addArrangedSubview:[self card:@"You stay in control"
                                   body:@"Select what you want to clean. Close selected apps first and review the list: cleanup is permanent, although apps and iOS can recreate cache later."]];

    UILabel *once = [self label:@"You will only see this guide once after installation. Help and credits remain available from the ••• menu."
                              style:UIFontTextStyleFootnote
                             weight:UIFontWeightRegular
                              color:UIColor.tertiaryLabelColor];
    once.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:once];

    UIButton *continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = @"Continue";
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(14.0, 18.0, 14.0, 18.0);
    continueButton.configuration = configuration;
    [continueButton addTarget:self action:@selector(continueTapped) forControlEvents:UIControlEventTouchUpInside];
    [continueButton.heightAnchor constraintGreaterThanOrEqualToConstant:54.0].active = YES;
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
    if (self.completion) self.completion();
}

+ (BOOL)shouldShow
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:SCIntroSeenKey];
}

@end
