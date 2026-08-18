#import "StorageRescueGuideViewController.h"

@interface StorageRescueGuideViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@end

@implementation StorageRescueGuideViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Help & Credits";
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
    stack.spacing = 12.0;
    stack.layoutMargins = UIEdgeInsetsMake(22.0, 20.0, 34.0, 20.0);
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

    [stack addArrangedSubview:[self heading:@"How it works" style:UIFontTextStyleTitle2]];

    [stack addArrangedSubview:[self cardWithTitle:@"Automatic Access"
                                           body:@"On normal launches, Storage Cleaner waits five seconds and enables the existing Cyanide/DarkSword access path automatically. Nothing is deleted during this step."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Apps"
                                           body:@"Scans temporary Library/Caches and tmp data app by app. Results appear progressively instead of waiting for the whole device scan."]];

    [stack addArrangedSubview:[self cardWithTitle:@"System Cache"
                                           body:@"Shows compatible iOS CacheDelete leftovers only when they exist. An empty list is normal."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Clean"
                                           body:@"Select the entries you want, review the selected size, then confirm. Close selected apps first."]];

    [stack setCustomSpacing:24.0 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:[self heading:@"FAQ" style:UIFontTextStyleTitle3]];

    [stack addArrangedSubview:[self cardWithTitle:@"What can Apps remove?"
                                           body:@"Only Library/Caches and tmp inside validated app containers. Photos, documents, messages, credentials and normal app data are outside this path."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Why do results appear one by one?"
                                           body:@"Some apps contain thousands of files. Storage Cleaner scans a small number of containers concurrently and publishes each completed result immediately."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Why might System Cache be empty?"
                                           body:@"That directory is managed by iOS and may not exist or may contain nothing removable. Storage Cleaner does not create artificial entries."]];

    [stack addArrangedSubview:[self cardWithTitle:@"How are app names found?"
                                           body:@"After Gain Access and the initial scan are idle, Storage Cleaner reads installed app metadata and falls back to LaunchServices. Extra name lookup does not run during Gain Access."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Before cleaning"
                                           body:@"Cleanup is permanent. Apps and iOS can recreate temporary cache later, but you should still close selected apps and review the list first."]];

    [stack setCustomSpacing:24.0 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:[self heading:@"Credits" style:UIFontTextStyleTitle3]];

    [stack addArrangedSubview:[self cardWithTitle:@"Storage Cleaner"
                                           body:@"Lucas Boiero — @boierito on GitHub. Product direction, integration and this Storage Cleaner fork."]];

    NSString *credits = @"zeroxjf — Cyanide project and integration work this fork derives from.\n\n"
                         "opa334 — original DarkSword kernel exploit work, ChOma and XPF components.\n\n"
                         "wh1te4ever — darksword-kexploit-fun / RemoteCall work used by Cyanide.\n\n"
                         "rooootdev — exploit behavior referenced by Cyanide for reliability work.\n\n"
                         "YangJiiii / 3105 — reference for the limited per-app cleaner and progressive scan model.\n\n"
                         "Cyanide upstream contributors and the researchers credited in the original project history.";
    [stack addArrangedSubview:[self cardWithTitle:@"Upstream & research" body:credits]];

    [stack addArrangedSubview:[self cardWithTitle:@"AI Slop Disclosure"
                                           body:@"Yes, this is AI Slop. The current product/UI iteration was made with GPT-5.6 Sol. The underlying Cyanide, DarkSword, XPF, ChOma and 3105 work remains credited above."]];

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"?";
    UILabel *versionLabel = [self labelWithText:[NSString stringWithFormat:@"Storage Cleaner %@ (%@)\n%@", version, build, bundleID]
                                            font:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]
                                           color:UIColor.tertiaryLabelColor];
    versionLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:versionLabel];
}

- (UILabel *)heading:(NSString *)text style:(UIFontTextStyle)style
{
    UILabel *label = [self labelWithText:text
                                    font:[UIFont preferredFontForTextStyle:style]
                                   color:UIColor.labelColor];
    label.font = [UIFont systemFontOfSize:label.font.pointSize weight:UIFontWeightBold];
    return label;
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

- (UIView *)cardWithTitle:(NSString *)title body:(NSString *)body
{
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *titleLabel = [self labelWithText:title
                                         font:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]
                                        color:UIColor.labelColor];
    UILabel *bodyLabel = [self labelWithText:body
                                        font:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]
                                       color:UIColor.secondaryLabelColor];

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

- (void)doneTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
