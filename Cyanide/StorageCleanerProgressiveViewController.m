#import "StorageCleanerProgressiveViewController.h"

#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

@interface StorageRescueDedicatedViewController (StorageCleanerProgressiveBackend)
- (void)scanCurrentMode;
- (void)updateChrome;
- (void)stageAppRecords:(NSArray *)records;
@end

static NSString * const SCProgressAppDataRoot = @"/var/mobile/Containers/Data/Application";

typedef struct {
    uint64_t allocatedBytes;
    uint64_t logicalBytes;
    NSUInteger files;
    NSUInteger dirs;
    NSUInteger errors;
} SCProgressUsage;

typedef struct {
    uint64_t removedAllocatedBytes;
    NSUInteger removedFiles;
    NSUInteger removedDirs;
    NSUInteger failures;
} SCProgressDeleteSummary;

static NSString *SCProgressFormatBytes(uint64_t bytes)
{
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseKB |
                             NSByteCountFormatterUseMB |
                             NSByteCountFormatterUseGB |
                             NSByteCountFormatterUseTB;
    return [formatter stringFromByteCount:(long long)bytes];
}

static BOOL SCProgressIsApplicationContainer(NSString *path)
{
    NSString *root = [SCProgressAppDataRoot stringByStandardizingPath];
    NSString *safe = [path stringByStandardizingPath];
    if (![safe hasPrefix:[root stringByAppendingString:@"/"]]) return NO;
    return [[NSUUID alloc] initWithUUIDString:safe.lastPathComponent] != nil;
}

