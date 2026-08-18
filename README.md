# Storage Cleaner for iOS

Storage Cleaner is a dedicated iOS cache-cleaning utility built on the Cyanide / DarkSword research stack.

The user-facing cleaner has two areas:

- **Apps** — temporary per-app data inside `Library/Caches` and `tmp`.
- **System Cache** — compatible CacheDelete leftovers managed by iOS, when they exist.

The proven Cyanide/DarkSword Gain Access backend remains separate from the cleaner UI.

> **Cleanup is permanent. Review selections carefully and close apps before clearing their cache.**

## How to use

1. Open Storage Cleaner.
2. A short loading screen waits five seconds and starts **Gain Access automatically**.
3. When access succeeds, the app immediately starts the progressive Apps scan.
4. Use **Apps** or **System Cache**, select entries and confirm cleanup.

Nothing is deleted automatically.

## Safe startup

The five-second startup screen is deliberately simple. Before Gain Access finishes it performs only UIKit work, a main-thread countdown and reads of the existing access state.

It does **not** enumerate the filesystem, build an application catalog, query LaunchServices in the background or replace the Cyanide/DarkSword access implementation.

The call after the countdown is the inherited `prepareAccess` path used by the known-good 1.2.1 (12) build. On success that backend starts the existing progressive scan.

## Apps

App cleanup is deliberately limited to:

```text
<app container>/Library/Caches
<app container>/tmp
```

Photos, documents, messages, credentials, user-created files and normal application data are outside this path.

The app scanner is progressive: a small worker pool scans application containers and publishes results as each app finishes. The UI shows live processed-app counts and removable storage instead of waiting for the entire device scan to complete.

After a selected app is cleaned, only that app is rescanned and its row is updated immediately. Storage Cleaner does not perform a full-device rescan after every cleanup batch.

### Application names

The progressive scanner first asks LaunchServices for a friendly name. Some devices return only the bundle identifier, so Storage Cleaner performs a second, stronger lookup **only after Gain Access has completed and the initial scan is idle**.

That post-access lookup:

- catalogs installed `.app` bundles under the normal third-party and system application roots;
- reads `CFBundleDisplayName`, `CFBundleName` and `CFBundleExecutable` from bundle metadata;
- falls back to LaunchServices for bundle identifiers that are still unresolved;
- updates the record itself, so displayed names, search and name sorting can use the friendly name.

No device-wide app-bundle catalog walk runs before or during Gain Access.

## System Cache

System Cache checks the optional iOS CacheDelete leftovers directory:

```text
/var/mobile/Library/Caches/com.apple.cache_delete/com.apple.CacheDeleteAppContainerCaches.discardedCaches
```

This path is managed by iOS. It may not exist and may legitimately contain nothing. Storage Cleaner does not create fake entries just to populate the list.

System Cache is intentionally separated from normal app cache because these entries can have different filesystem behavior.

## Progressive scanner

The progressive app scanner is inspired by the cleaner behavior in [`YangJiiii/3105`](https://github.com/YangJiiii/3105).

The implementation:

- scans a limited number of application containers concurrently;
- publishes results as individual apps complete;
- shows scan counts and removable bytes while scanning;
- uses descriptor-relative filesystem traversal (`openat`, `fstatat`, `fdopendir`);
- updates cleaned apps individually instead of rebuilding the complete catalog.

## Gain Access

Gain Access uses the existing Cyanide/DarkSword backend proven on the target device.

The frontend deliberately does **not** override `updateChrome` or `scanCurrentMode`. The five-second automation only calls inherited `prepareAccess`; additional name-resolution work is gated until `prepared == YES` and `busy == NO`.

No files are deleted merely by enabling access.

## Bundle identity

The experimental 1.2.2 build uses:

```text
com.ai.StorageCleaner
```

The installed bundle identity comes from `StorageRescue.xcconfig` and is normalized into the final IPA `Info.plist` by the build script. The internal Xcode product and executable intentionally remain `Cyanide.app` / `Cyanide`, because inherited linker and runtime paths depend on that internal name.

## Protected-file fallback

The standalone **Protected Cleanup (Advanced)** menu entry is not exposed in the normal interface.

The underlying guarded recovery path remains in the project as a contextual fallback for selected data that genuinely cannot be removed normally.

## Safety boundaries

- App cleanup only targets `Library/Caches` and `tmp` inside validated app containers.
- System Cache only uses direct children of the known CacheDelete leftovers path.
- Symlinks are not followed while scanning or cleaning cache trees.
- The existing low-level recovery backend remains isolated behind its staging boundary.
- The cleaner is not a general-purpose root file manager.

## Build

```sh
./scripts/build.sh
```

The unsigned IPA is written under `build/`. GitHub Actions also produces a `Storage-Rescue` artifact containing the current Storage Cleaner IPA.

## Installation

The IPA is unsigned and must be signed/sideloaded using a compatible method for the target device.

## Credits

- [`zeroxjf`](https://github.com/zeroxjf) — Cyanide project and integration work this fork derives from.
- [`opa334`](https://github.com/opa334) — original DarkSword kernel exploit work, ChOma and XPF components.
- [`wh1te4ever`](https://github.com/wh1te4ever) — `darksword-kexploit-fun` / RemoteCall work used by Cyanide.
- [`rooootdev`](https://github.com/rooootdev) — exploit behavior referenced by Cyanide for reliability work.
- [`YangJiiii/3105`](https://github.com/YangJiiii/3105) — reference for the limited per-app cleaner and progressive-result model.
- Cyanide upstream contributors and the researchers credited in the original project history.

## License

This repository remains licensed under **AGPL-3.0**. See `LICENSE`.

## Disclaimer

Storage Cleaner permanently removes filesystem data and uses a kernel-exploit-based access backend. Incorrect low-level filesystem or kernel behavior can crash, panic or reboot a device and may cause data loss.

Use it only on devices and data you control, keep backups of important data, close apps before clearing their cache, and review selections before confirming cleanup.
