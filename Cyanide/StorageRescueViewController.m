#import "StorageRescueViewController.h"
#import "kexploit/kexploit_opa334.h"
#import "utils/sandbox.h"

#import <dirent.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>
#import <string.h>

// Existing Cyanide sandbox escape from ViewController.m:
// SpringBoard issues a com.apple.app-sandbox.read-write token for "/" and
// Cyanide consumes that token in-process. Unlike patch_sandbox_ext(), this
// does not rewrite sandbox extension structures in kernel memory.
extern int escape_sbx_demo2(void);

static NSString * const SRRootPath = @"/var/mobile/Documents/test";

typedef struct {
    uint64_t allocatedBytes;
    uint64_t logicalBytes;
    NSUInteger files;
    NSUInteger directories;
    NSUInteger errors;
} SRScanStats;

static BOOL SRPathAllowed(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    if ([path containsString:@".."]) return NO;
    NSString *safe = [path stringByStandardizingPath];
    return [safe isEqualToString:SRRootPath] ||
           [safe hasPrefix:[SRRootPath stringByAppendingString:@"/"]];
}

static uint64_t SRAllocatedBytes(const struct stat *st)
{
    return st ? (uint64_t)st->st_blocks * 512ULL : 0;
}

static NSString *SRFormatBytes(uint64_t bytes)
{
    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;
    fmt.allowedUnits = NSByteCountFormatterUseKB |
                       NSByteCountFormatterUseMB |
                       NSByteCountFormatterUseGB |
                       NSByteCountFormatterUseTB;
    return [fmt stringFromByteCount:(long long)bytes];
}

static NSString *SRNameFromDirent(const struct dirent *entry)
{
    if (!entry || !entry->d_name[0]) return nil;
    return [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:entry->d_name
            length:strlen(entry->d_name)];
}

@interface StorageRescueViewController ()
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL prepared;
@property (nonatomic, assign) BOOL unlinkVerified;
@property (nonatomic, assign) SRScanStats scanStats;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, strong) NSMutableArray<NSString *> *activityLines;
@end

@implementation StorageRescueViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _statusText = @"Not prepared";
        _activityLines = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Storage Rescue";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58.0;
    [self appendLog:@"SAFE BUILD: patch_sandbox_ext() and automatic RemoteCall fallback are disabled."];
    [self appendLog:[NSString stringWithFormat:@"Hard target: %@", SRRootPath]];
}

- (void)appendLog:(NSString *)line
{
    if (!line.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                          dateStyle:NSDateFormatterNoStyle
                                                          timeStyle:NSDateFormatterMediumStyle];
        [self.activityLines addObject:[NSString stringWithFormat:@"%@  %@", stamp, line]];
        while (self.activityLines.count > 100) [self.activityLines removeObjectAtIndex:0];
        if (self.isViewLoaded) [self.tableView reloadData];
    });
}

- (void)setBusy:(BOOL)busy status:(NSString *)status
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = busy;
        if (status.length) self.statusText = status;
        [self.tableView reloadData];
    });
}

- (void)showMessage:(NSString *)title message:(NSString *)message
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - Access

