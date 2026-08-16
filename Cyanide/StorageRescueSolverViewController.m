#import "StorageRescueSolverViewController.h"

#import "kexploit/kexploit_opa334.h"
#import "kexploit/kutils.h"
#import "kexploit/krw.h"
#import "kexploit/vnode.h"
#import "utils/sandbox.h"
#import "TaskRop/RemoteCall.h"
#import "tweaks/remote_objc.h"

#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <string.h>

extern int escape_sbx_demo2(void);

static NSString * const SRRootPath = @"/var/mobile/Documents/test";
static const uint64_t SRAPFSBSDFlagsOffset = 0x70ULL;

#ifndef UF_NOUNLINK
#define UF_NOUNLINK 0x00000010U
#endif
#ifndef UF_DATAVAULT
#define UF_DATAVAULT 0x00000080U
#endif
#ifndef SF_IMMUTABLE
#define SF_IMMUTABLE 0x00020000U
#endif
#ifndef SF_APPEND
#define SF_APPEND 0x00040000U
#endif
#ifndef SF_RESTRICTED
#define SF_RESTRICTED 0x00080000U
#endif
#ifndef SF_NOUNLINK
#define SF_NOUNLINK 0x00100000U
#endif

static const uint32_t SRBlockingFlags =
    UF_IMMUTABLE | UF_APPEND | UF_NOUNLINK | UF_DATAVAULT |
    SF_IMMUTABLE | SF_APPEND | SF_RESTRICTED | SF_NOUNLINK;

typedef struct {
    uint64_t allocatedBytes;
    uint64_t logicalBytes;
    NSUInteger files;
    NSUInteger dirs;
    NSUInteger errors;
} SRScanStats;

typedef struct {
    NSUInteger removedFiles;
    NSUInteger removedDirs;
    NSUInteger failures;
    NSUInteger repairedFlags;
    NSUInteger removedMACL;
    uint64_t recoveredBytes;
} SRDeleteStats;

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
    NSByteCountFormatter *f = [[NSByteCountFormatter alloc] init];
    f.countStyle = NSByteCountFormatterCountStyleFile;
    f.allowedUnits = NSByteCountFormatterUseKB | NSByteCountFormatterUseMB |
                     NSByteCountFormatterUseGB | NSByteCountFormatterUseTB;
    return [f stringFromByteCount:(long long)bytes];
}

static uint64_t SRFreeBytes(void)
{
    struct statfs fs;
    if (statfs("/var/mobile/Documents", &fs) != 0) return 0;
    return (uint64_t)fs.f_bavail * (uint64_t)fs.f_bsize;
}

static NSString *SRNameFromDirent(const struct dirent *e)
{
    if (!e || !e->d_name[0]) return nil;
    return [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:e->d_name
            length:strlen(e->d_name)];
}

static BOOL SRGone(NSString *path)
{
    struct stat st;
    errno = 0;
    return lstat(path.fileSystemRepresentation, &st) != 0 && errno == ENOENT;
}

static NSString *SRFlagsDescription(uint32_t f)
{
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    if (f & UF_IMMUTABLE) [a addObject:@"UF_IMMUTABLE"];
    if (f & UF_APPEND) [a addObject:@"UF_APPEND"];
    if (f & UF_NOUNLINK) [a addObject:@"UF_NOUNLINK"];
    if (f & UF_DATAVAULT) [a addObject:@"UF_DATAVAULT"];
    if (f & SF_IMMUTABLE) [a addObject:@"SF_IMMUTABLE"];
    if (f & SF_APPEND) [a addObject:@"SF_APPEND"];
    if (f & SF_RESTRICTED) [a addObject:@"SF_RESTRICTED"];
    if (f & SF_NOUNLINK) [a addObject:@"SF_NOUNLINK"];
    return a.count ? [a componentsJoinedByString:@"|"] : @"none";
}

@interface StorageRescueSolverViewController ()
@property (atomic, assign) BOOL busy;
@property (atomic, assign) BOOL cancelRequested;
@property (nonatomic, assign) BOOL prepared;
@property (nonatomic, assign) BOOL proofVerified;
@property (nonatomic, assign) BOOL proofNeededFlagRepair;
@property (nonatomic, assign) BOOL proofNeededMACLRemoval;
@property (nonatomic, assign) BOOL safeMovePrefixReady;
@property (nonatomic, assign) int64_t safeMoveHandle;
@property (nonatomic, assign) SRScanStats scanStats;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, strong) NSMutableArray<NSString *> *activityLines;
@end

@implementation StorageRescueSolverViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _statusText = @"Not prepared";
        _activityLines = [NSMutableArray array];
        _safeMoveHandle = -1;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Storage Rescue";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58.0;
    [self appendLog:@"Solver build: no patch_sandbox_ext(), no inherited-method swizzling."];
    [self appendLog:[NSString stringWithFormat:@"Hard boundary: %@", SRRootPath]];
    [self appendLog:@"Mass deletion stays locked until one original file is actually removed and verified ENOENT."];
}

