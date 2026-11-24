# MemBar

A small macOS menu bar app that shows what is using your **RAM** and **disk**, and lets you act on it.

- **RAM** – used memory, swap, and every app grouped by its helper processes, with a Quit button.
- **Disk** – a size-sorted folder browser. Click to drill down, reveal in Finder, or move to Trash.
- **Chrome** – every open tab with Close, and an optional per-tab memory reading.
- **Clean** – caches, logs, Xcode DerivedData and Trash in one place.

## Build and run

Requires macOS 13+ and Xcode / Swift 5.9+.

```bash
./build.sh
open build/MemBar.app
```

`build.sh` produces an ad-hoc signed `build/MemBar.app`. Copy it to `/Applications` to keep it.

## Permissions

- **Automation (Chrome, System Events)** – to list and close Chrome tabs.
- **Accessibility** – only for "Measure memory", which reads Chrome's Task Manager.
- **Files and Folders** – macOS may ask the first time you open Documents, Desktop or Downloads.

## Safety

Deleting from the Disk tab moves items to the Trash. Your home folders (Documents, Library,
Application Support, ...) and `/Applications` itself cannot be deleted from the app.
Emptying the Trash is done through Finder and is permanent.
