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

    UILabel *title = [self heading:@"How it works" style:UIFontTextStyleTitle2];
    [stack addArrangedSubview:title];

    [stack addArrangedSubview:[self cardWithTitle:@"Apps"
                                           body:@"The app starts storage access automatically, then scans each installed app's Library/Caches and tmp folders. Results appear progressively as each app finishes scanning. Nothing is removed until you select items and confirm cleanup."]];

    [stack addArrangedSubview:[self cardWithTitle:@"System Cache"
                                           body:@"System Cache is intentionally separate from app cache/temp. It shows CacheDelete leftovers already managed by iOS. These entries are not presented as normal apps."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Protected Cleanup"
                                           body:@"Protected Cleanup is not a normal cleaning category. It is the advanced fallback used only when iOS refuses a normal deletion or when System Cache entries have been staged for verified removal. That is why Rescue is no longer a main tab."]];

    [stack setCustomSpacing:24.0 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:[self heading:@"FAQ" style:UIFontTextStyleTitle3]];

    [stack addArrangedSubview:[self cardWithTitle:@"What can be deleted?"
                                           body:@"For apps, only Library/Caches and tmp are in scope. Photos, documents, messages, credentials, user-created files and normal application data are outside the app-cleaning path."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Why does access start automatically?"
                                           body:@"The cleaner cannot inspect the relevant storage paths until the existing Cyanide/DarkSword access flow succeeds. The same backend is used as before; the new UI only starts it automatically when the cleaner opens."]];

    [stack addArrangedSubview:[self cardWithTitle:@"Why can scanning still take time?"
                                           body:@"Some apps contain tens of thousands of files. The cleaner now scans several app containers concurrently and inserts each completed result immediately instead of waiting for every app to finish."]];

    [stack addArrangedSubview:[self cardWithTitle:@"How do sorting and search work?"
                                           body:@"Use the sort control to order by size or name, in either direction. Search matches application names and bundle identifiers. Pull down on the list to rescan."]];

    [stack addArrangedSubview:[self cardWithTitle:@"What happens if normal deletion is denied?"
                                           body:@"The original protected cleanup path remains available from the More menu. It keeps the solver and low-level backend separate from the normal browsing experience."]];

    [stack setCustomSpacing:24.0 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:[self heading:@"Credits" style:UIFontTextStyleTitle3]];

    NSString *credits = @"zeroxjf — Cyanide project and integration work this fork derives from.\n\n"
                         "opa334 — original DarkSword kernel exploit work, ChOma and XPF components.\n\n"
                         "wh1te4ever — darksword-kexploit-fun / RemoteCall work used by Cyanide.\n\n"
                         "rooootdev — exploit behavior referenced by Cyanide for reliability work.\n\n"
                         "YangJiiii / 3105 — reference for the deliberately limited per-app cache-cleaner model.\n\n"
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
