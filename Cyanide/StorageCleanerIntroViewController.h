#import <UIKit/UIKit.h>

@interface StorageCleanerIntroViewController : UIViewController
@property (nonatomic, copy) void (^completion)(void);
+ (BOOL)shouldShow;
@end
