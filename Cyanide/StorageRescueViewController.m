#import "StorageRescueViewController.h"
#import "SettingsViewController.h"
#import "kexploit/kexploit_opa334.h"
#import "utils/sandbox.h"
#import "TaskRop/RemoteCall.h"
#import "tweaks/remote_objc.h"

#import <objc/runtime.h>
#import <dirent.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>
#import <string.h>

static NSString * const SRRootPath = @"/var/mobile/Documents/test";

typedef struct {
    uint64_t allocatedBytes;
    uint64_t logicalBytes;
    NSUInteger files;
    NSUInteger directories;
    NSUInteger errors;
} SRScanStats;

typedef struct {
    uint64_t recoveredBytes;
    NSUInteger filesRemoved;
    NSUInteger directoriesRemoved;
    NSUInteger failures;
} SRDeleteStats;

static BOOL SRPathAllowed(NSString *path)
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    if ([path containsString:@".."] ) return NO;
    NSString *safe = [path stringByStandardizingPath];
    if ([safe isEqualToString:SRRootPath]) return YES;
    return [safe hasPrefix:[SRRootPath stringByAppendingString:@"/"]];
}

static uint64_t SRAllocatedBytes(const struct stat *st)
{
    if (!st) return 0;
    return (uint64_t)st->st_blocks * 512ULL;
}

static NSString *SRFormatBytes(uint64_t bytes)
{
    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;
    fmt.allowedUnits = NSByteCountFormatterUseKB | NSByteCountFormatterUseMB | NSByteCountFormatterUseGB | NSByteCountFormatterUseTB;
    return [fmt stringFromByteCount:(long long)bytes];
}

@interface StorageRescueViewController ()
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL prepared;
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
    self.tableView.estimatedRowHeight = 54.0;
    [self appendLog:@"Native mode. Removal uses POSIX unlink()/rmdir(); NSFileManager is not used to delete files."];
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
        while (self.activityLines.count > 80) [self.activityLines removeObjectAtIndex:0];
        if (self.isViewLoaded) {
            NSIndexSet *set = [NSIndexSet indexSetWithIndex:2];
            [self.tableView reloadSections:set withRowAnimation:UITableViewRowAnimationNone];
        }
    });
}

- (void)setBusyState:(BOOL)busy status:(NSString *)status
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = busy;
        if (status.length) self.statusText = status;
        [self.tableView reloadData];
    });
}

#pragma mark - Access

- (BOOL)prepareAccessSync:(NSString **)errorText
{
    if (!kexploit_krw_ready()) {
        [self appendLog:@"Starting DarkSword KRW..."];
        int kr = kexploit_opa334();
        if (kr != 0 || !kexploit_krw_ready()) {
            if (errorText) *errorText = [NSString stringWithFormat:@"KRW failed (%d)", kr];
            return NO;
        }
        [self appendLog:@"KRW ready."];
    } else {
        [self appendLog:@"Reusing existing KRW session."];
    }

    int sbx = patch_sandbox_ext();
    int rw = check_sandbox_var_rw();
    [self appendLog:[NSString stringWithFormat:@"patch_sandbox_ext=%d, /private/var R/W=%@", sbx, rw == 0 ? @"yes" : @"no"]];

    struct stat st;
    if (lstat(SRRootPath.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT) {
            self.prepared = YES;
            if (errorText) *errorText = nil;
            [self appendLog:@"Target does not exist; nothing remains to delete."];
            return YES;
        }
        if (errorText) *errorText = [NSString stringWithFormat:@"lstat target failed: errno=%d (%s)", errno, strerror(errno)];
        return NO;
    }

    DIR *dir = opendir(SRRootPath.fileSystemRepresentation);
    if (!dir) {
        if (errorText) *errorText = [NSString stringWithFormat:@"opendir target failed: errno=%d (%s)", errno, strerror(errno)];
        return NO;
    }
    closedir(dir);

    self.prepared = YES;
    return YES;
}

- (void)prepareAccess
{
    if (self.busy) return;
    [self setBusyState:YES status:@"Preparing access…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        BOOL ok = [self prepareAccessSync:&err];
        [self appendLog:ok ? @"Access prepared." : (err ?: @"Access preparation failed.")];
        [self setBusyState:NO status:ok ? @"Ready" : @"Access failed"];
    });
}

#pragma mark - Scan

