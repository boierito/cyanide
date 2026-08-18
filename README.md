# StorageCleanerDS

**StorageCleanerDS** is an iOS cache-cleaning utility built on the Cyanide / DarkSword research stack. It scans removable temporary data progressively, shows results app by app, and lets the user decide exactly what to clean.

> Current release: **2.0.0 (15)**  
> Bundle ID: `com.ai.StorageCleaner`

StorageCleanerDS keeps the exploit-sensitive Gain Access path isolated from the cleaner UI. The frontend, progressive scanner, onboarding, app-name resolver and AppIcon are layered around the existing Cyanide/DarkSword backend instead of replacing it.

## Features

- Progressive per-app cache scanning with live results.
- Separate **Apps** and **System Cache** views.
- Friendly application names when they can be resolved safely.
- Search and sorting by name or removable size.
- Per-app selection and selected-size summary.
- Automatic Gain Access after a short fullscreen startup countdown.
- One-time onboarding on first launch after installation.
- Fullscreen startup state that hides the underlying cleaner controls until access is ready.
- Storage Cleaner / DarkSword app icon.
- Contextual protected-data fallback retained internally without exposing the old advanced screen as a normal workflow.

## What it cleans

### Apps

Only temporary per-app data under:

```text
<app container>/Library/Caches
<app container>/tmp
```

The cleaner is intentionally scoped away from photos, documents, messages, credentials and ordinary user-created app data.

### System Cache

The System Cache view checks compatible iOS CacheDelete leftovers under:

```text
/var/mobile/Library/Caches/com.apple.cache_delete/com.apple.CacheDeleteAppContainerCaches.discardedCaches
```

This directory is managed by iOS and may legitimately be missing or empty.

## Startup and Gain Access

On the **first launch after installation**, StorageCleanerDS shows a short onboarding screen explaining the workflow and precautions. A local `NSUserDefaults` flag prevents it from appearing again on later launches.

After onboarding — and on normal launches — a fullscreen startup screen waits five seconds and starts the existing Cyanide/DarkSword Gain Access path automatically.

The exploit-sensitive phase is deliberately isolated:

- no app-bundle filesystem walk runs before Gain Access;
- no LaunchServices catalog work runs during Gain Access;
- the progressive scanner and friendly-name resolver wait until access is complete and the cleaner is idle;
- enabling access itself does not delete files.

## Progressive scanner

The Apps scanner is progressive and was inspired by the cleaner behavior in [`YangJiiii/3105`](https://github.com/YangJiiii/3105):

- a small worker pool scans multiple app containers concurrently;
- rows appear as each app finishes rather than waiting for the whole device;
- processed-app count and removable bytes update while scanning;
- descriptor-relative traversal uses `openat`, `fstatat` and `fdopendir`;
- after cleanup, affected apps are rescanned instead of rebuilding the entire catalog.

## Friendly app names

The cleaner prefers a real application name over the final component of the bundle identifier.

When metadata is not already available, a post-access resolver may inspect installed application bundles and use:

- `CFBundleDisplayName`
- `CFBundleName`
- `CFBundleExecutable`
- LaunchServices as a fallback

The bundle identifier remains available internally for identification and search.

## Safety boundaries

StorageCleanerDS is intentionally **not** a general-purpose root file manager.

- App cleanup is limited to `Library/Caches` and `tmp` inside validated app containers.
- System Cache is limited to the known CacheDelete leftovers path.
- Symlinks are not followed while traversing cache trees.
- The low-level recovery backend remains behind its existing staging boundary.
- Destructive cleanup requires an explicit user selection and action.

## Internal identity

The installed bundle identifier is:

```text
com.ai.StorageCleaner
```

The internal Xcode product and executable intentionally remain `Cyanide.app` / `Cyanide`. Those internal names are preserved because inherited linker and runtime paths depend on them.

## App icon

The AppIcon uses the StorageCleanerDS artwork supplied for the 2.0 release: a hard drive crossed by a broom and a dark sword, referencing the cleaner purpose and DarkSword backend.

The build regenerates every iOS AppIcon size from the supplied source artwork so older Cyanide assets cannot be selected by SpringBoard.

## Build

```sh
./scripts/build.sh
```

The project produces an **unsigned IPA** under `build/`. GitHub Actions performs the same build and verifies bundle identity, runtime dependencies and the AppIcon asset catalog.

## 2.0.0 highlights

Version 2.0.0 consolidates the Storage Cleaner work into a cleaner user-facing product while preserving the known-good low-level backend:

- redesigned cleaner interface;
- progressive app-by-app scanning;
- automatic Gain Access with isolated five-second startup screen;
- one-time onboarding;
- real app-name resolution after access;
- separate Apps and System Cache modes;
- old Protected Cleanup view removed from the normal UI;
- updated StorageCleanerDS icon;
- bundle identity changed to `com.ai.StorageCleaner`;
- improved help, credits and safety copy;
- build-time checks intended to prevent frontend changes from altering the known-good Gain Access flow.

## Credits

- [`boierito`](https://github.com/boierito) — **Lucas Boiero**; StorageCleanerDS fork, product direction, integration and testing.
- [`zeroxjf`](https://github.com/zeroxjf) — Cyanide project and integration work this fork derives from.
- [`opa334`](https://github.com/opa334) — original DarkSword kernel exploit work, ChOma and XPF components.
- [`wh1te4ever`](https://github.com/wh1te4ever) — `darksword-kexploit-fun` / RemoteCall work used by Cyanide.
- [`rooootdev`](https://github.com/rooootdev) — exploit behavior referenced by Cyanide for reliability work.
- [`YangJiiii/3105`](https://github.com/YangJiiii/3105) — reference for the limited per-app cleaner and progressive-result model.
- Cyanide upstream contributors and the researchers credited in the original project history.

## License

This repository remains licensed under **AGPL-3.0**. See `LICENSE`.

## Disclaimer

StorageCleanerDS permanently removes filesystem data and relies on a kernel-exploit-based access backend. Incorrect low-level filesystem or kernel behavior can crash, panic or reboot a device and may cause data loss.

Use it only on devices and data you control. Keep backups of important data, close apps before clearing their cache and review selections before confirming cleanup.
