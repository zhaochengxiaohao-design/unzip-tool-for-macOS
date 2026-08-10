# Universal Extractor for macOS

[简体中文](README.zh-CN.md) | English

A native SwiftUI compression and extraction utility for Apple Silicon Macs. It detects archives from file contents, creates common archive formats, runs extraction jobs safely, and integrates with Finder without forcing the main window to open.

## Highlights

- Detects formats by content instead of trusting filename extensions.
- Supports ZIP, 7Z, RAR/RAR5, TAR, GZ, BZ2, XZ, `tar.gz`, `tar.bz2`, `tar.xz`, and common split archives.
- Creates 7Z, ZIP, TAR, `tar.gz`, `tar.bz2`, `tar.xz`, plus single-file GZIP, BZIP2, and XZ archives.
- Supports compression levels, safe automatic output naming, progress, cancellation, and password-protected 7Z/ZIP archives. RAR creation is not available because the format is proprietary.
- Handles password-protected archives without storing passwords in arguments, logs, preferences, or files.
- Queues multiple archives and expands compound formats to their final contents.
- Offers two output modes:
  - Create a separate folder for each archive in a chosen destination.
  - Extract directly beside each archive; the custom path control is hidden in this mode.
- Provides per-task conflict choices: replace, skip, keep both, or cancel.
- Integrates with Finder through **Open With → Universal Extractor** and **Services → Extract with Universal Extractor**.
- Finder-triggered jobs run silently, preserve focus, and exit automatically. The window appears only when a password is required.
- Automatically follows the current macOS language in English and Simplified Chinese.

## Build

Requirements:

- Apple Silicon Mac
- macOS 14 or later
- Swift 6 Command Line Tools
- Network access to download the official 7-Zip 26.02 macOS binary

```bash
./scripts/build_app.sh
```

The script runs core and real-engine integration checks, builds an arm64 release, applies an ad-hoc signature, refreshes Finder registration, and creates:

- `outputs/万能解压.app`
- `outputs/Universal-Extractor-v1.5.0-macOS-arm64.zip`
- `outputs/Universal-Extractor-v1.5.0-Source.zip`

The app is not notarized because no Apple Developer ID is used. For redistribution, add Developer ID signing and Apple notarization.

## Security Model

- Preflights archive entries with the 7-Zip technical listing.
- Rejects absolute paths, `..` traversal, unsafe symbolic links, and special device files.
- Checks available disk capacity with a 100 MB reserve when the expanded size is known.
- Extracts into a hidden staging directory beside the destination and only moves files after validation.
- Cleans staging data after cancellation, password errors, corruption, or extraction failures.
- Never persists archive passwords.
- Passes creation passwords through controlled standard input instead of command-line arguments; ZIP passwords are limited to ASCII for 7-Zip interoperability, while 7Z supports Unicode passwords.
- Prevents an archive from being created inside a folder that is itself being compressed.

## Localization

English and Simplified Chinese localizations cover the SwiftUI interface, task states, errors, password and conflict dialogs, Finder service names, app metadata, and documentation. macOS selects the language automatically.

## Third-Party Software

The app bundles the official 7-Zip 26.02 macOS command-line component. See `ThirdPartyNotices.txt` in the app and the [7-Zip license](https://www.7-zip.org/license.txt).