- (void)scanPath:(NSString *)path stats:(SRScanStats *)stats
{
    if (!SRPathAllowed(path) || !stats) return;

    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        stats->errors++;
        return;
    }

    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
        stats->files++;
        stats->logicalBytes += (uint64_t)MAX((off_t)0, st.st_size);
        stats->allocatedBytes += SRAllocatedBytes(&st);
        return;
    }

    stats->directories++;
    DIR *dir = opendir(path.fileSystemRepresentation);
    if (!dir) {
        stats->errors++;
        return;
    }

    struct dirent *entry = NULL;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        @autoreleasepool {
            NSString *name = [[NSFileManager defaultManager]
                stringWithFileSystemRepresentation:entry->d_name
                                            length:strlen(entry->d_name)];
            if (!name.length) { stats->errors++; continue; }
            NSString *child = [path stringByAppendingPathComponent:name];
            [self scanPath:child stats:stats];
        }
    }
    closedir(dir);
}

- (void)scanTarget
{
    if (self.busy) return;
    [self setBusyState:YES status:@"Scanning…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        if (![self prepareAccessSync:&err]) {
            [self appendLog:err ?: @"Could not prepare access."];
            [self setBusyState:NO status:@"Scan failed"];
            return;
        }

        SRScanStats stats = {0};
        [self scanPath:SRRootPath stats:&stats];
        self.scanStats = stats;
        [self appendLog:[NSString stringWithFormat:@"Scan: %lu files, %lu dirs, %@ allocated, %lu errors.",
                         (unsigned long)stats.files,
                         (unsigned long)stats.directories,
                         SRFormatBytes(stats.allocatedBytes),
                         (unsigned long)stats.errors]];
        [self setBusyState:NO status:@"Ready"];
    });
}

#pragma mark - Remote POSIX fallback

- (RemoteCallSession *)newRemoteSession:(NSString **)errorText
{
    RemoteCallSession *session = [[RemoteCallSession alloc] initWithProcess:@"SpringBoard"
                                                        useMigFilterBypass:NO
                                                   firstExceptionTimeoutMS:3000];
    if (!session || ![session hasLocalState] || session.pid <= 0) {
        if (errorText) *errorText = @"Could not open a SpringBoard RemoteCall session.";
        return nil;
    }

    // Give SpringBoard the same root read/write extension before calling libc
    // inside that process. This keeps the fallback independent from
    // NSFileManager semantics.
    uint64_t slash = r_session_alloc_str(session, "/");
    uint64_t klass = r_session_alloc_str(session, "com.apple.app-sandbox.read-write");
    uint64_t token = 0;
    int64_t handle = -1;
    if (slash && klass) {
        token = r_session_dlsym_call(session, R_TIMEOUT, "sandbox_extension_issue_file",
                                     klass, slash, 0, 0, 0, 0, 0, 0);
        if (token) {
            uint64_t rawHandle = r_session_dlsym_call(session, R_TIMEOUT, "sandbox_extension_consume",
                                                      token, 0, 0, 0, 0, 0, 0, 0);
            handle = (int64_t)rawHandle;
            r_session_dlsym_call(session, R_TIMEOUT, "free", token, 0, 0, 0, 0, 0, 0, 0);
        }
    }
    if (slash) r_session_free(session, slash);
    if (klass) r_session_free(session, klass);

    [self appendLog:[NSString stringWithFormat:@"Remote SpringBoard session pid=%d, sandbox handle=%lld.",
                     session.pid, (long long)handle]];
    return session;
}

- (int)remoteErrno:(RemoteCallSession *)session
{
    if (!session) return 0;
    uint64_t ep = r_session_dlsym_call(session, R_TIMEOUT, "__error", 0, 0, 0, 0, 0, 0, 0, 0);
    int value = 0;
    if (ep) [session remoteRead:ep to:&value size:sizeof(value)];
    return value;
}

- (int)remotePOSIX:(const char *)symbol path:(NSString *)path session:(RemoteCallSession *)session errnoOut:(int *)errnoOut
{
    if (!session || !symbol || !SRPathAllowed(path)) {
        if (errnoOut) *errnoOut = EPERM;
        return -1;
    }
    uint64_t remotePath = r_session_alloc_str(session, path.fileSystemRepresentation);
    if (!remotePath) {
        if (errnoOut) *errnoOut = ENOMEM;
        return -1;
    }
    uint64_t raw = r_session_dlsym_call(session, R_TIMEOUT, symbol,
                                        remotePath, 0, 0, 0, 0, 0, 0, 0);
    int rc = (int32_t)(uint32_t)raw;
    int re = rc == 0 ? 0 : [self remoteErrno:session];
    r_session_free(session, remotePath);
    if (errnoOut) *errnoOut = re;
    return rc;
}

