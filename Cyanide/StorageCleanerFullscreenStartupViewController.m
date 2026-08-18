#import "StorageCleanerFullscreenStartupViewController.h"

@implementation StorageCleanerFullscreenStartupViewController

// Keep the known-good 1.2.2 automatic Gain Access flow untouched. This subclass
// only changes where the startup overlay is hosted so underlying controls cannot
// bleed through while the five-second countdown / access phase is visible.
- (void)scShowStartupOverlay
{
    UIView *existing = [self valueForKey:@"scStartupOverlay"];
    if (existing) return;

    UIWindow *window = self.view.window ?: self.navigationController.view.window;
    UIView *host = window ?: self.navigationController.view ?: self.view;
    if (!host) return;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = UIColor.systemBackgroundColor;
    overlay.accessibilityViewIsModal = YES;
    overlay.userInteractionEnabled = YES;
    [host addSubview:overlay];
    [host bringSubviewToFront:overlay];
    [self setValue:overlay forKey:@"scStartupOverlay"];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"externaldrive.badge.checkmark"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.systemBlueColor;
    [icon.heightAnchor constraintEqualToConstant:64.0].active = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.text = @"Storage Cleaner";
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *descriptionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    descriptionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    descriptionLabel.textColor = UIColor.secondaryLabelColor;
    descriptionLabel.numberOfLines = 0;
    descriptionLabel.textAlignment = NSTextAlignmentCenter;
    descriptionLabel.text = @"Scans temporary app cache and compatible iOS cache. Nothing is deleted automatically.";

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    [spinner startAnimating];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    status.textAlignment = NSTextAlignmentCenter;
    status.text = @"Getting ready…";
    [self setValue:status forKey:@"scStartupStatusLabel"];

    UILabel *countdown = [[UILabel alloc] initWithFrame:CGRectZero];
    countdown.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    countdown.textColor = UIColor.secondaryLabelColor;
    countdown.textAlignment = NSTextAlignmentCenter;
    [self setValue:countdown forKey:@"scStartupCountdownLabel"];

    UILabel *warning = [[UILabel alloc] initWithFrame:CGRectZero];
    warning.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    warning.textColor = UIColor.tertiaryLabelColor;
    warning.numberOfLines = 0;
    warning.textAlignment = NSTextAlignmentCenter;
    warning.text = @"Close apps before cleaning them. Cleanup is permanent, but apps and iOS may recreate cache later.";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon,
        title,
        descriptionLabel,
        spinner,
        status,
        countdown,
        warning,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;
    [overlay addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:host.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],

        [stack.leadingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.leadingAnchor constant:28.0],
        [stack.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor constant:-28.0],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.centerYAnchor],
    ]];
}

- (void)scDismissStartupOverlay
{
    UIView *overlay = [self valueForKey:@"scStartupOverlay"];
    if (!overlay) return;

    [self setValue:nil forKey:@"scStartupOverlay"];
    [self setValue:nil forKey:@"scStartupStatusLabel"];
    [self setValue:nil forKey:@"scStartupCountdownLabel"];

    [UIView animateWithDuration:0.20 animations:^{
        overlay.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

@end