- (void)appendLog:(NSString *)line
{
    if (!line.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                          dateStyle:NSDateFormatterNoStyle
                                                          timeStyle:NSDateFormatterMediumStyle];
        [self.activityLines addObject:[NSString stringWithFormat:@"%@  %@", stamp, line]];
        while (self.activityLines.count > 160) [self.activityLines removeObjectAtIndex:0];
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
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

#pragma mark - Access

- (BOOL)prepareAccessSync:(NSString **)errorText
{
    if (!kexploit_krw_ready()) {
        [self appendLog:@"Stage 1: starting/recovering DarkSword KRW…"];
        int kr = kexploit_opa334();
        if (kr != 0 || !kexploit_krw_ready()) {
            if (errorText) *errorText = [NSString stringWithFormat:@"KRW failed (%d)", kr];
            return NO;
        }
        [self appendLog:@"Stage 1 complete: KRW ready."];
    } else {
        [self appendLog:@"Stage 1: existing KRW session is ready."];
    }

    if (check_sandbox_var_rw() != 0) {
        [self appendLog:@"Stage 2: requesting SpringBoard root R/W extension…"];
        int r = escape_sbx_demo2();
        if (r != 0 || check_sandbox_var_rw() != 0) {
            if (errorText) *errorText = [NSString stringWithFormat:@"R/W extension failed (%d)", r];
            return NO;
        }
    }

    struct stat st;
    if (lstat(SRRootPath.fileSystemRepresentation, &st) != 0) {
        if (errno == ENOENT) {
            self.prepared = YES;
            return YES;
        }
        if (errorText) *errorText = [NSString stringWithFormat:@"Target lstat failed: %s", strerror(errno)];
        return NO;
    }
    if (!S_ISDIR(st.st_mode)) {
        if (errorText) *errorText = @"Target is not a directory.";
        return NO;
    }

    DIR *d = opendir(SRRootPath.fileSystemRepresentation);
    if (!d) {
        if (errorText) *errorText = [NSString stringWithFormat:@"Target opendir failed: %s", strerror(errno)];
        return NO;
    }
    closedir(d);
    self.prepared = YES;
    [self appendLog:@"Prepare Access complete: KRW + /private/var R/W available."];
    return YES;
}

- (void)prepareAccess
{
    if (self.busy) return;
    self.cancelRequested = NO;
    [self setBusy:YES status:@"Preparing access…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        BOOL ok = [self prepareAccessSync:&err];
        [self appendLog:ok ? @"Prepare Access succeeded." : (err ?: @"Prepare Access failed.")];
        [self setBusy:NO status:ok ? @"Prepared" : @"Prepare failed"];
    });
}

- (BOOL)requirePrepared:(NSString *)op
{
    if (self.prepared) return YES;
    [self showMessage:@"Prepare Access First"
              message:[NSString stringWithFormat:@"%@ will not start the exploit automatically. Run Prepare Access first.", op]];
    return NO;
}

#pragma mark - Scan

- (SRScanStats)scanSync
{
    SRScanStats s = {0};
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:SRRootPath];
    while (stack.count && !self.cancelRequested) {
        @autoreleasepool {
            NSString *p = stack.lastObject;
            [stack removeLastObject];
            if (!SRPathAllowed(p)) { s.errors++; continue; }
            struct stat st;
            if (lstat(p.fileSystemRepresentation, &st) != 0) {
                if (errno != ENOENT) s.errors++;
                continue;
            }
            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                s.files++;
                s.logicalBytes += st.st_size > 0 ? (uint64_t)st.st_size : 0;
                s.allocatedBytes += SRAllocatedBytes(&st);
                continue;
            }
            s.dirs++;
            DIR *d = opendir(p.fileSystemRepresentation);
            if (!d) { s.errors++; continue; }
            struct dirent *e;
            while ((e = readdir(d))) {
                if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
                NSString *n = SRNameFromDirent(e);
                if (!n.length) continue;
                NSString *c = [p stringByAppendingPathComponent:n];
                if (SRPathAllowed(c)) [stack addObject:c];
            }
            closedir(d);
        }
    }
    return s;
}

- (void)scanTarget
{
    if (self.busy || ![self requirePrepared:@"Scan"]) return;
    self.cancelRequested = NO;
    [self setBusy:YES status:@"Scanning…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SRScanStats s = [self scanSync];
        self.scanStats = s;
        [self appendLog:[NSString stringWithFormat:@"Scan: %lu files, %lu dirs, %@ allocated, %@ logical, %lu errors.",
                         (unsigned long)s.files, (unsigned long)s.dirs,
                         SRFormatBytes(s.allocatedBytes), SRFormatBytes(s.logicalBytes),
                         (unsigned long)s.errors]];
        [self setBusy:NO status:self.cancelRequested ? @"Scan cancelled" : @"Prepared"];
    });
}