- (BOOL)unlinkPath:(NSString *)path
           session:(RemoteCallSession * __strong *)sessionRef
           backend:(NSString **)backend
             error:(int *)errorOut
{
    if (!SRPathAllowed(path)) {
        if (errorOut) *errorOut = EPERM;
        if (backend) *backend = @"blocked";
        return NO;
    }

    errno = 0;
    int rc = unlink(path.fileSystemRepresentation);
    int localErr = rc == 0 ? 0 : errno;
    if (rc == 0) {
        if (backend) *backend = @"local unlink";
        if (errorOut) *errorOut = 0;
        return YES;
    }

    RemoteCallSession *session = sessionRef ? *sessionRef : nil;
    if (!session) {
        NSString *sessionError = nil;
        session = [self newRemoteSession:&sessionError];
        if (sessionRef) *sessionRef = session;
        if (!session) {
            [self appendLog:sessionError ?: @"RemoteCall unavailable."];
            if (backend) *backend = @"local unlink";
            if (errorOut) *errorOut = localErr;
            return NO;
        }
    }

    int remoteErr = 0;
    rc = [self remotePOSIX:"unlink" path:path session:session errnoOut:&remoteErr];
    if (backend) *backend = @"remote unlink";
    if (errorOut) *errorOut = rc == 0 ? 0 : remoteErr;
    return rc == 0;
}

- (BOOL)rmdirPath:(NSString *)path
           session:(RemoteCallSession * __strong *)sessionRef
           backend:(NSString **)backend
             error:(int *)errorOut
{
    if (!SRPathAllowed(path)) {
        if (errorOut) *errorOut = EPERM;
        if (backend) *backend = @"blocked";
        return NO;
    }

    errno = 0;
    int rc = rmdir(path.fileSystemRepresentation);
    int localErr = rc == 0 ? 0 : errno;
    if (rc == 0) {
        if (backend) *backend = @"local rmdir";
        if (errorOut) *errorOut = 0;
        return YES;
    }

    RemoteCallSession *session = sessionRef ? *sessionRef : nil;
    if (!session) {
        NSString *sessionError = nil;
        session = [self newRemoteSession:&sessionError];
        if (sessionRef) *sessionRef = session;
        if (!session) {
            [self appendLog:sessionError ?: @"RemoteCall unavailable."];
            if (backend) *backend = @"local rmdir";
            if (errorOut) *errorOut = localErr;
            return NO;
        }
    }

    int remoteErr = 0;
    rc = [self remotePOSIX:"rmdir" path:path session:session errnoOut:&remoteErr];
    if (backend) *backend = @"remote rmdir";
    if (errorOut) *errorOut = rc == 0 ? 0 : remoteErr;
    return rc == 0;
}

#pragma mark - Delete

- (NSString *)firstRegularFileUnder:(NSString *)path
{
    if (!SRPathAllowed(path)) return nil;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return nil;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return path;

    DIR *dir = opendir(path.fileSystemRepresentation);
    if (!dir) return nil;
    NSString *found = nil;
    struct dirent *entry = NULL;
    while (!found && (entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        @autoreleasepool {
            NSString *name = [[NSFileManager defaultManager]
                stringWithFileSystemRepresentation:entry->d_name
                                            length:strlen(entry->d_name)];
            if (!name.length) continue;
            NSString *child = [path stringByAppendingPathComponent:name];
            found = [self firstRegularFileUnder:child];
        }
    }
    closedir(dir);
    return found;
}

- (void)testUnlink
{
    if (self.busy) return;
    [self setBusyState:YES status:@"Testing unlink…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *prepError = nil;
        if (![self prepareAccessSync:&prepError]) {
            [self appendLog:prepError ?: @"Could not prepare access."];
            [self setBusyState:NO status:@"Test failed"];
            return;
        }

        NSString *file = [self firstRegularFileUnder:SRRootPath];
        if (!file.length) {
            [self appendLog:@"No regular file found under target."];
            [self setBusyState:NO status:@"No test file"];
            return;
        }

        struct stat before;
        memset(&before, 0, sizeof(before));
        lstat(file.fileSystemRepresentation, &before);
        uint64_t bytes = SRAllocatedBytes(&before);
        [self appendLog:[NSString stringWithFormat:@"Test file: %@ (%@ allocated)", file, SRFormatBytes(bytes)]];

        RemoteCallSession *session = nil;
        NSString *backend = nil;
        int err = 0;
        BOOL ok = [self unlinkPath:file session:&session backend:&backend error:&err];
        BOOL gone = lstat(file.fileSystemRepresentation, &before) != 0 && errno == ENOENT;

        [self appendLog:[NSString stringWithFormat:@"%@ → rc=%@ errno=%d (%s), existsAfter=%@.",
                         backend ?: @"unlink", ok ? @"0" : @"-1", err,
                         err ? strerror(err) : "none", gone ? @"NO" : @"YES"]];

        if (session) [session destroyRemoteCall];
        [self setBusyState:NO status:(ok && gone) ? @"unlink works" : @"unlink failed"];
        if (ok && gone) [self scanTarget];
    });
}