static int SCProgressOpenRelativeDirectory(int rootFD, const char *first, const char *second)
{
    int current = dup(rootFD);
    if (current < 0) return -1;

    int next = openat(current, first, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(current);
    if (next < 0) return -1;
    current = next;

    if (second) {
        next = openat(current, second, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        close(current);
        if (next < 0) return -1;
        current = next;
    }
    return current;
}

static SCProgressUsage SCProgressScanDirectoryFD(int directoryFD)
{
    SCProgressUsage result = {0};
    int iterationFD = dup(directoryFD);
    if (iterationFD < 0) {
        result.errors++;
        return result;
    }

    DIR *directory = fdopendir(iterationFD);
    if (!directory) {
        close(iterationFD);
        result.errors++;
        return result;
    }

    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;

        struct stat st;
        if (fstatat(directoryFD, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT) result.errors++;
            continue;
        }

        if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
            result.dirs++;
            int childFD = openat(directoryFD,
                                 entry->d_name,
                                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (childFD < 0) {
                if (errno != ENOENT && errno != ELOOP) result.errors++;
                continue;
            }
            SCProgressUsage nested = SCProgressScanDirectoryFD(childFD);
            close(childFD);
            result.allocatedBytes += nested.allocatedBytes;
            result.logicalBytes += nested.logicalBytes;
            result.files += nested.files;
            result.dirs += nested.dirs;
            result.errors += nested.errors;
            continue;
        }

        result.files++;
        if (st.st_size > 0) result.logicalBytes += (uint64_t)st.st_size;
        result.allocatedBytes += (uint64_t)st.st_blocks * 512ULL;
    }

    closedir(directory);
    return result;
}

static SCProgressUsage SCProgressScanAllowedDirectory(int rootFD, const char *first, const char *second)
{
    int directoryFD = SCProgressOpenRelativeDirectory(rootFD, first, second);
    if (directoryFD < 0) return (SCProgressUsage){0};
    SCProgressUsage result = SCProgressScanDirectoryFD(directoryFD);
    close(directoryFD);
    return result;
}

static NSString *SCProgressBundleIdentifierForContainer(NSString *containerPath)
{
    NSString *metadataPath = [containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;

    NSArray<NSString *> *keys = @[@"MCMMetadataIdentifier", @"Identifier", @"CFBundleIdentifier"];
    for (NSString *key in keys) {
        id value = metadata[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }

    NSDictionary *info = [metadata[@"MCMMetadataInfo"] isKindOfClass:NSDictionary.class]
        ? metadata[@"MCMMetadataInfo"] : nil;
    for (NSString *key in keys) {
        id value = info[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *SCProgressApplicationDisplayName(NSString *bundleID)
{
    if (!bundleID.length) return @"Unknown App";

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
    });

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    id proxy = nil;
    if (proxyClass && [proxyClass respondsToSelector:proxySelector]) {
        id (*sendID)(id, SEL, id) = (void *)objc_msgSend;
        proxy = sendID((id)proxyClass, proxySelector, bundleID);
    }

    if (proxy) {
        id (*sendNoArg)(id, SEL) = (void *)objc_msgSend;
        for (NSString *selectorName in @[@"localizedName", @"itemName", @"bundleDisplayName"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![proxy respondsToSelector:selector]) continue;
            id value = sendNoArg(proxy, selector);
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        }
    }

    NSString *fallback = bundleID.pathExtension;
    return fallback.length ? fallback : bundleID;
}

static id SCProgressBuildAppRecord(NSString *containerPath, NSString *ownBundleID)
{
    if (!SCProgressIsApplicationContainer(containerPath)) return nil;

    NSString *bundleID = SCProgressBundleIdentifierForContainer(containerPath);
    if (!bundleID.length || [bundleID isEqualToString:ownBundleID]) return nil;

    int rootFD = open(containerPath.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (rootFD < 0) return nil;

    SCProgressUsage cache = SCProgressScanAllowedDirectory(rootFD, "Library", "Caches");
    SCProgressUsage temporary = SCProgressScanAllowedDirectory(rootFD, "tmp", NULL);
    close(rootFD);

    uint64_t total = cache.allocatedBytes + temporary.allocatedBytes;
    if (total == 0) return nil;

    Class recordClass = NSClassFromString(@"SRCacheRecord");
    id record = recordClass ? [[recordClass alloc] init] : nil;
    if (!record) return nil;

    [record setValue:bundleID forKey:@"identifier"];
    [record setValue:bundleID forKey:@"bundleID"];
    [record setValue:SCProgressApplicationDisplayName(bundleID) forKey:@"displayName"];
    [record setValue:containerPath forKey:@"containerPath"];
    [record setValue:containerPath forKey:@"sourcePath"];
    [record setValue:@(cache.allocatedBytes) forKey:@"cacheBytes"];
    [record setValue:@(temporary.allocatedBytes) forKey:@"temporaryBytes"];
    [record setValue:@(cache.files + temporary.files) forKey:@"itemCount"];
    [record setValue:@(cache.allocatedBytes > 0 || cache.files > 0 || cache.dirs > 0) forKey:@"cacheDirectoryExists"];
    [record setValue:@(temporary.allocatedBytes > 0 || temporary.files > 0 || temporary.dirs > 0) forKey:@"temporaryDirectoryExists"];
    [record setValue:@NO forKey:@"discarded"];
    return record;
}

static uint64_t SCProgressRecordBytes(id record)
{
    return [[record valueForKey:@"cacheBytes"] unsignedLongLongValue] +
           [[record valueForKey:@"temporaryBytes"] unsignedLongLongValue];
}

static NSArray *SCProgressSortRecords(NSArray *records)
{
    return [records sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        uint64_t leftBytes = SCProgressRecordBytes(left);
        uint64_t rightBytes = SCProgressRecordBytes(right);
        if (leftBytes > rightBytes) return NSOrderedAscending;
        if (leftBytes < rightBytes) return NSOrderedDescending;
        NSString *leftName = [left valueForKey:@"displayName"] ?: @"";
        NSString *rightName = [right valueForKey:@"displayName"] ?: @"";
        return [leftName localizedCaseInsensitiveCompare:rightName];
    }];
}

static SCProgressDeleteSummary SCProgressDeleteDirectoryContentsFD(int directoryFD)
{
    SCProgressDeleteSummary summary = {0};
    int iterationFD = dup(directoryFD);
    if (iterationFD < 0) {
        summary.failures++;
        return summary;
    }

    DIR *directory = fdopendir(iterationFD);
    if (!directory) {
        close(iterationFD);
        summary.failures++;
        return summary;
    }

    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;

        struct stat st;
        if (fstatat(directoryFD, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT) summary.failures++;
            continue;
        }

        if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
            int childFD = openat(directoryFD,
                                 entry->d_name,
                                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (childFD < 0) {
                if (errno != ENOENT && errno != ELOOP) summary.failures++;
                continue;
            }
            SCProgressDeleteSummary nested = SCProgressDeleteDirectoryContentsFD(childFD);
            close(childFD);
            summary.removedAllocatedBytes += nested.removedAllocatedBytes;
            summary.removedFiles += nested.removedFiles;
            summary.removedDirs += nested.removedDirs;
            summary.failures += nested.failures;

            errno = 0;
            if (unlinkat(directoryFD, entry->d_name, AT_REMOVEDIR) == 0 || errno == ENOENT) {
                summary.removedDirs++;
            } else if (errno != ENOTEMPTY) {
                summary.failures++;
            }
            continue;
        }

        uint64_t allocated = (uint64_t)st.st_blocks * 512ULL;
        errno = 0;
        if (unlinkat(directoryFD, entry->d_name, 0) == 0 || errno == ENOENT) {
            summary.removedFiles++;
            summary.removedAllocatedBytes += allocated;
        } else {
            summary.failures++;
        }
    }

    closedir(directory);
    return summary;
}

static SCProgressDeleteSummary SCProgressCleanAppContainer(NSString *containerPath)
{
    SCProgressDeleteSummary total = {0};
    if (!SCProgressIsApplicationContainer(containerPath)) {
        total.failures++;
        return total;
    }

    int rootFD = open(containerPath.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (rootFD < 0) {
        total.failures++;
        return total;
    }

    const char *components[][2] = {{"Library", "Caches"}, {"tmp", NULL}};
    for (NSUInteger index = 0; index < 2; index++) {
        int directoryFD = SCProgressOpenRelativeDirectory(rootFD,
                                                          components[index][0],
                                                          components[index][1]);
        if (directoryFD < 0) continue;
        SCProgressDeleteSummary result = SCProgressDeleteDirectoryContentsFD(directoryFD);
        close(directoryFD);
        total.removedAllocatedBytes += result.removedAllocatedBytes;
        total.removedFiles += result.removedFiles;
        total.removedDirs += result.removedDirs;
        total.failures += result.failures;
    }

    close(rootFD);
    return total;
}

@implementation StorageCleanerProgressiveViewController

- (BOOL)scProgressPrepared
{
    return [[self valueForKey:@"prepared"] boolValue];
}

- (BOOL)scProgressBusy
{
    return [[self valueForKey:@"busy"] boolValue];
}

- (NSMutableSet *)scProgressSelection
{
    id selection = [self valueForKey:@"selectedIdentifiers"];
    return [selection isKindOfClass:NSMutableSet.class] ? selection : nil;
}

- (void)scProgressRefreshUI
{
    [self updateChrome];
    [self.tableView reloadData];
}

- (void)scanCurrentMode
{
    NSInteger mode = [[self valueForKey:@"browserMode"] integerValue];
    if (mode != 0) {
        [super scanCurrentMode];
        return;
    }

    if ([self scProgressBusy]) return;
    if (![self scProgressPrepared]) {
        [super scanCurrentMode];
        return;
    }

    [self setValue:@YES forKey:@"busy"];
    [self setValue:@[] forKey:@"appRecords"];
    [[self scProgressSelection] removeAllObjects];
    [self setValue:@"Scanning apps…" forKey:@"statusText"];
    [self scProgressRefreshUI];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *containers = [NSMutableArray array];
        DIR *directory = opendir(SCProgressAppDataRoot.fileSystemRepresentation);
        if (directory) {
            struct dirent *entry;
            while ((entry = readdir(directory))) {
                if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                NSString *name = [NSString stringWithUTF8String:entry->d_name];
                if (!name.length || ![[NSUUID alloc] initWithUUIDString:name]) continue;
                NSString *container = [SCProgressAppDataRoot stringByAppendingPathComponent:name];
                if (SCProgressIsApplicationContainer(container)) [containers addObject:container];
            }
            closedir(directory);
        }

        NSUInteger totalCandidates = containers.count;
        __block NSUInteger processed = 0;
        NSString *ownBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t gate = dispatch_semaphore_create(3);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusText = [NSString stringWithFormat:@"Scanning 0/%lu apps…", (unsigned long)totalCandidates];
            [self scProgressRefreshUI];
        });

        for (NSString *container in containers) {
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
                id record = SCProgressBuildAppRecord(container, ownBundleID);
                dispatch_semaphore_signal(gate);

                dispatch_async(dispatch_get_main_queue(), ^{
                    processed++;
                    NSMutableArray *current = [[self valueForKey:@"appRecords"] mutableCopy] ?: [NSMutableArray array];
                    if (record) [current addObject:record];
                    NSArray *sorted = SCProgressSortRecords(current);
                    [self setValue:sorted forKey:@"appRecords"];

                    uint64_t totalBytes = 0;
                    for (id item in sorted) totalBytes += SCProgressRecordBytes(item);
                    self.statusText = [NSString stringWithFormat:@"Scanning %lu/%lu apps • %lu found • %@",
                                       (unsigned long)processed,
                                       (unsigned long)totalCandidates,
                                       (unsigned long)sorted.count,
                                       SCProgressFormatBytes(totalBytes)];
                    [self scProgressRefreshUI];
                });
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSArray *records = [self valueForKey:@"appRecords"] ?: @[];
            uint64_t totalBytes = 0;
            for (id item in records) totalBytes += SCProgressRecordBytes(item);
            [self setValue:@NO forKey:@"busy"];
            self.statusText = [NSString stringWithFormat:@"%lu apps • %@ removable",
                               (unsigned long)records.count,
                               SCProgressFormatBytes(totalBytes)];
            [self scProgressRefreshUI];
        });
    });
}