#pragma mark - Proof helpers

- (NSString *)firstFileUnderTarget
{
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:SRRootPath];
    while (stack.count) {
        @autoreleasepool {
            NSString *p = stack.lastObject;
            [stack removeLastObject];
            if (!SRPathAllowed(p)) continue;
            struct stat st;
            if (lstat(p.fileSystemRepresentation, &st) != 0) continue;
            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return p;
            DIR *d = opendir(p.fileSystemRepresentation);
            if (!d) continue;
            struct dirent *e;
            while ((e = readdir(d))) {
                if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
                NSString *n = SRNameFromDirent(e);
                if (!n.length) continue;
                NSString *c = [p stringByAppendingPathComponent:n];
                if (SRPathAllowed(c)) [stack addObject:c];
            }
            closedir(d);
        }
    }
    return nil;
}

- (NSArray<NSString *> *)directoryChainForFile:(NSString *)file
{
    NSMutableArray<NSString *> *rev = [NSMutableArray array];
    NSString *p = [file stringByDeletingLastPathComponent];
    while (p.length && SRPathAllowed(p)) {
        [rev addObject:p];
        if ([p isEqualToString:SRRootPath]) break;
        NSString *next = [p stringByDeletingLastPathComponent];
        if ([next isEqualToString:p]) break;
        p = next;
    }
    return [[rev reverseObjectEnumerator] allObjects];
}

- (void)logMetadataForPath:(NSString *)path label:(NSString *)label
{
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        [self appendLog:[NSString stringWithFormat:@"%@ lstat failed: %@ errno=%d (%s)", label, path, errno, strerror(errno)]];
        return;
    }
    [self appendLog:[NSString stringWithFormat:@"%@ flags=0x%08x [%@] uid=%u gid=%u mode=%o ino=%llu path=%@",
                     label, (uint32_t)st.st_flags, SRFlagsDescription((uint32_t)st.st_flags),
                     st.st_uid, st.st_gid, st.st_mode & 07777,
                     (unsigned long long)st.st_ino, path]];
}

- (BOOL)controlledSiblingUnlinkAtParent:(NSString *)parent
{
    NSString *name = [NSString stringWithFormat:@".cyanide_unlink_probe_%d_%llu", getpid(), (unsigned long long)mach_absolute_time()];
    NSString *p = [parent stringByAppendingPathComponent:name];
    if (!SRPathAllowed(p)) return NO;
    int fd = open(p.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        [self appendLog:[NSString stringWithFormat:@"Controlled create: FAIL errno=%d (%s)", errno, strerror(errno)]];
        return NO;
    }
    const char b = 'C';
    (void)write(fd, &b, 1);
    fsync(fd);
    close(fd);
    errno = 0;
    int rc = unlink(p.fileSystemRepresentation);
    int e = rc == 0 ? 0 : errno;
    BOOL gone = SRGone(p);
    [self appendLog:[NSString stringWithFormat:@"Controlled create→unlink: rc=%d errno=%d (%s) existsAfter=%@",
                     rc, e, e ? strerror(e) : "none", gone ? @"NO" : @"YES"]];
    return rc == 0 && gone;
}

- (BOOL)tryUnlinkOriginal:(NSString *)file stage:(NSString *)stage
{
    errno = 0;
    int rc = unlink(file.fileSystemRepresentation);
    int e = rc == 0 ? 0 : errno;
    BOOL gone = SRGone(file);
    [self appendLog:[NSString stringWithFormat:@"%@ unlink: rc=%d errno=%d (%s) existsAfter=%@",
                     stage, rc, e, e ? strerror(e) : "none", gone ? @"NO" : @"YES"]];
    return rc == 0 && gone;
}

#pragma mark - Safe move extension

