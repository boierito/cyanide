<p align="center">
  <img src="Cyanide/Assets.xcassets/AppIcon.appiconset/icon-ios-1024x1024.png" alt="Cyanide" width="150">
</p>

<h1 align="center">Cyanide — Storage Rescue Fork</h1>

<p align="center">
  iOS kernel research toolkit based on DarkSword, with a verified storage-recovery workflow for files that normal file managers cannot unlink.
</p>

> **Status:** public research fork. The original Cyanide project is no longer actively maintained by its original author. This fork preserves the original project and adds a practical, guarded Storage Rescue workflow.

## Why this fork exists

This fork was created after encountering a real iOS storage problem: a very large cache tree could be read, moved and inspected, but could not be deleted by normal jailed file managers even though ownership and POSIX permissions looked correct.

The final solution was not another `chmod`, `chown`, trash implementation, or `NSFileManager` wrapper. The working path required a verified native `unlink(2)` flow plus inspection and repair of the metadata that can block namespace deletion on APFS.

The result is **Storage Rescue**, integrated directly into Cyanide.

## Storage Rescue

Open:

`Settings → Storage`

The current solver uses a deliberately narrow safety boundary:

```text
/var/mobile/Documents/test
```

It will not operate outside that tree.

### Recovery workflow

Storage Rescue is intentionally staged:

1. **Prepare Access**
   - Starts or reuses the DarkSword kernel read/write primitive.
   - Requests a SpringBoard-issued root read/write sandbox extension.
   - Verifies access before continuing.

2. **Scan Target**
   - Walks the target tree without modifying it.
   - Counts files and directories.
   - Reports logical and allocated size.

3. **Prove One Real Delete**
   - Selects one real file from the target tree.
   - Attempts a native `unlink(2)`.
   - Can request Apple's `com.apple.private.safe-move.receive` extension when needed.
   - Inspects BSD/APFS flags on the file and its parent chain.
   - Detects blocking flags such as:
     - `UF_IMMUTABLE`
     - `UF_APPEND`
     - `UF_NOUNLINK`
     - `UF_DATAVAULT`
     - `SF_IMMUTABLE`
     - `SF_APPEND`
     - `SF_RESTRICTED`
     - `SF_NOUNLINK`
   - Tries normal `chflags()` first.
   - Falls back to a guarded KRW metadata repair only when the APFS vnode layout can be cross-validated against `stat()` / `fstat()`.
   - Checks `com.apple.macl` where relevant.
   - Declares success only after `lstat()` confirms `ENOENT`.

4. **DELETE Entire Test Directory**
   - Remains locked until step 3 has physically removed and verified one original file.
   - Uses `unlink()` for files and `rmdir()` for directories.
   - Stops instead of blindly continuing through repeated failures.
   - Measures free space before and after the operation.

The important distinction is that the UI does **not** treat `sandbox_check == ALLOW`, `isWritableFileAtPath:`, or `isDeletableFileAtPath:` as proof of success. The file must actually disappear from the filesystem namespace.

## KRW safety guard

The metadata-repair path is intentionally conservative.

Before writing APFS metadata, Cyanide obtains the vnode for an already-open file descriptor and validates the filesystem node against userspace metadata. UID, GID, mode and BSD flags must all match the corresponding `stat`/`fstat` values.

If that validation fails, the solver logs:

```text
KRW GUARD ABORT
```

and performs **no kernel write** for that object.

After a repair, the value is read back and the inode and other metadata are checked again before deletion is attempted.

This is important because APFS structure offsets are version-sensitive; a guessed write is not an acceptable recovery strategy.

## What this is for

Storage Rescue is intended for recovery/debugging cases where:

- a cache or temporary-data tree is consuming significant storage;
- the files are visible and readable;
- ownership and normal POSIX permissions appear valid;
- standard deletion APIs or jailed file managers still return `EPERM` or otherwise fail;
- you control the device and understand what is being removed.

It is **not** intended as a generic "delete anything on iOS" button. The hard path boundary exists on purpose.

## Current implementation notes

The solver currently uses:

- DarkSword kernel R/W;
- Cyanide's vnode/APFS helpers;
- SpringBoard RemoteCall;
- sandbox extensions;
- native `unlink(2)` and `rmdir(2)`;
- BSD/APFS flag inspection and guarded repair;
- xattr inspection for `com.apple.macl`;
- post-operation filesystem verification.

The original Cyanide tweak runner remains in the repository as well.

## Supported exploit window

The upstream Cyanide code targets the DarkSword-compatible iOS/iPadOS range documented by the original project. Kernel exploit compatibility is device- and OS-version-dependent and can change across builds.

Do not assume that a build working on one device/OS combination implies compatibility with another.

## Build

The repository includes the normal Cyanide build script:

```sh
./scripts/build.sh
```

It produces an unsigned IPA at:

```text
build/Cyanide.ipa
```

A dedicated GitHub Actions workflow is also included:

```text
.github/workflows/storage-rescue.yml
```

The workflow builds and uploads an unsigned Storage Rescue IPA artifact.

Equivalent manual build:

```sh
xcodebuild \
  -project Cyanide.xcodeproj \
  -scheme Cyanide \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

You still need an appropriate signing/sideloading method to install the resulting application on a device.

## Important warning

This repository contains low-level iOS kernel and filesystem research code.

Incorrect filesystem metadata writes can corrupt data or make a device unstable. Keep backups of anything important. Do not remove system files simply because the tool can access them, and do not weaken the path guards without understanding the consequences.

Storage Rescue was designed around the principle: **prove one real deletion safely before allowing a recursive operation**.

## Project lineage and credits

This repository is a fork and builds on substantial work by other researchers and developers.

- [`zeroxjf/cyanide`](https://github.com/zeroxjf/cyanide) — original Cyanide project and UI/tweak framework.
- [`opa334/darksword-kexploit`](https://github.com/opa334/darksword-kexploit) — DarkSword kernel R/W primitive and related research.
- [`wh1te4ever/darksword-kexploit-fun`](https://github.com/wh1te4ever/darksword-kexploit-fun) — RemoteCall-based experimentation used by Cyanide.
- [`d1y/cyanide-ios`](https://github.com/d1y/cyanide-ios) — additional Cyanide-related AGPL work used by upstream ports.
- [`kolbicz/DarkSword-Tweaks`](https://github.com/kolbicz/DarkSword-Tweaks) — DarkSword tweak research used by upstream Cyanide.
- `rooootdev`, `neonmodder123`, `rpetrich`, Julio Verne, `tomt000`, `YangJiiii`, `@Little_34306`, `ezzuldinSt` and the other contributors credited by the original Cyanide project.

The Storage Rescue implementation in this fork was developed from a real recovery/debugging case and integrated on top of those existing primitives.

## Contributing

Useful contributions include:

- testing on additional supported device / iOS combinations;
- documenting reproducible `EPERM` filesystem cases;
- improving metadata validation before KRW writes;
- reducing reliance on hard-coded structure assumptions;
- adding tests that prove a deletion actually occurred rather than trusting permission checks;
- improving error reporting without weakening safety boundaries.

When reporting a Storage Rescue issue, include the relevant Activity log, iOS version, device model, and the exact stage that failed. Avoid uploading personal file contents.

## License

This repository is licensed under **AGPL-3.0**, consistent with the upstream project. See [`LICENSE`](LICENSE).

Forks and redistributed modifications must continue to comply with the applicable license terms and preserve upstream attribution.