- (BOOL)prepareAccessSync:(NSString **)errorText
{
    // IMPORTANT: never call patch_sandbox_ext() here. It performs kernel writes
    // into the live sandbox extension structures and caused device panics on
    // the Storage Rescue test build.
    if (!kexploit_krw_ready()) {
        [self appendLog:@"Stage 1: starting/recovering DarkSword KRW..."];
        int kr = kexploit_opa334();
        if (kr != 0 || !kexploit_krw_ready()) {
            if (errorText) *errorText = [NSString stringWithFormat:@"KRW failed (%d)", kr];
            return NO;
        }
        [self appendLog:@"Stage 1 complete: KRW ready."];
    } else {
        [self appendLog:@"Stage 1: existing KRW session is ready."];
    }

    int rwBefore = check_sandbox_var_rw();
    if (rwBefore != 0) {
        [self appendLog:@"Stage 2: requesting root R/W sandbox extension through SpringBoard..."];
        int sbx = escape_sbx_demo2();
        if (sbx != 0) {
            if (errorText) *errorText = [NSString stringWithFormat:@"sandbox extension escape failed (%d)", sbx];
            return NO;
        }
    } else {
        [self appendLog:@"Stage 2: /private/var R/W already available; no sandbox change needed."];
    }

    int rwAfter = check_sandbox_var_rw();
    if (rwAfter != 0) {
        if (errorText) *errorText = @"Sandbox token was consumed but /private/var R/W is still denied.";
        return NO;
    }

    [self appendLog:@"Stage 2 complete: /private/var read/write-data allowed."];

    struct stat st;
    errno = 0;
    if (lstat(SRRootPath.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT) {
            self.prepared = YES;
            [self appendLog:@"Target no longer exists."];
            return YES;
        }
        if (errorText) {
            *errorText = [NSString stringWithFormat:@"lstat target failed: errno=%d (%s)", errno, strerror(errno)];
        }
        return NO;
    }

    if (!S_ISDIR(st.st_mode)) {
        if (errorText) *errorText = @"Target exists but is not a directory.";
        return NO;
    }

    DIR *dir = opendir(SRRootPath.fileSystemRepresentation);
    if (!dir) {
        if (errorText) {
            *errorText = [NSString stringWithFormat:@"opendir target failed: errno=%d (%s)", errno, strerror(errno)];
        }
        return NO;
    }
    closedir(dir);

    self.prepared = YES;
    return YES;
}

- (void)prepareAccess
{
    if (self.busy) return;
    [self setBusy:YES status:@"Preparing access…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        BOOL ok = [self prepareAccessSync:&err];
        [self appendLog:ok ? @"Prepare Access completed safely." : (err ?: @"Prepare Access failed.")];
        [self setBusy:NO status:ok ? @"Prepared" : @"Prepare failed"];
    });
}

- (BOOL)requirePreparedFor:(NSString *)operation
{
    if (self.prepared) return YES;
    [self showMessage:@"Prepare Access First"
              message:[NSString stringWithFormat:@"%@ will not run an exploit or sandbox operation automatically in this safe build. Tap Prepare Access first.", operation]];
    return NO;
}

#pragma mark - Iterative scan

- (SRScanStats)scanTargetSync
{
    SRScanStats stats = {0};
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:SRRootPath];

    while (stack.count > 0) {
        @autoreleasepool {
            NSString *path = stack.lastObject;
            [stack removeLastObject];
            if (!SRPathAllowed(path)) {
                stats.errors++;
                continue;
            }

            struct stat st;
            errno = 0;
            if (lstat(path.fileSystemRepresentation, &st) != 0) {
                if (errno != ENOENT) stats.errors++;
                continue;
            }

            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                stats.files++;
                if (st.st_size > 0) stats.logicalBytes += (uint64_t)st.st_size;
                stats.allocatedBytes += SRAllocatedBytes(&st);
                continue;
            }

            stats.directories++;
            DIR *dir = opendir(path.fileSystemRepresentation);
            if (!dir) {
                stats.errors++;
                continue;
            }

            struct dirent *entry = NULL;
            while ((entry = readdir(dir)) != NULL) {
                if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
                NSString *name = SRNameFromDirent(entry);
                if (!name.length) {
                    stats.errors++;
                    continue;
                }
                NSString *child = [path stringByAppendingPathComponent:name];
                if (SRPathAllowed(child)) [stack addObject:child];
            }
            closedir(dir);
        }
    }
    return stats;
}

- (void)scanTarget
{
    if (self.busy || ![self requirePreparedFor:@"Scan"]) return;
    [self setBusy:YES status:@"Scanning (userspace only)…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SRScanStats stats = [self scanTargetSync];
        self.scanStats = stats;
        [self appendLog:[NSString stringWithFormat:@"Scan complete: %lu files, %lu dirs, %@ allocated, %@ logical, %lu errors.",
                         (unsigned long)stats.files,
                         (unsigned long)stats.directories,
                         SRFormatBytes(stats.allocatedBytes),
                         SRFormatBytes(stats.logicalBytes),
                         (unsigned long)stats.errors]];
        [self setBusy:NO status:@"Prepared"];
    });
}