- (BOOL)consumeSafeMoveExtensionForPath:(NSString *)path prefix:(BOOL)prefix
{
    if (!SRPathAllowed(path) || !kexploit_krw_ready()) return NO;

    uint32_t flags = 0;
    if (prefix) {
        void *sym = dlsym(RTLD_DEFAULT, "SANDBOX_EXTENSION_PREFIXMATCH");
        if (!sym) {
            [self appendLog:@"safe-move prefix flag symbol is unavailable; refusing to guess its value."];
            return NO;
        }
        flags = *(const uint32_t *)sym;
        [self appendLog:[NSString stringWithFormat:@"safe-move prefix flags=0x%x", flags]];
    }

    RemoteCallSession *s = [[RemoteCallSession alloc] initWithProcess:@"SpringBoard"
                                                  useMigFilterBypass:NO
                                             firstExceptionTimeoutMS:3000];
    if (!s || ![s hasLocalState] || s.pid <= 0) {
        if (s) [s abandonRemoteCall];
        [self appendLog:@"safe-move: could not open isolated SpringBoard RemoteCall session."];
        return NO;
    }

    uint64_t c = r_session_alloc_str(s, "com.apple.private.safe-move.receive");
    uint64_t p = r_session_alloc_str(s, path.fileSystemRepresentation);
    if (!c || !p) {
        if (c) r_session_free(s, c);
        if (p) r_session_free(s, p);
        [s destroyRemoteCall];
        [self appendLog:@"safe-move: remote string allocation failed."];
        return NO;
    }

    uint64_t tokenPtr = r_session_dlsym_call(s, R_TIMEOUT, "sandbox_extension_issue_file",
                                             c, p, flags, 0, 0, 0, 0, 0);
    r_session_free(s, c);
    r_session_free(s, p);

    NSString *token = nil;
    if (tokenPtr) {
        RemotePointer *rp = s[(NSUInteger)tokenPtr];
        token = [rp stringWithMaxLength:0x4000];
        r_session_dlsym_call(s, R_TIMEOUT, "free", tokenPtr, 0, 0, 0, 0, 0, 0, 0);
    }
    int dr = [s destroyRemoteCall];

    if (!token.length) {
        [self appendLog:[NSString stringWithFormat:@"safe-move issue failed for %@ (destroyRC=%d).", prefix ? @"root prefix" : @"exact file", dr]];
        return NO;
    }

    int64_t h = sandbox_extension_consume(token.UTF8String);
    if (h < 0) {
        [self appendLog:@"safe-move token received but consume failed."];
        return NO;
    }

    if (prefix) {
        self.safeMoveHandle = h;
        self.safeMovePrefixReady = YES;
    }
    [self appendLog:[NSString stringWithFormat:@"safe-move %@ token consumed (handle=%lld).",
                     prefix ? @"PREFIX" : @"exact-file", (long long)h]];
    return YES;
}

#pragma mark - Flag repair

- (BOOL)kernelClearBlockingFlagsOnFD:(int)fd path:(NSString *)path statBefore:(const struct stat *)before
{
    if (fd < 0 || !before || !kexploit_krw_ready()) return NO;
    uint32_t oldFlags = (uint32_t)before->st_flags;
    uint32_t blockers = oldFlags & SRBlockingFlags;
    if (!blockers) return YES;

    uint64_t vp = get_vnode_by_fd(fd);
    if (!vp || vp == (uint64_t)-1 || !is_kaddr_valid(vp)) {
        [self appendLog:[NSString stringWithFormat:@"KRW guard: invalid vnode for %@", path]];
        return NO;
    }
    uint64_t fsn = vnode_fsnode(vp);
    if (!fsn || fsn == (uint64_t)-1 || !is_kaddr_valid(fsn)) {
        [self appendLog:[NSString stringWithFormat:@"KRW guard: invalid APFS fsnode for %@", path]];
        return NO;
    }

    uint32_t ku = apfs_fsnode_get_uid(fsn);
    uint32_t kg = apfs_fsnode_get_gid(fsn);
    uint16_t km = apfs_fsnode_get_mode(fsn);
    uint32_t kf = kread32(fsn + SRAPFSBSDFlagsOffset);

    BOOL layoutOK = ku == before->st_uid && kg == before->st_gid &&
                    km == (uint16_t)before->st_mode && kf == oldFlags;
    if (!layoutOK) {
        [self appendLog:[NSString stringWithFormat:@"KRW GUARD ABORT: APFS layout mismatch; NO WRITE. stat(uid=%u gid=%u mode=0x%x flags=0x%x) kernel(uid=%u gid=%u mode=0x%x flags@+0x70=0x%x) path=%@",
                         before->st_uid, before->st_gid, (uint16_t)before->st_mode, oldFlags,
                         ku, kg, km, kf, path]];
        return NO;
    }

    uint32_t newFlags = oldFlags & ~blockers;
    kwrite32(fsn + SRAPFSBSDFlagsOffset, newFlags);
    uint32_t verifyRaw = kread32(fsn + SRAPFSBSDFlagsOffset);
    struct stat after;
    memset(&after, 0, sizeof(after));
    int sr = fstat(fd, &after);

    BOOL verifyOK = verifyRaw == newFlags && sr == 0 &&
                    (uint32_t)after.st_flags == newFlags &&
                    after.st_uid == before->st_uid && after.st_gid == before->st_gid &&
                    (uint16_t)after.st_mode == (uint16_t)before->st_mode &&
                    after.st_ino == before->st_ino;
    if (!verifyOK) {
        kwrite32(fsn + SRAPFSBSDFlagsOffset, oldFlags);
        [self appendLog:[NSString stringWithFormat:@"KRW VERIFY FAILED: restored 0x%08x; NO DELETE attempted for %@", oldFlags, path]];
        return NO;
    }

    [self appendLog:[NSString stringWithFormat:@"KRW flag repair verified: 0x%08x → 0x%08x (%@) path=%@",
                     oldFlags, newFlags, SRFlagsDescription(blockers), path]];
    return YES;
}

