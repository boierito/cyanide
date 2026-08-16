from pathlib import Path

p = Path("Cyanide/tweaks/QuickLoader.m")
s = p.read_text()

if '#import <errno.h>' not in s:
    s = s.replace('#import <unistd.h>\n', '#import <unistd.h>\n#import <errno.h>\n', 1)

anchor = '        context[@"r_nsstr"] = ^NSString*(NSString *str) {'
if anchor not in s:
    raise SystemExit("QuickLoader bridge anchor not found")

bridge = r'''
        // ===============================================================
        // Storage Rescue bridge
        // HARD boundary: /var/mobile/Documents/test only.
        // Actual deletion uses POSIX unlink(2)/rmdir(2), never NSFileManager.
        // Tries Cyanide-local libc first, then the active RemoteCall target.
        // ===============================================================
        __block int32_t storageRescueLastErrno = 0;
        __block NSString *storageRescueLastBackend = @"none";

        BOOL (^storageRescuePathAllowed)(NSString *) = ^BOOL(NSString *path) {
            if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
            NSString *safe = [path stringByStandardizingPath];
            NSString *root = @"/var/mobile/Documents/test";
            if ([safe isEqualToString:root]) return YES;
            return [safe hasPrefix:[root stringByAppendingString:@"/"]];
        };

        int32_t (^storageRescueRemoteErrno)(void) = ^int32_t(void) {
            uint64_t errnoPtr = r_dlsym_call(R_TIMEOUT, "__error",
                                             0, 0, 0, 0, 0, 0, 0, 0);
            int32_t e = 0;
            if (errnoPtr) remote_read(errnoPtr, &e, sizeof(e));
            return e;
        };

        context[@"r_read_str"] = ^NSString*(JSValue *remoteValue) {
            if (!quickloader_generation_is_active(runGeneration)) return @"";
            uint64_t ptr = js_to_uint64(remoteValue);
            if (!ptr) return @"";
            char buf[4096];
            memset(buf, 0, sizeof(buf));
            if (!r_read_nsstring(ptr, buf, sizeof(buf))) return @"";
            NSString *out = [NSString stringWithUTF8String:buf];
            return out ?: @"";
        };

        context[@"sr_unlink"] = ^NSNumber*(NSString *path) {
            if (!quickloader_generation_is_active(runGeneration)) return @(-1);
            NSString *safe = [path stringByStandardizingPath];
            if (!storageRescuePathAllowed(safe)) {
                storageRescueLastErrno = EPERM;
                storageRescueLastBackend = @"blocked";
                log_user("[StorageRescue] BLOCK unlink: %s\n", path.UTF8String);
                return @(-1);
            }

            errno = 0;
            int localRC = unlink(safe.fileSystemRepresentation);
            int localErr = (localRC == 0) ? 0 : errno;
            if (localRC == 0) {
                storageRescueLastErrno = 0;
                storageRescueLastBackend = @"local";
                return @(0);
            }

            uint64_t remotePath = r_alloc_str(safe.UTF8String);
            if (!remotePath) {
                storageRescueLastErrno = localErr ? localErr : ENOMEM;
                storageRescueLastBackend = @"local";
                return @(-1);
            }

            uint64_t raw = r_dlsym_call(R_TIMEOUT, "unlink",
                                        remotePath, 0, 0, 0, 0, 0, 0, 0);
            int remoteRC = (int32_t)(uint32_t)raw;
            int remoteErr = (remoteRC == 0) ? 0 : storageRescueRemoteErrno();
            r_free(remotePath);

            storageRescueLastErrno = remoteErr;
            storageRescueLastBackend = @"remote";
            return @(remoteRC);
        };

        context[@"sr_rmdir"] = ^NSNumber*(NSString *path) {
            if (!quickloader_generation_is_active(runGeneration)) return @(-1);
            NSString *safe = [path stringByStandardizingPath];
            if (!storageRescuePathAllowed(safe)) {
                storageRescueLastErrno = EPERM;
                storageRescueLastBackend = @"blocked";
                log_user("[StorageRescue] BLOCK rmdir: %s\n", path.UTF8String);
                return @(-1);
            }

            errno = 0;
            int localRC = rmdir(safe.fileSystemRepresentation);
            int localErr = (localRC == 0) ? 0 : errno;
            if (localRC == 0) {
                storageRescueLastErrno = 0;
                storageRescueLastBackend = @"local";
                return @(0);
            }

            uint64_t remotePath = r_alloc_str(safe.UTF8String);
            if (!remotePath) {
                storageRescueLastErrno = localErr ? localErr : ENOMEM;
                storageRescueLastBackend = @"local";
                return @(-1);
            }

            uint64_t raw = r_dlsym_call(R_TIMEOUT, "rmdir",
                                        remotePath, 0, 0, 0, 0, 0, 0, 0);
            int remoteRC = (int32_t)(uint32_t)raw;
            int remoteErr = (remoteRC == 0) ? 0 : storageRescueRemoteErrno();
            r_free(remotePath);

            storageRescueLastErrno = remoteErr;
            storageRescueLastBackend = @"remote";
            return @(remoteRC);
        };

        context[@"sr_errno"] = ^NSNumber*() {
            return @(storageRescueLastErrno);
        };

        context[@"sr_backend"] = ^NSString*() {
            return storageRescueLastBackend ?: @"none";
        };

        context[@"sr_strerror"] = ^NSString*() {
            const char *msg = strerror(storageRescueLastErrno);
            return msg ? [NSString stringWithUTF8String:msg] : @"unknown";
        };
'''

s = s.replace(anchor, bridge + "\n" + anchor, 1)
p.write_text(s)
print("Storage Rescue POSIX bridges injected into QuickLoader.m")
