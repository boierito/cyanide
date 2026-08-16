# Storage Rescue for iOS

Storage Rescue is a dedicated iOS recovery utility for deleting data that can still be read or moved but refuses to be removed normally.

It is built from the Cyanide / DarkSword kernel research stack and was created after encountering a real filesystem tree where normal `unlink(2)` returned `EPERM` even though the files were readable, writable, and owned by `mobile`.

> **Destructive tool. There is no undo. Read the staging instructions before using it.**

## The staging rule

Storage Rescue intentionally operates on **one hard-coded directory only**:

```text
/var/mobile/Documents/test
```

Before opening the deletion workflow:

1. Use Filza or another compatible filesystem manager.
2. Move **only the files or folders you actually want to permanently delete** into `/var/mobile/Documents/test`.
3. Do **not** move `/var/mobile/Documents` itself, your whole Library, an application container you still need, or unrelated system data.
4. Return to Storage Rescue and run the verification workflow.

The app rejects deletion paths outside the hard-coded target. This is deliberate: Storage Rescue is not intended to be a general-purpose root file manager.

## Workflow

The app launches directly into Storage Rescue. There are no tweak-store, package, source, or general Cyanide screens in the dedicated build.

Use the actions in this order:

### 1. Prepare Access

Initializes or recovers the DarkSword kernel read/write primitive and obtains the filesystem access required by the recovery flow.

The Storage Rescue implementation does **not** use the older aggressive `patch_sandbox_ext()` path that was found to be unstable during development.

### 2. Scan Target

Recursively scans `/var/mobile/Documents/test` using filesystem APIs and reports:

- file count
- directory count
- logical size
- allocated size
- scan errors

Scanning does not delete anything.

### 3. Prove One Real Delete

Before mass deletion is enabled, Storage Rescue must successfully remove one original staged file and verify that it is physically gone.

The proof is not based on a sandbox permission query or an Objective-C `isDeletable` result. Success requires an actual deletion followed by:

```text
lstat(path) -> ENOENT
```

The recovery path can evaluate and repair deletion-blocking filesystem state, including BSD/APFS flags such as:

- `UF_IMMUTABLE`
- `UF_APPEND`
- `UF_NOUNLINK`
- `UF_DATAVAULT`
- `SF_IMMUTABLE`
- `SF_APPEND`
- `SF_RESTRICTED`
- `SF_NOUNLINK`

It can also evaluate the relevant sandbox-extension path and `com.apple.macl` metadata when needed.

### Guarded KRW repair

If normal metadata operations are rejected and kernel read/write is required, Storage Rescue does not blindly write a hard-coded vnode field.

Before modifying the APFS BSD flags field it cross-checks the pinned vnode/fsnode against the userspace `stat` result, including:

- UID
- GID
- mode
- BSD flags
- inode identity during verification

If the expected layout does not agree, the operation stops with a guard failure and no delete is attempted.

### 4. Delete Entire Test Directory

This action stays locked until step 3 has proven a real deletion.

Once unlocked, Storage Rescue processes the staged tree with filesystem deletion primitives:

- `unlink(2)` for files and symlinks
- `rmdir(2)` for directories

It verifies failures and stops rather than continuing indefinitely when the recovery mechanism is no longer working.

## Why `write` is not enough

Being able to write file contents does not necessarily mean the process can remove the directory entry. During development, both Cyanide and SpringBoard could read/write the test tree while real `unlink()` calls still returned:

```text
EPERM (Operation not permitted)
```

Likewise, a basic `sandbox_check(..., "file-write-unlink", ...)` query reported `ALLOW` for processes whose real syscall still failed. For that reason, Storage Rescue treats the actual syscall plus `ENOENT` verification as the source of truth.

## Safety model

The dedicated build is intentionally narrow:

- hard boundary: `/var/mobile/Documents/test`
- no arbitrary path picker
- no recursive delete outside that boundary
- mass deletion locked until one real file is removed and verified
- no automatic `patch_sandbox_ext()` kernel mutation
- guarded APFS metadata repair
- no inherited-method swizzling for the Storage Rescue UI
- user must manually stage the intended data first

Symlinks are treated as filesystem entries and are not followed for the kernel metadata repair path.

## Real-world validation

The recovery flow was developed against a real cache tree containing more than 100,000 files and tens of gigabytes of allocated data. The final guarded solver successfully removed files that previously returned `EPERM` through both local and SpringBoard `unlink()` attempts.

This does not mean every iOS version, device, filesystem state, or corruption scenario is supported. Kernel offsets and exploit behavior are version/device dependent.

## Install

Prebuilt unsigned IPAs are published under GitHub Releases when available.

The IPA still needs to be signed/sideloaded using a compatible method for the target device. Storage Rescue does not include an Apple distribution signature.

## Build

```sh
./scripts/build.sh
```

The build script writes the unsigned application to:

```text
build/Cyanide.ipa
```

The `Storage Rescue IPA` GitHub Actions workflow packages that binary as `Storage-Rescue.ipa`.

## Development notes

The original problem was not solved by:

- `chmod`
- `chown`
- moving the tree within the same APFS volume
- `NSFileManager removeItemAtPath:`
- local `unlink()` with a normal read/write sandbox extension
- SpringBoard RemoteCall `unlink()`
- trusting `sandbox_check()` alone

The working recovery path was kept behind explicit validation checks because incorrect vnode/APFS writes can panic or reboot the device.

## Credits

Storage Rescue is built on work from the Cyanide and DarkSword ecosystem.

- [`zeroxjf`](https://github.com/zeroxjf) — Cyanide project and integration work this fork derives from.
- [`opa334`](https://github.com/opa334) — original DarkSword kernel exploit work, ChOma and XPF components.
- [`wh1te4ever`](https://github.com/wh1te4ever) — `darksword-kexploit-fun` / RemoteCall work used by Cyanide.
- [`rooootdev`](https://github.com/rooootdev) — exploit behavior referenced by the Cyanide project for reliability work.
- Cyanide's upstream contributors and the researchers credited in the original project history.

The repository history is intentionally preserved so the provenance of the exploit, RemoteCall, and supporting research remains visible.

## License

This repository remains licensed under **AGPL-3.0**. See `LICENSE`.

## Disclaimer

Storage Rescue modifies filesystem metadata and permanently removes files. Kernel exploitation and incorrect filesystem metadata changes can crash, panic, or reboot a device and may cause data loss.

Only stage data you have deliberately chosen to destroy, keep backups of anything important, and do not modify the hard-coded safety boundary unless you understand the consequences.