#pragma mark - One-file unlink test

- (NSString *)firstFileUnderTarget
{
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:SRRootPath];
    while (stack.count > 0) {
        @autoreleasepool {
            NSString *path = stack.lastObject;
            [stack removeLastObject];
            if (!SRPathAllowed(path)) continue;

            struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) != 0) continue;
            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return path;

            DIR *dir = opendir(path.fileSystemRepresentation);
            if (!dir) continue;
            struct dirent *entry = NULL;
            while ((entry = readdir(dir)) != NULL) {
                if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
                NSString *name = SRNameFromDirent(entry);
                if (!name.length) continue;
                NSString *child = [path stringByAppendingPathComponent:name];
                if (SRPathAllowed(child)) [stack addObject:child];
            }
            closedir(dir);
        }
    }
    return nil;
}

- (void)testUnlink
{
    if (self.busy || ![self requirePreparedFor:@"Test unlink"]) return;
    [self setBusy:YES status:@"Testing local unlink…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *file = [self firstFileUnderTarget];
        if (!file.length) {
            [self appendLog:@"No file found under target."];
            [self setBusy:NO status:@"No test file"];
            return;
        }

        struct stat before;
        memset(&before, 0, sizeof(before));
        if (lstat(file.fileSystemRepresentation, &before) != 0) {
            [self appendLog:[NSString stringWithFormat:@"Test file disappeared before unlink: %@", file]];
            [self setBusy:NO status:@"Test inconclusive"];
            return;
        }

        uint64_t bytes = SRAllocatedBytes(&before);
        [self appendLog:[NSString stringWithFormat:@"Calling local unlink() on %@ (%@ allocated).", file, SRFormatBytes(bytes)]];

        errno = 0;
        int rc = unlink(file.fileSystemRepresentation);
        int e = rc == 0 ? 0 : errno;

        struct stat after;
        errno = 0;
        BOOL gone = lstat(file.fileSystemRepresentation, &after) != 0 && errno == ENOENT;
        self.unlinkVerified = (rc == 0 && gone);

        [self appendLog:[NSString stringWithFormat:@"unlink() rc=%d errno=%d (%s), existsAfter=%@.",
                         rc, e, e ? strerror(e) : "none", gone ? @"NO" : @"YES"]];

        if (self.unlinkVerified) {
            [self appendLog:@"Local POSIX unlink verified. Full delete is now unlocked for this app session."];
            [self setBusy:NO status:@"unlink verified"];
        } else {
            [self appendLog:@"No RemoteCall fallback was attempted in this safe build."];
            [self setBusy:NO status:@"unlink denied"];
        }
    });
}

#pragma mark - Full deletion (only after verified unlink)

