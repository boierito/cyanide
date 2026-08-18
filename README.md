# Storage Cleaner for iOS

Storage Cleaner is an iOS cache-cleaning utility built on the Cyanide / DarkSword research stack. The app focuses on a simple job: show removable temporary data progressively, let the user choose what to clean, and keep the low-level access backend isolated from the UI.

Current experimental version: **2.0.0 (15)**  
Bundle ID: `com.ai.StorageCleaner`

> **Cleanup is permanent. Close selected apps and review the list before confirming.**

## What it cleans

### Apps

Storage Cleaner only targets temporary per-app data inside:

```text
<app container>/Library/Caches
<app container>/tmp
```

Photos, documents, messages, credentials and normal user-created app data are outside this path.

### System Cache

The System Cache area checks compatible iOS CacheDelete leftovers under:

```text
/var/mobile/Library/Caches/com.apple.cache_delete/com.apple.CacheDeleteAppContainerCaches.discardedCaches
```

That directory is managed by iOS. It may not exist or may legitimately be empty.

## Startup flow

On the first launch after installation, Storage Cleaner shows a short onboarding screen explaining what the app does, how cleanup works and the main precautions. That guide is stored with a stable `NSUserDefaults` flag and is not shown again on later launches.

After onboarding — and on every normal launch afterwards — a fullscreen loading view waits five seconds and starts the existing Cyanide/DarkSword Gain Access path automatically.

The startup layer does not replace the access implementation. Before Gain Access finishes, it performs only UI/countdown work. Additional app-name catalog work waits until access is complete and the cleaner is idle.

## Progressive scanning

The Apps scanner is progressive and inspired by the cleaner behavior in [`YangJiiii/3105`](https://github.com/YangJiiii/3105):

- a small worker pool scans multiple app containers concurrently;
- results appear as each app finishes instead of after the entire device scan;
- the UI shows processed-app counts and removable bytes while scanning;
- descriptor-relative traversal uses `openat`, `fstatat` and `fdopendir`;
- after cleanup, only affected apps are rescanned instead of rebuilding the whole catalog.

## App names

The scanner first uses the name already available through the existing app metadata path. If a friendly name is still missing, Storage Cleaner performs a stronger lookup only after Gain Access and the initial scan are idle.

That post-access lookup can read `CFBundleDisplayName`, `CFBundleName` and `CFBundleExecutable` from installed app bundles and fall back to LaunchServices. The bundle ID remains searchable internally but is no longer shown as the primary row text in the cleaner UI.

## Interface

The normal UI is intentionally small:

- **Apps / System Cache** segmented control;
- live scan status and removable-size summary;
- search;
- sorting by size or name;
- per-item selection;
- selected-size summary and cleanup action;
- Help & Credits in the `•••` menu.

The old standalone **Protected Cleanup (Advanced)** screen is not exposed as a normal user-facing mode. The underlying guarded fallback remains available internally where the existing backend needs it.

## Gain Access

Gain Access remains the existing Cyanide/DarkSword backend. The cleaner frontend is designed around that implementation rather than replacing it.

The known-good access path remains inherited through `prepareAccess`; the progressive scanner and post-access name resolver are kept separate from the exploit-sensitive startup phase.

No files are deleted simply by enabling access.

## Bundle identity

The installed identity is defined in `StorageRescue.xcconfig`:

```text
com.ai.StorageCleaner
```

The build script normalizes that identity into the final IPA `Info.plist`. The internal Xcode product and executable intentionally remain `Cyanide.app` / `Cyanide` because inherited linker/runtime paths depend on that internal name.

## App icon

The iOS AppIcon uses the supplied Storage Cleaner artwork: a hard drive with a broom and a dark sword, referencing the cleaner purpose and DarkSword backend. The source artwork is cropped to full bleed before being exported to the iOS icon sizes so iOS applies the final rounded mask itself.

## Build

```sh
./scripts/build.sh
```

The IPA is unsigned and written under `build/`. GitHub Actions also produces a `Storage-Rescue` artifact for the current branch build.

## Safety boundaries

- App cleanup is limited to `Library/Caches` and `tmp` inside validated app containers.
- System Cache only uses the known CacheDelete leftovers path.
- Symlinks are not followed while scanning or cleaning cache trees.
- The low-level recovery backend remains isolated behind its existing staging boundary.
- Storage Cleaner is not a general-purpose root file manager.

## Credits

- [`boierito`](https://github.com/boierito) — Lucas Boiero; Storage Cleaner fork, product direction and integration.
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
