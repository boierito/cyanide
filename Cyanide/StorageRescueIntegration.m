#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SettingsViewController.h"
#import "StorageRescueViewController.h"
#import "StorageRescueProbeViewController.h"

// Small UI-only integration layer. Keeping this separate from
// SettingsViewController.m makes Storage Rescue easy to remove and avoids
// coupling the recovery code to Cyanide's large settings implementation.
@implementation SettingsViewController (StorageRescueIntegration)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [SettingsViewController class];
        Method original = class_getInstanceMethod(cls, @selector(viewDidLoad));
        Method replacement = class_getInstanceMethod(cls, @selector(sr_viewDidLoad));
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
        }
    });
}

- (void)sr_viewDidLoad
{
    // Calls Cyanide's original -viewDidLoad after method swizzling.
    [self sr_viewDidLoad];

    UIBarButtonItem *storage = [[UIBarButtonItem alloc]
        initWithTitle:@"Storage"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(sr_openStorageRescue)];
    storage.accessibilityLabel = @"Storage Rescue";

    UIBarButtonItem *probe = [[UIBarButtonItem alloc]
        initWithTitle:@"Probe"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(sr_openStorageProbe)];
    probe.accessibilityLabel = @"Storage Permission Probe";

    // Preserve Cyanide's existing right-side Respring button.
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObjects:storage, probe, nil];

    NSArray<UIBarButtonItem *> *existing = self.navigationItem.rightBarButtonItems;
    if (existing.count > 0) {
        for (UIBarButtonItem *item in existing) {
            if (![item.accessibilityLabel isEqualToString:@"Storage Rescue"] &&
                ![item.accessibilityLabel isEqualToString:@"Storage Permission Probe"]) {
                [items addObject:item];
            }
        }
    } else if (self.navigationItem.rightBarButtonItem &&
               self.navigationItem.rightBarButtonItem != storage &&
               self.navigationItem.rightBarButtonItem != probe) {
        [items addObject:self.navigationItem.rightBarButtonItem];
    }

    self.navigationItem.rightBarButtonItems = items;
}

- (void)sr_openStorageRescue
{
    StorageRescueViewController *vc = [[StorageRescueViewController alloc] init];

    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)sr_openStorageProbe
{
    StorageRescueProbeViewController *vc = [[StorageRescueProbeViewController alloc] init];

    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

@end
