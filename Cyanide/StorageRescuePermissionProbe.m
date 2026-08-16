#import "StorageRescueViewController.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/kutils.h"
#import "kexploit/krw.h"
#import "kexploit/offsets.h"
#import "utils/sandbox.h"

#import <objc/runtime.h>
#import <errno.h>
#import <string.h>
#import <unistd.h>

static const void *SRProbeBusyKey = &SRProbeBusyKey;

@interface StorageRescueViewController (StorageRescueProbePrivate)
- (NSString *)firstFileUnderTarget;
- (void)appendLog:(NSString *)line;
- (void)setBusy:(BOOL)busy status:(NSString *)status;
@end

@implementation StorageRescueViewController (StorageRescuePermissionProbe)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(viewWillAppear:));
        Method replacement = class_getInstanceMethod(self, @selector(sr_probe_viewWillAppear:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)sr_probe_viewWillAppear:(BOOL)animated
{
    [self sr_probe_viewWillAppear:animated];

    UIBarButtonItem *probe = [[UIBarButtonItem alloc] initWithTitle:@"Probe"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(sr_probeUnlinkPermissions)];
    probe.accessibilityLabel = @"Probe file-write-unlink permissions";

    UIBarButtonItem *existing = self.navigationItem.rightBarButtonItem;
    if (existing && existing != probe) {
        self.navigationItem.rightBarButtonItems = @[probe, existing];
    } else {
        self.navigationItem.rightBarButtonItem = probe;
    }
}

- (void)sr_probeShow:(NSString *)title message:(NSString *)message
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    });
}

- (void)sr_probeUnlinkPermissions
{
    if ([objc_getAssociatedObject(self, SRProbeBusyKey) boolValue]) return;

    if (!kexploit_krw_ready()) {
        [self sr_probeShow:@"Prepare Access First"
                   message:@"The permission probe only reads process metadata, but it needs the existing KRW session to resolve system PIDs. Run Prepare Access first."];
        return;
    }

    NSString *file = [self firstFileUnderTarget];
    if (!file.length || ![file hasPrefix:@"/var/mobile/Documents/test/"]) {
        [self sr_probeShow:@"No Test File" message:@"Could not find a file under /var/mobile/Documents/test."];
        return;
    }

    objc_setAssociatedObject(self, SRProbeBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setBusy:YES status:@"Probing unlink permissions…"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            [self appendLog:[NSString stringWithFormat:@"Permission probe only — no deletion. Path: %@", file]];
            [self appendLog:@"Checking file-read-data / file-write-data / file-write-unlink for candidate system processes…"];

            struct Candidate { const char *name; } candidates[] = {
                { "Cyanide" },
                { "SpringBoard" },
                { "deleted" },
                { "installd" },
                { "containermanagerd" },
                { "mobileassetd" },
                { "runningboardd" },
                { "nsurlsessiond" },
                { "storagekitd" },
                { "cfprefsd" },
            };

            NSUInteger found = 0;
            NSUInteger unlinkAllowed = 0;

            for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
                const char *name = candidates[i].name;
                uint64_t proc = proc_find_by_name(name);
                if (!proc || !is_kaddr_valid(proc)) {
                    [self appendLog:[NSString stringWithFormat:@"%-18s  not running / not found", name]];
                    continue;
                }

                pid_t pid = (pid_t)kread32(proc + off_proc_p_pid);
                if (pid <= 0) {
                    [self appendLog:[NSString stringWithFormat:@"%-18s  invalid pid", name]];
                    continue;
                }
                found++;

                errno = 0;
                int rd = sandbox_check(pid,
                                       "file-read-data",
                                       SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT,
                                       file.fileSystemRepresentation);
                int rdErr = errno;

                errno = 0;
                int wr = sandbox_check(pid,
                                       "file-write-data",
                                       SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT,
                                       file.fileSystemRepresentation);
                int wrErr = errno;

                errno = 0;
                int ul = sandbox_check(pid,
                                       "file-write-unlink",
                                       SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT,
                                       file.fileSystemRepresentation);
                int ulErr = errno;

                NSString *rdText = rd == 0 ? @"ALLOW" : (rd > 0 ? @"DENY" : @"ERROR");
                NSString *wrText = wr == 0 ? @"ALLOW" : (wr > 0 ? @"DENY" : @"ERROR");
                NSString *ulText = ul == 0 ? @"ALLOW" : (ul > 0 ? @"DENY" : @"ERROR");
                if (ul == 0) unlinkAllowed++;

                [self appendLog:[NSString stringWithFormat:@"%-18s pid=%d  read=%@ write=%@ unlink=%@  rc=(%d,%d,%d) errno=(%d,%d,%d)",
                                 name, pid, rdText, wrText, ulText,
                                 rd, wr, ul, rdErr, wrErr, ulErr]];
            }

            [self appendLog:[NSString stringWithFormat:@"Probe complete: %lu candidates found; %lu report file-write-unlink ALLOW.",
                             (unsigned long)found, (unsigned long)unlinkAllowed]];

            if (unlinkAllowed == 0) {
                [self appendLog:@"No tested process reports unlink permission. Do not run another remote unlink yet."];
                [self setBusy:NO status:@"No unlink-capable candidate"];
            } else {
                [self appendLog:@"At least one process reports unlink ALLOW. Next step should target only that process with one-file verification."];
                [self setBusy:NO status:@"Unlink candidate found"];
            }

            objc_setAssociatedObject(self, SRProbeBusyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

@end
