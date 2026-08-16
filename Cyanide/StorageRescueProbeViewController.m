#import "StorageRescueProbeViewController.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/kutils.h"
#import "kexploit/krw.h"
#import "kexploit/offsets.h"
#import "utils/sandbox.h"

#import <dirent.h>
#import <errno.h>
#import <string.h>
#import <unistd.h>
#import <sys/stat.h>

static NSString * const SRProbeRoot = @"/var/mobile/Documents/test";

@interface StorageRescueProbeViewController ()
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) NSString *stateText;
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@end

@implementation StorageRescueProbeViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _stateText = @"Ready to probe";
        _lines = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Permission Probe";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
    [self appendLine:@"Read-only diagnostic. This screen does not call unlink(), rmdir(), RemoteCall, patch_sandbox_ext(), or any kernel write primitive."];
    [self appendLine:[NSString stringWithFormat:@"Target: %@", SRProbeRoot]];
}

- (void)appendLine:(NSString *)line
{
    if (!line.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                          dateStyle:NSDateFormatterNoStyle
                                                          timeStyle:NSDateFormatterMediumStyle];
        [self.lines addObject:[NSString stringWithFormat:@"%@  %@", stamp, line]];
        while (self.lines.count > 120) [self.lines removeObjectAtIndex:0];
        if (self.isViewLoaded) [self.tableView reloadData];
    });
}

- (void)setBusyState:(BOOL)busy text:(NSString *)text
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = busy;
        if (text.length) self.stateText = text;
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

- (BOOL)pathAllowed:(NSString *)path
{
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    if ([path containsString:@".."]) return NO;
    NSString *safe = [path stringByStandardizingPath];
    return [safe isEqualToString:SRProbeRoot] || [safe hasPrefix:[SRProbeRoot stringByAppendingString:@"/"]];
}

- (NSString *)firstFileUnderTarget
{
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:SRProbeRoot];

    while (stack.count > 0) {
        @autoreleasepool {
            NSString *path = stack.lastObject;
            [stack removeLastObject];
            if (![self pathAllowed:path]) continue;

            struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) != 0) continue;
            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return path;

            DIR *dir = opendir(path.fileSystemRepresentation);
            if (!dir) continue;

            struct dirent *entry = NULL;
            while ((entry = readdir(dir)) != NULL) {
                if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
                NSString *name = [[NSFileManager defaultManager]
                                  stringWithFileSystemRepresentation:entry->d_name
                                  length:strlen(entry->d_name)];
                if (!name.length) continue;
                NSString *child = [path stringByAppendingPathComponent:name];
                if ([self pathAllowed:child]) [stack addObject:child];
            }
            closedir(dir);
        }
    }
    return nil;
}

- (void)runProbe
{
    if (self.busy) return;

    if (!kexploit_krw_ready() || check_sandbox_var_rw() != 0) {
        [self showMessage:@"Prepare Access First"
                  message:@"Open Storage Rescue, run Prepare Access successfully, then return here. The probe itself will not start DarkSword or change the sandbox."];
        return;
    }

    [self setBusyState:YES text:@"Finding test file…"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSString *file = [self firstFileUnderTarget];
            if (!file.length) {
                [self appendLine:@"No file could be found under the target directory."];
                [self setBusyState:NO text:@"No test file"];
                return;
            }

            [self appendLine:[NSString stringWithFormat:@"Testing sandbox policy for: %@", file]];

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
            NSUInteger allowed = 0;

            for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
                const char *name = candidates[i].name;
                uint64_t proc = proc_find_by_name(name);
                if (!proc || !is_kaddr_valid(proc)) {
                    [self appendLine:[NSString stringWithFormat:@"%-18s  not found", name]];
                    continue;
                }

                pid_t pid = (pid_t)kread32(proc + off_proc_p_pid);
                if (pid <= 0) {
                    [self appendLine:[NSString stringWithFormat:@"%-18s  invalid pid", name]];
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
                if (ul == 0) allowed++;

                [self appendLine:[NSString stringWithFormat:@"%-18s pid=%d  read=%@ write=%@ unlink=%@  rc=(%d,%d,%d) errno=(%d,%d,%d)",
                                  name, pid, rdText, wrText, ulText,
                                  rd, wr, ul, rdErr, wrErr, ulErr]];
            }

            [self appendLine:[NSString stringWithFormat:@"Probe complete: %lu candidates found; %lu report unlink ALLOW.",
                              (unsigned long)found, (unsigned long)allowed]];
            [self setBusyState:NO text:allowed ? @"Candidate found" : @"No candidate"];
        }
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 2;
    if (section == 1) return 1;
    return MAX((NSInteger)self.lines.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"Status";
    if (section == 1) return @"Diagnostic";
    return @"Activity";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Target";
            cell.detailTextLabel.text = SRProbeRoot;
            cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        } else {
            cell.textLabel.text = @"State";
            cell.detailTextLabel.text = self.busy ? @"Busy" : self.stateText;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"Run Permission Probe";
        cell.detailTextLabel.text = @"Read-only sandbox_check() against candidate system processes.";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = !self.busy;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.text = self.lines.count ? self.lines[indexPath.row] : @"No activity yet.";
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0 && !self.busy) [self runProbe];
}

@end