- (BOOL)deleteTreeAtPath:(NSString *)path
                 session:(RemoteCallSession * __strong *)sessionRef
                   stats:(SRDeleteStats *)stats
{
    if (!SRPathAllowed(path) || !stats) return NO;

    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT) return YES;
        stats->failures++;
        return NO;
    }

    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
        uint64_t bytes = SRAllocatedBytes(&st);
        NSString *backend = nil;
        int err = 0;
        BOOL ok = [self unlinkPath:path session:sessionRef backend:&backend error:&err];
        if (ok) {
            stats->filesRemoved++;
            stats->recoveredBytes += bytes;
        } else {
            stats->failures++;
            if (stats->failures <= 30) {
                [self appendLog:[NSString stringWithFormat:@"unlink failed errno=%d (%s): %@", err, strerror(err), path]];
            }
        }
        return ok;
    }

    DIR *dir = opendir(path.fileSystemRepresentation);
    if (!dir) {
        stats->failures++;
        [self appendLog:[NSString stringWithFormat:@"opendir failed errno=%d (%s): %@", errno, strerror(errno), path]];
        return NO;
    }

    NSMutableArray<NSString *> *children = [NSMutableArray array];
    struct dirent *entry = NULL;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        @autoreleasepool {
            NSString *name = [[NSFileManager defaultManager]
                stringWithFileSystemRepresentation:entry->d_name
                                            length:strlen(entry->d_name)];
            if (name.length) [children addObject:[path stringByAppendingPathComponent:name]];
        }
    }
    closedir(dir);

    BOOL allChildren = YES;
    for (NSString *child in children) {
        @autoreleasepool {
            if (![self deleteTreeAtPath:child session:sessionRef stats:stats]) allChildren = NO;
            NSUInteger done = stats->filesRemoved + stats->directoriesRemoved + stats->failures;
            if (done > 0 && done % 100 == 0) {
                [self appendLog:[NSString stringWithFormat:@"Progress: %lu removed, %lu failures, %@ recovered.",
                                 (unsigned long)(stats->filesRemoved + stats->directoriesRemoved),
                                 (unsigned long)stats->failures,
                                 SRFormatBytes(stats->recoveredBytes)]];
            }
        }
    }

    NSString *backend = nil;
    int err = 0;
    BOOL dirOK = [self rmdirPath:path session:sessionRef backend:&backend error:&err];
    if (dirOK) {
        stats->directoriesRemoved++;
    } else {
        stats->failures++;
        if (stats->failures <= 30) {
            [self appendLog:[NSString stringWithFormat:@"rmdir failed errno=%d (%s): %@", err, strerror(err), path]];
        }
    }
    return allChildren && dirOK;
}

- (void)deleteTargetConfirmed
{
    if (self.busy) return;
    [self setBusyState:YES status:@"Deleting…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *prepError = nil;
        if (![self prepareAccessSync:&prepError]) {
            [self appendLog:prepError ?: @"Could not prepare access."];
            [self setBusyState:NO status:@"Delete failed"];
            return;
        }

        SRDeleteStats stats = {0};
        RemoteCallSession *session = nil;
        BOOL ok = [self deleteTreeAtPath:SRRootPath session:&session stats:&stats];
        if (session) [session destroyRemoteCall];

        struct stat st;
        BOOL exists = lstat(SRRootPath.fileSystemRepresentation, &st) == 0;
        [self appendLog:[NSString stringWithFormat:@"Delete finished: files=%lu dirs=%lu failures=%lu recovered≈%@ rootExists=%@.",
                         (unsigned long)stats.filesRemoved,
                         (unsigned long)stats.directoriesRemoved,
                         (unsigned long)stats.failures,
                         SRFormatBytes(stats.recoveredBytes),
                         exists ? @"YES" : @"NO"]];
        [self setBusyState:NO status:(!exists && ok) ? @"Completed" : @"Completed with errors"];
        [self scanTarget];
    });
}

