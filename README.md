# Storage Rescue for iOS

Storage Rescue is a dedicated iOS cache-recovery and cleanup utility built from the Cyanide / DarkSword research stack.

It was created for filesystem data that can still be read or moved but may refuse normal deletion with `EPERM`. The current app combines a limited per-app cache cleaner with the guarded Storage Rescue solver.

> **Destructive tool. There is no undo. Review every selected item before cleaning or staging it.**

## Cache browser

The main screen has three modes:

### Apps

Storage Rescue enumerates application data containers and calculates removable cache usage per app.

The allowed per-app scope is deliberately limited to:

```text
<app container>/Library/Caches
<app container>/tmp
```

Apps with no data in those locations are omitted from the list. Results are sorted by recoverable size and can be searched by app name or bundle identifier.

Normal app cache is removed **in place**. Storage Rescue preserves the `Library/Caches` and `tmp` root directories and removes only their contents.

If direct POSIX deletion is denied, the remaining top-level cache entries can be staged into the Storage Rescue target and passed to the guarded solver.

### Discarded

Storage Rescue also checks the optional CacheDelete location:

```text
/var/mobile/Library/Caches/com.apple.cache_delete/com.apple.CacheDeleteAppContainerCaches.discardedCaches
```

This directory does not necessarily exist on every device or at every moment. When present, its direct entries are scanned and listed by size. When absent, the UI reports that there is nothing there; Storage Rescue does **not** create this system-managed directory.

Selected discarded entries are moved with `rename(2)` into the staging target before solver deletion. On the same `/var` filesystem this is a metadata move rather than a second copy of the data.

### Staging

The guarded solver continues to operate only inside:

```text
/var/mobile/Documents/test
```

`Prepare Access` automatically creates this directory if it does not exist.

Moving data into `test` does **not** free space by itself. It is only a quarantine/staging step. The bytes are reclaimed only after the solver successfully removes the files.

## Recommended strategy

Use direct in-place cleanup for ordinary app caches. There is no reason to move healthy cache data first when a normal `unlink(2)` succeeds.

Use staging for protected or abandoned CacheDelete data, or as a fallback when an app cache returns deletion errors. Moving an entire protected subtree can succeed even when deleting individual protected leaf files does not; the solver can then operate inside its proven hard boundary.

## Prepare Access

Filesystem scanning and modification never start the exploit implicitly. Run `Prepare Access` first.

The access flow initializes or reuses DarkSword kernel read/write and obtains the filesystem access required by the recovery flow. It does **not** use the older aggressive `patch_sandbox_ext()` path that was found to be unstable during development.

After access is ready, Storage Rescue verifies the app-container root and creates `/var/mobile/Documents/test` if necessary.

## Guarded solver

The Solver is the recovery path for staged data that still refuses normal deletion.

Before mass deletion is enabled, it must successfully remove one real staged file and verify:

```text
unlink(path) == 0
lstat(path) -> ENOENT
```

It does not trust a theoretical `ALLOW`, `isDeletable`, or sandbox query as proof of deletion capability.

The recovery path can inspect and repair deletion-blocking BSD/APFS state including:

- `UF_IMMUTABLE`
- `UF_APPEND`
- `UF_NOUNLINK`
- `UF_DATAVAULT`
- `SF_IMMUTABLE`
- `SF_APPEND`
- `SF_RESTRICTED`
- `SF_NOUNLINK`

It can also evaluate the relevant sandbox-extension path and `com.apple.macl` metadata when needed.

### KRW guard

If userspace metadata operations are rejected and a kernel metadata write is required, Storage Rescue cross-checks the pinned vnode/fsnode against userspace metadata before writing anything:

- UID
- GID
- mode
- BSD flags
- inode identity during verification

If those values do not match the expected APFS layout, the operation aborts with no kernel write and no delete attempt.

## Safety boundaries

Storage Rescue intentionally separates the two cleanup modes:

- **App cleaner:** only validated application containers, and only `Library/Caches` + `tmp` contents.
- **Discarded CacheDelete:** only direct children of the known `discardedCaches` path can be staged.
- **Solver:** only `/var/mobile/Documents/test` and descendants.
- symlinks are never followed while scanning or traversing cache trees.
- mass solver deletion remains locked until a real staged-file deletion is proven.
- no automatic `patch_sandbox_ext()` mutation.

The app is not a general-purpose root file manager.

## Relationship to 3105

The app-cache browser is inspired by the limited-cleaner design in [`YangJiiii/3105`](https://github.com/YangJiiii/3105), whose cleaner deliberately limits per-app cleanup to `Library/Caches` and `tmp` and presents cache usage by application.

Storage Rescue uses its own Objective-C implementation and adds the DarkSword-based protected-file staging/solver workflow for cache trees that normal deletion cannot remove.

## Build

```sh
./scripts/build.sh
```

The unsigned IPA is written under `build/`, with `build/Cyanide.ipa` pointing at the latest build. The `Storage Rescue IPA` GitHub Actions workflow publishes the artifact as `Storage-Rescue.ipa`.

## Installation

The IPA is unsigned and must be signed/sideloaded with a compatible method for the target device.

## Credits

Storage Rescue is built on work from the Cyanide and DarkSword ecosystem.

- [`zeroxjf`](https://github.com/zeroxjf) — Cyanide project and integration work this fork derives from.
- [`opa334`](https://github.com/opa334) — original DarkSword kernel exploit work, ChOma and XPF components.
- [`wh1te4ever`](https://github.com/wh1te4ever) — `darksword-kexploit-fun` / RemoteCall work used by Cyanide.
- [`rooootdev`](https://github.com/rooootdev) — exploit behavior referenced by the Cyanide project for reliability work.
- [`YangJiiii/3105`](https://github.com/YangJiiii/3105) — reference for the deliberately limited per-app cache-cleaner model.
- Cyanide's upstream contributors and the researchers credited in the original project history.

## License

This repository remains licensed under **AGPL-3.0**. See `LICENSE`.

## Disclaimer

Storage Rescue modifies filesystem data and, in solver mode, may modify filesystem metadata. Kernel exploitation and incorrect low-level filesystem changes can crash, panic, or reboot a device and may cause data loss.

Use it only on devices and data you control. Close apps before clearing their cache, review selections carefully, and keep backups of anything important.
