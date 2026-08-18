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

    [stack addArrangedSubview:[self cardWithTitle:@"1. Automatic Access"
                                           body:@"After Storage Cleaner appears, a five-second loading screen starts Gain Access automatically. Nothing is deleted during this step."]];

    [stack addArrangedSubview:[self cardWithTitle:@"2. Apps"
                                           body:@"Apps scans only Library/Caches and tmp. Results appear progressively as each app finishes so you can see scan progress without waiting for the whole device."]];

    [stack addArrangedSubview:[self cardWithTitle:@"3. System Cache"
                                           body:@"System Cache is separate from app cache. It shows compatible CacheDelete leftovers only when iOS has created them. An empty list means there is currently nothing compatible there."]];

    [stack addArrangedSubview:[self cardWithTitle:@"4. Select and Clean"
                                           body:@"Choose the entries you want, review the selected size, then confirm. App cleanup updates each row as it finishes instead of waiting for a full rescan."]];

    [stack setCustomSpacing:24.0 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:[self heading:@"FAQ" style:UIFontTextStyleTitle3]];

    [stack addArrangedSubview:[self cardWithTitle:@"What can App cleanup delete?"
                                           body:@"Only Library/Caches and tmp inside validated application containers. Photos, documents, messages, credentials and normal application data are outside the app-cleaning path."]];

    [stack addArrangedSubview:[self cardWithTitle:@"What happens during the five-second wait?"
                                           body:@"Only the loading interface and a main-thread countdown run. Extra filesystem enumeration and application-name lookup wait until Gain Access and the initial scan are finished."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Why do results appear one by one?"
                                           body:@"Some applications contain many thousands of files. Storage Cleaner scans a few containers concurrently and publishes each completed result immediately."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Why might System Cache be empty?"
                                           body:@"The CacheDelete leftovers directory is managed by iOS and is not guaranteed to exist. Storage Cleaner never creates fake system-cache entries just to populate the list."]];

    [stack addArrangedSubview:[self cardWithTitle:@"How are real app names found?"
                                           body:@"After access and the initial scan are idle, Storage Cleaner reads installed app bundle metadata and falls back to LaunchServices. Until then it does not start the extra name catalog."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Where did Protected Cleanup go?"
                                           body:@"The standalone Protected Cleanup screen is not exposed as a normal mode. The proven recovery backend remains available contextually when a selected item genuinely needs it."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Before cleaning"
                                           body:@"Close the apps you select, review the list carefully, and remember that cleanup is permanent. Apps and iOS can recreate temporary cache later."]];

    [stack setCustomSpacing:24.0 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:[self heading:@"Credits" style:UIFontTextStyleTitle3]];

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