- (BOOL)clearBlockingFlagsAtPath:(NSString *)path keepFD:(int *)fdOut changed:(BOOL *)changed
{
    if (fdOut) *fdOut = -1;
    if (changed) *changed = NO;
    if (!SRPathAllowed(path)) return NO;

    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return errno == ENOENT;
    uint32_t blockers = (uint32_t)st.st_flags & SRBlockingFlags;
    if (!blockers) return YES;

    [self appendLog:[NSString stringWithFormat:@"Blocking flags detected: 0x%08x [%@] path=%@",
                     (uint32_t)st.st_flags, SRFlagsDescription((uint32_t)st.st_flags), path]];

    uint32_t wanted = (uint32_t)st.st_flags & ~blockers;
    errno = 0;
    if (chflags(path.fileSystemRepresentation, wanted) == 0) {
        struct stat v;
        if (lstat(path.fileSystemRepresentation, &v) == 0 && (((uint32_t)v.st_flags & blockers) == 0)) {
            if (changed) *changed = YES;
            [self appendLog:[NSString stringWithFormat:@"chflags repair verified: 0x%08x → 0x%08x path=%@",
                             (uint32_t)st.st_flags, (uint32_t)v.st_flags, path]];
            return YES;
        }
    } else {
        [self appendLog:[NSString stringWithFormat:@"chflags denied: errno=%d (%s); evaluating guarded KRW repair.", errno, strerror(errno)]];
    }

    // Never follow symlinks into a kernel metadata operation.
    if (S_ISLNK(st.st_mode)) return NO;

    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        [self appendLog:[NSString stringWithFormat:@"KRW repair cannot pin vnode: open errno=%d (%s) path=%@", errno, strerror(errno), path]];
        return NO;
    }

    BOOL ok = [self kernelClearBlockingFlagsOnFD:fd path:path statBefore:&st];
    if (ok && changed) *changed = YES;
    if (ok && fdOut) {
        *fdOut = fd; // caller owns; keeping it open pins the repaired vnode.
    } else {
        close(fd);
    }
    return ok;
}

- (BOOL)removeMACLIfPresent:(NSString *)path changed:(BOOL *)changed
{
    if (changed) *changed = NO;
    if (!SRPathAllowed(path)) return NO;
    ssize_t n = listxattr(path.fileSystemRepresentation, NULL, 0, XATTR_NOFOLLOW);
    if (n <= 0) return YES;
    char *buf = calloc(1, (size_t)n);
    if (!buf) return NO;
    ssize_t got = listxattr(path.fileSystemRepresentation, buf, (size_t)n, XATTR_NOFOLLOW);
    BOOL found = NO;
    if (got > 0) {
        for (ssize_t off = 0; off < got;) {
            const char *name = buf + off;
            size_t len = strlen(name);
            if (!strcmp(name, "com.apple.macl")) { found = YES; break; }
            off += (ssize_t)len + 1;
        }
    }
    free(buf);
    if (!found) return YES;

    errno = 0;
    int rc = removexattr(path.fileSystemRepresentation, "com.apple.macl", XATTR_NOFOLLOW);
    int e = rc == 0 ? 0 : errno;
    [self appendLog:[NSString stringWithFormat:@"remove com.apple.macl: rc=%d errno=%d (%s) path=%@",
                     rc, e, e ? strerror(e) : "none", path]];
    if (rc == 0 && changed) *changed = YES;
    return rc == 0;
}

#pragma mark - Prove deletion

