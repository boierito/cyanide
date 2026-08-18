# StorageCleanerDS

**StorageCleanerDS** is an iOS storage-cleaning app focused on finding and removing temporary cache data from installed apps and compatible iOS system caches.

It is built on top of the **Cyanide / DarkSword** research stack, which provides the low-level access needed to inspect and clean locations that a normal iOS app cannot access.

Current release: **2.0.0**

## What does it do?

StorageCleanerDS scans the device and shows removable cache data progressively, app by app, so you can see results while the scan is still running.

For installed apps, cleanup is limited to temporary data inside:

```text
Library/Caches
tmp
```

The app also includes a **System Cache** section for compatible leftovers managed by iOS. This section may be empty depending on the current state of the device.

StorageCleanerDS is intended for cache cleanup. It is not a general-purpose file manager and is not designed to remove personal documents, photos, messages or other normal user data.

## How does it work?

On the first launch, the app shows a short introduction explaining the basic workflow and precautions.

After that:

1. StorageCleanerDS automatically prepares the required low-level access.
2. The **Apps** section starts scanning application caches.
3. Results appear progressively instead of waiting for the entire device to finish scanning.
4. You can search, sort and select the apps you want to clean.
5. **Clean Selected** removes the selected temporary cache data.
6. **System Cache** can be used to review compatible iOS cache leftovers when available.

Whenever possible, StorageCleanerDS displays the real application name instead of only its bundle identifier.

## What can you do in the app?

- Scan removable cache from installed apps.
- See scan progress and detected space in real time.
- Search applications by name.
- Sort results by name or removable size.
- Select one or multiple apps to clean.
- See the total amount selected before deleting anything.
- Clean temporary app cache.
- Check compatible **System Cache** leftovers.
- Access the built-in help and credits.

Nothing is deleted simply by opening the app or preparing access. Cleanup happens only after you select items and confirm the cleaning action.

## Based on

StorageCleanerDS is a cleaner-focused fork built around the existing **Cyanide** project and its **DarkSword**-based low-level access stack.

The cleaner interface and progressive scanning behavior were developed specifically for StorageCleanerDS while keeping the working Gain Access backend intact. The progressive-result approach also takes inspiration from the cleaner implementation in [`YangJiiii/3105`](https://github.com/YangJiiii/3105).

## Important warnings

StorageCleanerDS performs real filesystem deletion and uses a kernel-exploit-based access method.

- **Cache removal is permanent.**
- Close an app before cleaning its cache whenever possible.
- Apps and iOS may recreate cache files later; this is normal.
- The amount of removable storage can change between scans.
- System Cache may legitimately contain nothing to remove.
- Low-level access can fail, crash the app, panic or reboot the device.
- Keep backups of important data.
- Use StorageCleanerDS only on devices and data you control.

Although app cleanup is intentionally restricted to temporary cache locations, low-level filesystem tools always carry risk. Review your selections before cleaning.

## AI Slop Disclosure

**Yes, this is AI Slop.** The current product/UI iteration was made with **GPT-5.6 Sol**. The underlying **Cyanide, DarkSword, XPF, ChOma and 3105** work remains credited below.

## Credits

- [`boierito`](https://github.com/boierito) — **Lucas Boiero**; StorageCleanerDS fork, product direction, integration and testing.
- [`zeroxjf`](https://github.com/zeroxjf) — Cyanide project and integration work this fork derives from.
- [`opa334`](https://github.com/opa334) — DarkSword, ChOma and XPF work used by the underlying stack.
- [`wh1te4ever`](https://github.com/wh1te4ever) — `darksword-kexploit-fun` / RemoteCall work used by Cyanide.
- [`rooootdev`](https://github.com/rooootdev) — exploit research referenced by Cyanide.
- [`YangJiiii/3105`](https://github.com/YangJiiii/3105) — reference for progressive cleaner behavior.
- Cyanide upstream contributors and the researchers credited by the original project.

## License

Licensed under **AGPL-3.0**. See `LICENSE`.
