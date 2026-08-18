# Storage Cleaner for iOS

Storage Cleaner is a dedicated iOS cache-cleaning utility built on the Cyanide / DarkSword research stack.

The user-facing cleaner has two areas:

- **Apps** — temporary per-app data inside `Library/Caches` and `tmp`.
- **System Cache** — compatible CacheDelete leftovers managed by iOS, when they exist.

The proven Cyanide/DarkSword Gain Access backend remains separate from the cleaner UI.

> **Cleanup is permanent. Review selections carefully and close apps before clearing their cache.**

## How to use

1. Open Storage Cleaner and read the short startup guide.
2. Tap **Enable Access** once for the current launch.
3. Use **Apps** or **System Cache**.
4. Select the entries you want to remove.
5. Confirm the cleanup.

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

The progressive scanner first asks LaunchServices for the friendly app name. If the result is still only the bundle identifier, the corrected 1.2.1 frontend may inspect that app's own bundle metadata **only after Gain Access has fully completed and while no scan or cleanup is running**.

There is no device-wide app-bundle catalog walk before or during Gain Access.

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

**Enable Access** uses the existing Cyanide/DarkSword backend already proven on the target device.

The corrected 1.2.1 frontend deliberately does **not** override `updateChrome` or `scanCurrentMode`, and starts no filesystem enumeration, LaunchServices catalog scan, or asynchronous resolver before/during Gain Access.

No files are deleted merely by enabling access.

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