- (void)proveDeletion
{
    if (self.busy || ![self requirePrepared:@"Deletion proof"]) return;
    self.cancelRequested = NO;
    self.proofVerified = NO;
    self.proofNeededFlagRepair = NO;
    self.proofNeededMACLRemoval = NO;
    [self setBusy:YES status:@"Proving deletion…"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *file = [self firstFileUnderTarget];
            if (!file.length) {
                [self appendLog:@"No file found. Target may already be empty."];
                [self setBusy:NO status:@"No test file"];
                return;
            }

            struct stat initial;
            if (lstat(file.fileSystemRepresentation, &initial) != 0) {
                [self appendLog:@"Proof file disappeared before test."];
                [self setBusy:NO status:@"Proof inconclusive"];
                return;
            }

            [self appendLog:[NSString stringWithFormat:@"PROOF FILE: %@ (%@ allocated)", file, SRFormatBytes(SRAllocatedBytes(&initial))]];
            NSArray<NSString *> *dirs = [self directoryChainForFile:file];
            for (NSString *d in dirs) [self logMetadataForPath:d label:@"DIR"];
            [self logMetadataForPath:file label:@"FILE"];

            NSString *parent = [file stringByDeletingLastPathComponent];
            (void)[self controlledSiblingUnlinkAtParent:parent];

            if ([self tryUnlinkOriginal:file stage:@"Baseline"]) {
                self.proofVerified = YES;
                [self appendLog:@"PROOF SUCCESS: local unlink already works. Mass delete unlocked."];
                [self setBusy:NO status:@"Deletion proved"];
                return;
            }

            // First try Apple's purpose-specific unlink extension on the whole hard-bounded tree.
            if ([self consumeSafeMoveExtensionForPath:SRRootPath prefix:YES]) {
                (void)[self controlledSiblingUnlinkAtParent:parent];
                if ([self tryUnlinkOriginal:file stage:@"After safe-move PREFIX"]) {
                    self.proofVerified = YES;
                    [self appendLog:@"PROOF SUCCESS: safe-move prefix extension enabled real unlink. Mass delete unlocked."];
                    [self setBusy:NO status:@"Deletion proved"];
                    return;
                }
            }

            // Pin every ancestor that needs an in-memory APFS flag repair until the proof syscall finishes.
            NSMutableArray<NSNumber *> *heldFDs = [NSMutableArray array];
            BOOL repairFailure = NO;
            BOOL anyFlagRepair = NO;
            for (NSString *d in dirs) {
                int held = -1;
                BOOL changed = NO;
                if (![self clearBlockingFlagsAtPath:d keepFD:&held changed:&changed]) {
                    struct stat st;
                    if (lstat(d.fileSystemRepresentation, &st) == 0 && ((uint32_t)st.st_flags & SRBlockingFlags)) {
                        repairFailure = YES;
                        [self appendLog:[NSString stringWithFormat:@"Could not safely clear blocking directory flags: %@", d]];
                        break;
                    }
                }
                if (held >= 0) [heldFDs addObject:@(held)];
                anyFlagRepair |= changed;
            }

            int fileHeld = -1;
            BOOL fileChanged = NO;
            if (!repairFailure && ![self clearBlockingFlagsAtPath:file keepFD:&fileHeld changed:&fileChanged]) {
                struct stat st;
                if (lstat(file.fileSystemRepresentation, &st) == 0 && ((uint32_t)st.st_flags & SRBlockingFlags)) repairFailure = YES;
            }
            anyFlagRepair |= fileChanged;

            if (!repairFailure) {
                (void)[self controlledSiblingUnlinkAtParent:parent];
                if ([self tryUnlinkOriginal:file stage:@"After flag repair"]) {
                    self.proofVerified = YES;
                    self.proofNeededFlagRepair = anyFlagRepair;
                    [self appendLog:@"PROOF SUCCESS: guarded flag repair enabled real unlink. Mass delete unlocked."];
                }
            }

            if (!self.proofVerified && !repairFailure) {
                BOOL anyMACL = NO;
                for (NSString *d in dirs) {
                    BOOL c = NO;
                    (void)[self removeMACLIfPresent:d changed:&c];
                    anyMACL |= c;
                }
                BOOL fc = NO;
                (void)[self removeMACLIfPresent:file changed:&fc];
                anyMACL |= fc;
                if (anyMACL && [self tryUnlinkOriginal:file stage:@"After MACL cleanup"]) {
                    self.proofVerified = YES;
                    self.proofNeededFlagRepair = anyFlagRepair;
                    self.proofNeededMACLRemoval = YES;
                    [self appendLog:@"PROOF SUCCESS: metadata cleanup enabled real unlink. Mass delete unlocked."];
                }
            }

            if (fileHeld >= 0) close(fileHeld);
            for (NSNumber *n in heldFDs) close(n.intValue);

            if (self.proofVerified) {
                [self setBusy:NO status:@"Deletion proved"];
            } else {
                [self appendLog:@"PROOF FAILED: file still exists. Mass delete remains locked; no bulk mutation was attempted."];
                [self setBusy:NO status:@"Deletion still blocked"];
            }
        }
    });
}

#pragma mark - Full delete

- (BOOL)prepareOpenFDForDeletion:(int)fd path:(NSString *)path stats:(SRDeleteStats *)stats
{
    struct stat st;
    if (fstat(fd, &st) != 0) return NO;
    uint32_t blockers = (uint32_t)st.st_flags & SRBlockingFlags;
    if (blockers) {
        uint32_t wanted = (uint32_t)st.st_flags & ~blockers;
        BOOL fixed = NO;
        if (chflags(path.fileSystemRepresentation, wanted) == 0) {
            struct stat v;
            if (fstat(fd, &v) == 0 && (((uint32_t)v.st_flags & blockers) == 0)) fixed = YES;
        }
        if (!fixed) fixed = [self kernelClearBlockingFlagsOnFD:fd path:path statBefore:&st];
        if (!fixed) return NO;
        if (stats) stats->repairedFlags++;
    }
    if (self.proofNeededMACLRemoval) {
        BOOL c = NO;
        (void)[self removeMACLIfPresent:path changed:&c];
        if (c && stats) stats->removedMACL++;
    }
    return YES;
}

