//
//  SceneDelegate.m
//  Storage Cleaner 2.0 experimental branch
//

#import "SceneDelegate.h"
#import "StorageCleanerFullscreenStartupViewController.h"
#import "StorageCleanerIntroViewController.h"

@implementation SceneDelegate

- (UINavigationController *)storageCleanerNavigationController
{
    StorageCleanerFullscreenStartupViewController *root = [[StorageCleanerFullscreenStartupViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:root];
    navigation.navigationBar.prefersLargeTitles = YES;
    return navigation;
}

- (void)scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions
{
    if (![scene isKindOfClass:UIWindowScene.class]) return;

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];

    if ([StorageCleanerIntroViewController shouldShow]) {
        StorageCleanerIntroViewController *intro = [[StorageCleanerIntroViewController alloc] init];
        __weak typeof(self) weakSelf = self;
        intro.completion = ^{
            UIWindow *window = weakSelf.window;
            if (!window) return;
            UIViewController *cleaner = [weakSelf storageCleanerNavigationController];
            [UIView transitionWithView:window
                              duration:0.25
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{
                window.rootViewController = cleaner;
            } completion:nil];
        };
        self.window.rootViewController = intro;
    } else {
        self.window.rootViewController = [self storageCleanerNavigationController];
    }

    [self.window makeKeyAndVisible];
}

- (void)sceneDidDisconnect:(UIScene *)scene {}
- (void)sceneDidBecomeActive:(UIScene *)scene {}
- (void)sceneWillResignActive:(UIScene *)scene {}
- (void)sceneWillEnterForeground:(UIScene *)scene {}
- (void)sceneDidEnterBackground:(UIScene *)scene {}

@end
