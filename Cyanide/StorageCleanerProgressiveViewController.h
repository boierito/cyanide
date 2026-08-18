#import "StorageRescueCleanupViewController.h"

// The property already exists in StorageRescueDedicatedViewController's private
// implementation. This declaration only exposes its accessor to the progressive
// presentation subclass; it does not add or replace backend state.
@interface StorageRescueDedicatedViewController (StorageCleanerProgressiveState)
@property (nonatomic, copy) NSString *statusText;
@end

@interface StorageCleanerProgressiveViewController : StorageRescueCleanupViewController
@end