- (BOOL)deleteLeaf:(NSString *)path stats:(SRDeleteStats *)stats consecutive:(NSUInteger *)consecutive
{
    if (self.cancelRequested || !SRPathAllowed(path)) return NO;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return errno == ENOENT;
    uint64_t allocated = SRAllocatedBytes(&st);

    int fd = -1;
    if (!S_ISLNK(st.st_mode)) {
        fd = open(path.fileSystemRepresentation, O_RDONLY);
        if (fd >= 0 && ![self prepareOpenFDForDeletion:fd path:path stats:stats]) {
            close(fd);
            fd = -1;
        }
    }

    if (S_ISLNK(st.st_mode) && ((uint32_t)st.st_flags & SRBlockingFlags)) {
        uint32_t wanted = (uint32_t)st.st_flags & ~((uint32_t)st.st_flags & SRBlockingFlags);
        (void)lchflags(path.fileSystemRepresentation, wanted);
    }

    errno = 0;
    int rc = unlink(path.fileSystemRepresentation);
    int e = rc == 0 ? 0 : errno;
    BOOL gone = SRGone(path);
    if (fd >= 0) close(fd);

    if (rc == 0 && gone) {
        stats->removedFiles++;
        stats->recoveredBytes += allocated;
        *consecutive = 0;
        if ((stats->removedFiles % 250) == 0) {
            [self appendLog:[NSString stringWithFormat:@"Progress: %lu files removed · %@ verified allocated bytes · failures=%lu",
                             (unsigned long)stats->removedFiles,
                             SRFormatBytes(stats->recoveredBytes),
                             (unsigned long)stats->failures]];
        }
        return YES;
    }

    stats->failures++;
    (*consecutive)++;
    if (*consecutive <= 5) {
        [self appendLog:[NSString stringWithFormat:@"DELETE FAIL #%lu: errno=%d (%s) path=%@",
                         (unsigned long)*consecutive, e, e ? strerror(e) : "unknown", path]];
    }
    return NO;
}

- (BOOL)deleteDirectoryRecursive:(NSString *)path stats:(SRDeleteStats *)stats consecutive:(NSUInteger *)consecutive
{
    if (self.cancelRequested || *consecutive >= 20 || !SRPathAllowed(path)) return NO;

    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return errno == ENOENT;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return [self deleteLeaf:path stats:stats consecutive:consecutive];

    DIR *d = opendir(path.fileSystemRepresentation);
    if (!d) {
        stats->failures++;
        (*consecutive)++;
        [self appendLog:[NSString stringWithFormat:@"opendir failed during delete: errno=%d (%s) path=%@", errno, strerror(errno), path]];
        return NO;
    }

    int dfd = dirfd(d);
    if (dfd >= 0 && ![self prepareOpenFDForDeletion:dfd path:path stats:stats]) {
        [self appendLog:[NSString stringWithFormat:@"Directory metadata repair could not be verified: %@", path]];
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        NSString *n = SRNameFromDirent(e);
        if (n.length) [names addObject:n];
    }

    for (NSString *n in names) {
        if (self.cancelRequested || *consecutive >= 20) break;
        @autoreleasepool {
            NSString *c = [path stringByAppendingPathComponent:n];
            if (!SRPathAllowed(c)) continue;
            struct stat cs;
            if (lstat(c.fileSystemRepresentation, &cs) != 0) continue;
            if (S_ISDIR(cs.st_mode) && !S_ISLNK(cs.st_mode))
                [self deleteDirectoryRecursive:c stats:stats consecutive:consecutive];
            else
                [self deleteLeaf:c stats:stats consecutive:consecutive];
        }
    }

    BOOL allChildrenProcessed = !self.cancelRequested && *consecutive < 20;
    if (allChildrenProcessed) {
        errno = 0;
        int rr = rmdir(path.fileSystemRepresentation); // while d is still open, keeping repaired vnode pinned
        int re = rr == 0 ? 0 : errno;
        if (rr == 0 || re == ENOENT) {
            stats->removedDirs++;
            *consecutive = 0;
        } else if (re != ENOTEMPTY) {
            stats->failures++;
            (*consecutive)++;
            [self appendLog:[NSString stringWithFormat:@"rmdir fail errno=%d (%s) path=%@", re, strerror(re), path]];
        }
    }
    closedir(d);
    return SRGone(path);
}

