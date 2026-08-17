#import "StorageRescueHomeViewController.h"
#import "StorageRescueCleanupViewController.h"
#import "StorageRescueGuideViewController.h"

@interface StorageRescueHomeViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@end

@implementation StorageRescueHomeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Storage Rescue";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];
    self.scrollView = scrollView;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 14.0;
    stack.layoutMargins = UIEdgeInsetsMake(28.0, 20.0, 34.0, 20.0);
    stack.layoutMarginsRelativeArrangement = YES;
    [scrollView addSubview:stack];
    self.contentStack = stack;

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
    ]];

    UIImageView *heroIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"externaldrive.badge.checkmark"]];
    heroIcon.translatesAutoresizingMaskIntoConstraints = NO;
    heroIcon.contentMode = UIViewContentModeScaleAspectFit;
    heroIcon.tintColor = UIColor.systemBlueColor;
    [heroIcon.heightAnchor constraintEqualToConstant:60.0].active = YES;
    [stack addArrangedSubview:heroIcon];

    UILabel *titleLabel = [self labelWithText:@"Recover storage safely"
                                        style:UIFontTextStyleTitle1
                                       weight:UIFontWeightBold
                                        color:UIColor.labelColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:titleLabel];

    UILabel *subtitle = [self labelWithText:@"Find temporary app cache and iOS leftovers, review what is taking space, then choose exactly what to clean."
                                      style:UIFontTextStyleBody
                                     weight:UIFontWeightRegular
                                      color:UIColor.secondaryLabelColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:subtitle];

    [stack setCustomSpacing:24.0 afterView:subtitle];

    UIButton *startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *startConfiguration = [UIButtonConfiguration filledButtonConfiguration];
    startConfiguration.title = @"Start Cleanup";
    startConfiguration.image = [UIImage systemImageNamed:@"arrow.right.circle.fill"];
    startConfiguration.imagePlacement = NSDirectionalRectEdgeTrailing;
    startConfiguration.imagePadding = 8.0;
    startConfiguration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    startConfiguration.baseBackgroundColor = UIColor.systemBlueColor;
    startConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(14.0, 18.0, 14.0, 18.0);
    startButton.configuration = startConfiguration;
    startButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [startButton addTarget:self action:@selector(startTapped) forControlEvents:UIControlEventTouchUpInside];
    [startButton.heightAnchor constraintGreaterThanOrEqualToConstant:54.0].active = YES;
    [stack addArrangedSubview:startButton];

    UIButton *helpButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *helpConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    helpConfiguration.title = @"How Storage Rescue works";
    helpConfiguration.image = [UIImage systemImageNamed:@"info.circle"];
    helpConfiguration.imagePadding = 7.0;
    helpButton.configuration = helpConfiguration;
    [helpButton addTarget:self action:@selector(helpTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:helpButton];

    [stack setCustomSpacing:24.0 afterView:helpButton];

    UILabel *sectionTitle = [self labelWithText:@"A simple three-step flow"
                                          style:UIFontTextStyleHeadline
                                         weight:UIFontWeightSemibold
                                          color:UIColor.labelColor];
    [stack addArrangedSubview:sectionTitle];

    [stack addArrangedSubview:[self stepCardWithNumber:@"1"
                                                 icon:@"shield.lefthalf.filled"
                                                title:@"Enable access"
                                                 body:@"Required once after opening the app. This step only enables scanning; it does not delete anything."
                                                color:UIColor.systemBlueColor]];

    [stack addArrangedSubview:[self stepCardWithNumber:@"2"
                                                 icon:@"magnifyingglass"
                                                title:@"Review storage"
                                                 body:@"Storage Rescue measures removable cache and shows the largest items first. You decide what to select."
                                                color:UIColor.systemIndigoColor]];

    [stack addArrangedSubview:[self stepCardWithNumber:@"3"
                                                 icon:@"trash.fill"
                                                title:@"Clean what you selected"
                                                 body:@"Normal app cache is removed directly. Protected leftovers are sent through Rescue only when that extra step is needed."
                                                color:UIColor.systemOrangeColor]];

    [stack setCustomSpacing:22.0 afterView:stack.arrangedSubviews.lastObject];

    UIView *safetyCard = [self infoCardWithIcon:@"checkmark.shield.fill"
                                         title:@"What stays untouched"
                                          body:@"App cleanup is limited to temporary cache folders. Photos, documents, messages, logins and normal app data are outside the cleanup scope."
                                         color:UIColor.systemGreenColor];
    [stack addArrangedSubview:safetyCard];

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    UILabel *versionLabel = [self labelWithText:[NSString stringWithFormat:@"Version %@ (%@)", version, build]
                                          style:UIFontTextStyleCaption1
                                         weight:UIFontWeightRegular
                                          color:UIColor.tertiaryLabelColor];
    versionLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:versionLabel];
}

- (UILabel *)labelWithText:(NSString *)text
                     style:(UIFontTextStyle)style
                    weight:(UIFontWeight)weight
                     color:(UIColor *)color
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

- (UIView *)stepCardWithNumber:(NSString *)number
                         icon:(NSString *)iconName
                        title:(NSString *)title
                         body:(NSString *)body
                        color:(UIColor *)color
{
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 18.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *numberLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    numberLabel.translatesAutoresizingMaskIntoConstraints = NO;
    numberLabel.text = number;
    numberLabel.textAlignment = NSTextAlignmentCenter;
    numberLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
    numberLabel.textColor = UIColor.whiteColor;
    numberLabel.backgroundColor = color;
    numberLabel.layer.cornerRadius = 13.0;
    numberLabel.layer.masksToBounds = YES;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = color;
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *titleLabel = [self labelWithText:title
                                        style:UIFontTextStyleHeadline
                                       weight:UIFontWeightSemibold
                                        color:UIColor.labelColor];
    UILabel *bodyLabel = [self labelWithText:body
                                       style:UIFontTextStyleSubheadline
                                      weight:UIFontWeightRegular
                                       color:UIColor.secondaryLabelColor];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, bodyLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 4.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[numberLabel, icon, textStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 11.0;
    row.layoutMargins = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    row.layoutMarginsRelativeArrangement = YES;
    [card addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [numberLabel.widthAnchor constraintEqualToConstant:26.0],
        [numberLabel.heightAnchor constraintEqualToConstant:26.0],
        [icon.widthAnchor constraintEqualToConstant:26.0],
        [icon.heightAnchor constraintEqualToConstant:26.0],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:card.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    return card;
}

- (UIView *)infoCardWithIcon:(NSString *)iconName
                       title:(NSString *)title
                        body:(NSString *)body
                       color:(UIColor *)color
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
                                        style:UIFontTextStyleHeadline
                                       weight:UIFontWeightSemibold
                                        color:UIColor.labelColor];
    UILabel *bodyLabel = [self labelWithText:body
                                       style:UIFontTextStyleSubheadline
                                      weight:UIFontWeightRegular
                                       color:UIColor.secondaryLabelColor];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, bodyLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 4.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, textStack]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 12.0;
    row.layoutMargins = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
    row.layoutMarginsRelativeArrangement = YES;
    [card addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:28.0],
        [icon.heightAnchor constraintEqualToConstant:28.0],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:card.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    return card;
}

- (void)startTapped
{
    StorageRescueCleanupViewController *cleanup = [[StorageRescueCleanupViewController alloc] init];
    [self.navigationController pushViewController:cleanup animated:YES];
}

- (void)helpTapped
{
    StorageRescueGuideViewController *guide = [[StorageRescueGuideViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:guide];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

@end