- (void)confirmTestUnlink
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Test POSIX unlink"
                                                                 message:@"This removes one real file inside /var/mobile/Documents/test. It cannot touch any path outside that directory."
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete One File" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self testUnlink];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)confirmDeleteAll
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Delete test directory?"
                                                                 message:@"Irreversible. Every file and subdirectory under /var/mobile/Documents/test will be removed with unlink()/rmdir(). The hard-coded boundary rejects every other path."
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete Everything" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self deleteTargetConfirmed];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 4;
    if (section == 1) return 4;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"Target";
    if (section == 1) return @"Actions";
    return @"Activity";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Path";
            cell.detailTextLabel.text = SRRootPath;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Status";
            cell.detailTextLabel.text = self.statusText ?: @"Unknown";
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Entries";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu files · %lu dirs",
                                         (unsigned long)self.scanStats.files,
                                         (unsigned long)self.scanStats.directories];
        } else {
            cell.textLabel.text = @"Allocated";
            cell.detailTextLabel.text = SRFormatBytes(self.scanStats.allocatedBytes);
        }
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.55;
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = !self.busy;
        cell.textLabel.textColor = self.busy ? UIColor.tertiaryLabelColor : UIColor.labelColor;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Prepare Access";
            cell.detailTextLabel.text = @"Starts/reuses KRW and lifts Cyanide's filesystem sandbox.";
            cell.imageView.image = [UIImage systemImageNamed:@"lock.open.fill"];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Scan Target";
            cell.detailTextLabel.text = @"Counts files and allocated bytes without deleting anything.";
            cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Test unlink() on One File";
            cell.detailTextLabel.text = @"Deletes one real file and verifies that it disappeared.";
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        } else {
            cell.textLabel.text = @"Delete /var/mobile/Documents/test";
            cell.detailTextLabel.text = @"Recursive POSIX unlink()/rmdir() with a hard-coded path boundary.";
            cell.textLabel.textColor = self.busy ? UIColor.tertiaryLabelColor : UIColor.systemRedColor;
            cell.imageView.image = [UIImage systemImageNamed:@"trash.fill"];
        }
        cell.detailTextLabel.numberOfLines = 0;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UITextView *tv = [[UITextView alloc] init];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.scrollEnabled = NO;
    tv.backgroundColor = UIColor.clearColor;
    tv.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    tv.text = [self.activityLines componentsJoinedByString:@"\n"];
    [cell.contentView addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [tv.topAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy || indexPath.section != 1) return;
    if (indexPath.row == 0) [self prepareAccess];
    else if (indexPath.row == 1) [self scanTarget];
    else if (indexPath.row == 2) [self confirmTestUnlink];
    else [self confirmDeleteAll];
}

@end

#pragma mark - Settings integration

// Cyanide's Xcode project uses a file-system-synchronized Cyanide source group,
// so this file is compiled automatically. Keep the integration self-contained:
// add a native Storage button to the root Settings navigation bar without
// modifying the large SettingsViewController implementation.
@interface SettingsViewController (StorageRescueIntegration)
- (void)sr_viewDidLoad;
- (void)sr_openStorageRescue;
@end

@implementation SettingsViewController (StorageRescueIntegration)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(viewDidLoad));
        Method replacement = class_getInstanceMethod(self, @selector(sr_viewDidLoad));
        method_exchangeImplementations(original, replacement);
    });
}

- (void)sr_viewDidLoad
{
    [self sr_viewDidLoad];

    BOOL detail = NO;
    @try {
        id value = [self valueForKey:@"detailMode"];
        if ([value respondsToSelector:@selector(boolValue)]) detail = [value boolValue];
    } @catch (__unused NSException *e) {}
    if (detail) return;

    UIBarButtonItem *storage = [[UIBarButtonItem alloc] initWithTitle:@"Storage"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(sr_openStorageRescue)];
    storage.accessibilityLabel = @"Storage Rescue";

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    if (self.navigationItem.rightBarButtonItems.count) {
        [items addObjectsFromArray:self.navigationItem.rightBarButtonItems];
    } else if (self.navigationItem.rightBarButtonItem) {
        [items addObject:self.navigationItem.rightBarButtonItem];
    }
    BOOL alreadyPresent = NO;
    for (UIBarButtonItem *item in items) {
        if ([item.accessibilityLabel isEqualToString:@"Storage Rescue"]) {
            alreadyPresent = YES;
            break;
        }
    }
    if (!alreadyPresent) [items addObject:storage];
    self.navigationItem.rightBarButtonItems = items;
}

- (void)sr_openStorageRescue
{
    StorageRescueViewController *vc = [[StorageRescueViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