- (void)beginFullDelete
{
    if (self.busy || ![self requirePrepared:@"Full deletion"]) return;
    if (!self.proofVerified) {
        [self showMessage:@"Deletion Not Proven"
                  message:@"Run Prove One Real Delete first. Bulk deletion is intentionally locked until a real cache file disappears with ENOENT."];
        return;
    }

    NSString *msg = [NSString stringWithFormat:@"Permanently delete only %@ and its descendants? The verified deletion mechanism will be reused. The operation aborts after 20 consecutive failures.", SRRootPath];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Delete Test Directory?"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"DELETE" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [self runFullDelete];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runFullDelete
{
    if (self.busy) return;
    self.cancelRequested = NO;
    [self setBusy:YES status:@"Deleting verified tree…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint64_t freeBefore = SRFreeBytes();
        SRDeleteStats s = {0};
        NSUInteger consecutive = 0;
        [self appendLog:[NSString stringWithFormat:@"FULL DELETE START · free before=%@", SRFormatBytes(freeBefore)]];

        [self deleteDirectoryRecursive:SRRootPath stats:&s consecutive:&consecutive];

        BOOL rootGone = SRGone(SRRootPath);
        uint64_t freeAfter = SRFreeBytes();
        uint64_t delta = freeAfter > freeBefore ? freeAfter - freeBefore : 0;
        [self appendLog:[NSString stringWithFormat:@"FULL DELETE END · files=%lu dirs=%lu failures=%lu flagRepairs=%lu MACL=%lu verifiedAllocated=%@ freeDelta=%@ rootExists=%@",
                         (unsigned long)s.removedFiles,
                         (unsigned long)s.removedDirs,
                         (unsigned long)s.failures,
                         (unsigned long)s.repairedFlags,
                         (unsigned long)s.removedMACL,
                         SRFormatBytes(s.recoveredBytes), SRFormatBytes(delta),
                         rootGone ? @"NO" : @"YES"]];

        NSString *status = rootGone ? @"Deleted" : (self.cancelRequested ? @"Cancelled" : (consecutive >= 20 ? @"Aborted after failures" : @"Incomplete"));
        [self setBusy:NO status:status];
    });
}

- (void)cancelCurrent
{
    if (!self.busy) return;
    self.cancelRequested = YES;
    [self appendLog:@"Cancel requested. Current filesystem call will finish, then traversal stops."];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3;
    if (section == 1) return 5;
    return MAX((NSInteger)self.activityLines.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"Status";
    if (section == 1) return @"Recovery";
    return @"Activity";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1) return @"Safety boundary is hard-coded to /var/mobile/Documents/test. Kernel flag repair writes only after vnode/APFS metadata is cross-validated against fstat; a mismatch aborts before writing.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip
{
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        if (ip.row == 0) { c.textLabel.text = @"Target"; c.detailTextLabel.text = SRRootPath; c.detailTextLabel.adjustsFontSizeToFitWidth = YES; }
        else if (ip.row == 1) { c.textLabel.text = @"State"; c.detailTextLabel.text = self.busy ? @"Busy" : self.statusText; }
        else { c.textLabel.text = @"Last scan"; c.detailTextLabel.text = (self.scanStats.files || self.scanStats.dirs) ? [NSString stringWithFormat:@"%lu files · %@", (unsigned long)self.scanStats.files, SRFormatBytes(self.scanStats.allocatedBytes)] : @"Not scanned"; }
        return c;
    }

    if (ip.section == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        if (ip.row == 0) { c.textLabel.text = @"1. Prepare Access"; c.detailTextLabel.text = @"DarkSword KRW + SpringBoard root R/W extension."; }
        else if (ip.row == 1) { c.textLabel.text = @"2. Scan Target"; c.detailTextLabel.text = @"Read-only inventory and allocated bytes."; }
        else if (ip.row == 2) { c.textLabel.text = @"3. Prove One Real Delete"; c.detailTextLabel.text = @"safe-move → flags → guarded KRW metadata repair; verifies ENOENT."; }
        else if (ip.row == 3) {
            c.textLabel.text = @"4. DELETE Entire Test Directory";
            c.detailTextLabel.text = self.proofVerified ? @"UNLOCKED: a real original file was deleted and verified." : @"LOCKED until step 3 succeeds.";
            c.textLabel.textColor = self.proofVerified ? UIColor.systemRedColor : UIColor.tertiaryLabelColor;
        } else { c.textLabel.text = @"Cancel Current Operation"; c.detailTextLabel.text = self.busy ? @"Stops traversal after the current syscall." : @"No operation running."; }
        c.userInteractionEnabled = (ip.row == 4) ? self.busy : !self.busy;
        return c;
    }

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    c.textLabel.numberOfLines = 0;
    c.textLabel.text = self.activityLines.count ? self.activityLines[ip.row] : @"No activity yet.";
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;
    if (ip.row == 4) { [self cancelCurrent]; return; }
    if (self.busy) return;
    if (ip.row == 0) [self prepareAccess];
    else if (ip.row == 1) [self scanTarget];
    else if (ip.row == 2) [self proveDeletion];
    else if (ip.row == 3) [self beginFullDelete];
}

@end