- (void)deleteAllConfirmed
{
    if (self.busy || ![self requirePreparedFor:@"Full delete"]) return;
    if (!self.unlinkVerified) {
        [self showMessage:@"Run Test unlink First"
                  message:@"Full deletion is locked until a local unlink() succeeds and the file is verified absent in this app session."];
        return;
    }

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Delete /var/mobile/Documents/test?"
                         message:@"This permanently removes only this directory and its descendants using local POSIX unlink()/rmdir(). There is no RemoteCall fallback."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [self runFullDelete];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)runFullDelete
{
    if (self.busy) return;
    [self setBusy:YES status:@"Deleting (POSIX only)…"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:SRRootPath];
        NSMutableArray<NSString *> *files = [NSMutableArray array];
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        NSUInteger enumerateErrors = 0;

        // Enumerate first; no deletion while DIR streams are open.
        while (stack.count > 0) {
            @autoreleasepool {
                NSString *path = stack.lastObject;
                [stack removeLastObject];
                if (!SRPathAllowed(path)) { enumerateErrors++; continue; }

                struct stat st;
                if (lstat(path.fileSystemRepresentation, &st) != 0) {
                    if (errno != ENOENT) enumerateErrors++;
                    continue;
                }

                if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                    [files addObject:path];
                    continue;
                }

                [dirs addObject:path];
                DIR *dir = opendir(path.fileSystemRepresentation);
                if (!dir) { enumerateErrors++; continue; }
                struct dirent *entry = NULL;
                while ((entry = readdir(dir)) != NULL) {
                    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
                    NSString *name = SRNameFromDirent(entry);
                    if (!name.length) continue;
                    NSString *child = [path stringByAppendingPathComponent:name];
                    if (SRPathAllowed(child)) [stack addObject:child];
                }
                closedir(dir);
            }
        }

        [self appendLog:[NSString stringWithFormat:@"Delete plan: %lu files/symlinks, %lu dirs, %lu enumeration errors.",
                         (unsigned long)files.count, (unsigned long)dirs.count, (unsigned long)enumerateErrors]];

        NSUInteger removedFiles = 0;
        NSUInteger removedDirs = 0;
        NSUInteger failures = enumerateErrors;

        for (NSString *path in files) {
            @autoreleasepool {
                if (unlink(path.fileSystemRepresentation) == 0 || errno == ENOENT) removedFiles++;
                else failures++;
            }
        }

        // Longest paths first guarantees children before parents.
        [dirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            if (a.length > b.length) return NSOrderedAscending;
            if (a.length < b.length) return NSOrderedDescending;
            return [b compare:a];
        }];

        for (NSString *path in dirs) {
            @autoreleasepool {
                if (rmdir(path.fileSystemRepresentation) == 0 || errno == ENOENT) removedDirs++;
                else failures++;
            }
        }

        struct stat st;
        errno = 0;
        BOOL rootGone = lstat(SRRootPath.fileSystemRepresentation, &st) != 0 && errno == ENOENT;
        [self appendLog:[NSString stringWithFormat:@"Delete result: files=%lu dirs=%lu failures=%lu rootExists=%@.",
                         (unsigned long)removedFiles,
                         (unsigned long)removedDirs,
                         (unsigned long)failures,
                         rootGone ? @"NO" : @"YES"]];
        [self setBusy:NO status:rootGone ? @"Deleted" : @"Incomplete"];
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3;
    if (section == 1) return 4;
    return MAX((NSInteger)self.activityLines.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"Status";
    if (section == 1) return @"Actions";
    return @"Activity";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) {
        return @"Safe build: Scan and unlink never run KRW, sandbox patching, or RemoteCall automatically. Prepare Access is a separate explicit stage.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Target";
            cell.detailTextLabel.text = SRRootPath;
            cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"State";
            cell.detailTextLabel.text = self.busy ? @"Busy" : self.statusText;
        } else {
            cell.textLabel.text = @"Last scan";
            cell.detailTextLabel.text = self.scanStats.files || self.scanStats.directories
                ? [NSString stringWithFormat:@"%lu files · %@", (unsigned long)self.scanStats.files, SRFormatBytes(self.scanStats.allocatedBytes)]
                : @"Not scanned";
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = !self.busy;
        cell.textLabel.textColor = self.busy ? UIColor.tertiaryLabelColor : UIColor.labelColor;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Prepare Access";
            cell.detailTextLabel.text = @"KRW + SpringBoard-issued R/W token; no patch_sandbox_ext().";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Scan Target";
            cell.detailTextLabel.text = @"Userspace lstat/opendir/readdir only. Requires Prepare Access.";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Test unlink() on One File";
            cell.detailTextLabel.text = @"Local libc unlink only; no remote fallback.";
        } else {
            cell.textLabel.text = @"Delete Entire Test Directory";
            cell.detailTextLabel.text = self.unlinkVerified ? @"Unlocked: local unlink verified." : @"Locked until Test unlink succeeds.";
            cell.textLabel.textColor = self.unlinkVerified ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
        }
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.text = self.activityLines.count ? self.activityLines[indexPath.row] : @"No activity yet.";
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || self.busy) return;

    if (indexPath.row == 0) [self prepareAccess];
    else if (indexPath.row == 1) [self scanTarget];
    else if (indexPath.row == 2) [self testUnlink];
    else [self deleteAllConfirmed];
}

@end
