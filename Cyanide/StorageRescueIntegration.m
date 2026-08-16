#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SettingsViewController.h"
#import "StorageRescueSolverViewController.h"

@implementation SettingsViewController (StorageRescueIntegration)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [SettingsViewController class];
        Method original = class_getInstanceMethod(cls, @selector(viewDidLoad));
        Method replacement = class_getInstanceMethod(cls, @selector(sr_viewDidLoad));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)sr_viewDidLoad
{
    [self sr_viewDidLoad];

    UIBarButtonItem *storage = [[UIBarButtonItem alloc]
        initWithTitle:@"Storage"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(sr_openStorageRescue)];
    storage.accessibilityLabel = @"Storage Rescue";

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObject:storage];
    NSArray<UIBarButtonItem *> *existing = self.navigationItem.rightBarButtonItems;
    if (existing.count) {
        for (UIBarButtonItem *item in existing) {
            if (![item.accessibilityLabel isEqualToString:@"Storage Rescue"] &&
                ![item.accessibilityLabel isEqualToString:@"Storage Permission Probe"]) {
                [items addObject:item];
            }
        }
    }
    self.navigationItem.rightBarButtonItems = items;
}

- (void)sr_openStorageRescue
{
    StorageRescueSolverViewController *vc = [[StorageRescueSolverViewController alloc] init];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

@end