- (void)performCleanAppRecords:(NSArray *)records
{
    if ([self scProgressBusy] || records.count == 0) return;

    [self setValue:@YES forKey:@"busy"];
    [self setValue:@"Starting cleanup…" forKey:@"statusText"];
    [self scProgressRefreshUI];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SCProgressDeleteSummary total = {0};
        NSMutableArray *failedRecords = [NSMutableArray array];
        NSString *ownBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSUInteger appIndex = 0;

        for (id record in records) {
            appIndex++;
            NSString *displayName = [record valueForKey:@"displayName"] ?: @"App";
            NSString *containerPath = [record valueForKey:@"containerPath"] ?: @"";

            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusText = [NSString stringWithFormat:@"Cleaning %lu/%lu • %@",
                                   (unsigned long)appIndex,
                                   (unsigned long)records.count,
                                   displayName];
                [self scProgressRefreshUI];
            });

            SCProgressDeleteSummary result = SCProgressCleanAppContainer(containerPath);
            total.removedAllocatedBytes += result.removedAllocatedBytes;
            total.removedFiles += result.removedFiles;
            total.removedDirs += result.removedDirs;
            total.failures += result.failures;
            if (result.failures > 0) [failedRecords addObject:record];

            id refreshedRecord = SCProgressBuildAppRecord(containerPath, ownBundleID);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableArray *current = [[self valueForKey:@"appRecords"] mutableCopy] ?: [NSMutableArray array];
                NSString *identifier = [record valueForKey:@"identifier"];
                NSIndexSet *matching = [current indexesOfObjectsPassingTest:^BOOL(id item, NSUInteger idx, BOOL *stop) {
                    return identifier && [[item valueForKey:@"identifier"] isEqual:identifier];
                }];
                if (matching.count) [current removeObjectsAtIndexes:matching];
                if (refreshedRecord) [current addObject:refreshedRecord];
                [self setValue:SCProgressSortRecords(current) forKey:@"appRecords"];

                self.statusText = [NSString stringWithFormat:@"Cleaned %lu/%lu • %@ freed so far",
                                   (unsigned long)appIndex,
                                   (unsigned long)records.count,
                                   SCProgressFormatBytes(total.removedAllocatedBytes)];
                [self scProgressRefreshUI];
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setValue:@NO forKey:@"busy"];
            [[self scProgressSelection] removeAllObjects];
            self.statusText = [NSString stringWithFormat:@"Removed %lu items • %@ freed",
                               (unsigned long)(total.removedFiles + total.removedDirs),
                               SCProgressFormatBytes(total.removedAllocatedBytes)];
            [self scProgressRefreshUI];

            NSString *message = [NSString stringWithFormat:@"Removed %lu files/directories. Freed approximately %@.%@",
                                 (unsigned long)(total.removedFiles + total.removedDirs),
                                 SCProgressFormatBytes(total.removedAllocatedBytes),
                                 total.failures ? [NSString stringWithFormat:@"\n\n%lu operations were denied.", (unsigned long)total.failures] : @""];

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:total.failures ? @"Cleanup Finished with Protected Items" : @"Cleanup Complete"
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
            if (failedRecords.count > 0) {
                [alert addAction:[UIAlertAction actionWithTitle:@"Stage Remaining"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
                    [self stageAppRecords:failedRecords];
                }]];
            }
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end
