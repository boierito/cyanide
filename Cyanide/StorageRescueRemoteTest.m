#import "StorageRescueViewController.h"
#import "kexploit/kexploit_opa334.h"
#import "utils/sandbox.h"
#import "TaskRop/RemoteCall.h"
#import "tweaks/remote_objc.h"

#import <objc/runtime.h>
#import <sys/stat.h>
#import <errno.h>
#import <string.h>

static NSString * const SRRemoteRootPath = @"/var/mobile/Documents/test";
static const void *SRRemoteBusyKey = &SRRemoteBusyKey;

// Private methods implemented by StorageRescueViewController.m.  Keeping this
// test in a category lets us add the diagnostic without changing the known-good
// local scan/prepare implementation.
@interface StorageRescueViewController (StorageRescueRemotePrivate)
- (NSString *)firstFileUnderTarget;
- (void)appendLog:(NSString *)line;
- (void)setBusy:(BOOL)busy status:(NSString *)status;
@end

static BOOL SRRemotePathAllowed(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    if ([path containsString:@".."]) return NO;
    NSString *safe = [path stringByStandardizingPath];
    return [safe hasPrefix:[SRRemoteRootPath stringByAppendingString:@"/"]];
}

static uint64_t SRRemoteAllocatedBytes(const struct stat *st)
{
    return st ? (uint64_t)st->st_blocks * 512ULL : 0;
}

static NSString *SRRemoteFormatBytes(uint64_t bytes)
{
    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;
    fmt.allowedUnits = NSByteCountFormatterUseKB | NSByteCountFormatterUseMB | NSByteCountFormatterUseGB;
    return [fmt stringFromByteCount:(long long)bytes];
}

@implementation StorageRescueViewController (StorageRescueRemoteTest)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(viewDidLoad));
        Method replacement = class_getInstanceMethod(self, @selector(sr_remote_viewDidLoad));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)sr_remote_viewDidLoad
{
    // Calls the original viewDidLoad after swizzling.
    [self sr_remote_viewDidLoad];

    UIBarButtonItem *remote = [[UIBarButtonItem alloc] initWithTitle:@"Remote unlink"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(sr_testRemoteUnlink)];
    remote.accessibilityLabel = @"Test unlink from SpringBoard";
    self.navigationItem.rightBarButtonItem = remote;

    [self appendLog:@"Remote diagnostic available: top-right ‘Remote unlink’. It performs one SpringBoard libc unlink() only; no kernel sandbox patching."];
}

- (void)sr_showRemoteMessage:(NSString *)title message:(NSString *)message
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    });
}

- (void)sr_testRemoteUnlink
{
    if ([objc_getAssociatedObject(self, SRRemoteBusyKey) boolValue]) return;

    // RemoteCall requires a live KRW session.  Do not run the exploit here:
    // the user must explicitly complete Prepare Access first.
    if (!kexploit_krw_ready() || check_sandbox_var_rw() != 0) {
        [self sr_showRemoteMessage:@"Prepare Access First"
                           message:@"Run Prepare Access successfully before Remote unlink. This button will not start KRW or alter the sandbox automatically."];
        return;
    }

    objc_setAssociatedObject(self, SRRemoteBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setBusy:YES status:@"Testing SpringBoard unlink…"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *file = [self firstFileUnderTarget];
            if (!SRRemotePathAllowed(file)) {
                [self appendLog:@"Remote unlink aborted: no safe file was found under /var/mobile/Documents/test."];
                objc_setAssociatedObject(self, SRRemoteBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self setBusy:NO status:@"Remote test aborted"];
                return;
            }

            struct stat before;
            memset(&before, 0, sizeof(before));
            errno = 0;
            if (lstat(file.fileSystemRepresentation, &before) != 0) {
                int le = errno;
                [self appendLog:[NSString stringWithFormat:@"Remote unlink aborted: lstat errno=%d (%s): %@",
                                 le, strerror(le), file]];
                objc_setAssociatedObject(self, SRRemoteBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self setBusy:NO status:@"Remote test aborted"];
                return;
            }

            [self appendLog:[NSString stringWithFormat:@"Opening isolated RemoteCall session to SpringBoard for one unlink(): %@ (%@ allocated).",
                             file, SRRemoteFormatBytes(SRRemoteAllocatedBytes(&before))]];

            RemoteCallSession *session = [[RemoteCallSession alloc] initWithProcess:@"SpringBoard"
                                                                useMigFilterBypass:NO
                                                           firstExceptionTimeoutMS:3000];
            if (!session || ![session hasLocalState] || session.pid <= 0) {
                [self appendLog:@"Remote unlink failed before syscall: could not establish SpringBoard RemoteCall session."];
                if (session) [session abandonRemoteCall];
                objc_setAssociatedObject(self, SRRemoteBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self setBusy:NO status:@"RemoteCall failed"];
                return;
            }

            [self appendLog:[NSString stringWithFormat:@"RemoteCall ready: SpringBoard pid=%d.", session.pid]];

            uint64_t remotePath = r_session_alloc_str(session, file.fileSystemRepresentation);
            if (!remotePath) {
                [self appendLog:@"Remote unlink failed: could not allocate remote path string."];
                [session destroyRemoteCall];
                objc_setAssociatedObject(self, SRRemoteBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self setBusy:NO status:@"Remote allocation failed"];
                return;
            }

            uint64_t raw = r_session_dlsym_call(session, R_TIMEOUT, "unlink",
                                                remotePath, 0, 0, 0, 0, 0, 0, 0);
            int rc = (int32_t)(uint32_t)raw;

            // errno is diagnostic only.  The definitive test is whether lstat
            // can still see the path after unlink returns.
            int remoteErrno = 0;
            if (rc != 0) {
                uint64_t errnoPtr = r_session_dlsym_call(session, R_TIMEOUT, "__error",
                                                         0, 0, 0, 0, 0, 0, 0, 0);
                if (errnoPtr) [session remoteRead:errnoPtr to:&remoteErrno size:sizeof(remoteErrno)];
            }

            r_session_free(session, remotePath);
            int destroyRC = [session destroyRemoteCall];

            struct stat after;
            memset(&after, 0, sizeof(after));
            errno = 0;
            int statRC = lstat(file.fileSystemRepresentation, &after);
            int statErr = errno;
            BOOL gone = (statRC != 0 && statErr == ENOENT);

            [self appendLog:[NSString stringWithFormat:@"SpringBoard unlink() rc=%d remoteErrno=%d (%s), existsAfter=%@, destroyRC=%d.",
                             rc,
                             remoteErrno,
                             remoteErrno ? strerror(remoteErrno) : "none",
                             gone ? @"NO" : @"YES",
                             destroyRC]];

            if (rc == 0 && gone) {
                [self appendLog:@"SUCCESS: direct SpringBoard unlink() removed the file. Do not run full delete yet; this build only proves the primitive."];
                [self setBusy:NO status:@"Remote unlink verified"];
            } else {
                [self appendLog:@"Remote unlink did not remove the file. No further fallback was attempted."];
                [self setBusy:NO status:@"Remote unlink denied"];
            }

            objc_setAssociatedObject(self, SRRemoteBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

@end
