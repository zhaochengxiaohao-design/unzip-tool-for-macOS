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
- `outputs/SHA256SUMS.txt`

The build verifies both the official 7-Zip 26.02 download archive and the extracted `7zz` executable against pinned SHA-256 values. It signs the app and bundled engine ad hoc with Hardened Runtime enabled.

## Install a Release

Download the macOS archive and `SHA256SUMS.txt` from the GitHub Releases page. Before opening the app, run `shasum -a 256 Universal-Extractor-v1.5.0-macOS-arm64.zip` and compare the result with the matching line in `SHA256SUMS.txt`.

The public build is ad-hoc signed but is not Apple-notarized because the project does not have a Developer ID certificate. On first launch, Control-click **Universal Extractor**, choose **Open**, and confirm the macOS prompt. Do not disable Gatekeeper or remove quarantine attributes globally.

## Security Model

- Streams and preflights the complete 7-Zip technical listing with entry-count, line-length, and integer-overflow limits.
- Rejects absolute paths, `..` traversal, special files, and symbolic or hard links that cannot be proven to remain inside the isolated output tree.
- Uses exact filenames rather than wildcard expansion, and archives symbolic links without following them to external content.
- Snapshots source archives and split volumes before inspection, testing, and extraction to prevent files from changing between security checks.
- Checks available capacity before and during extraction, retaining a safety reserve even when the expanded size is unknown.
- Extracts into a private staging directory on the destination volume. Direct extraction uses a rollback area so a failed merge does not discard an existing file.
- Rejects destination path chains or existing merge directories that another local user could rename, inject into, or replace.
- Cleans staging data after cancellation, password errors, corruption, or extraction failures; failed rollback data is preserved for recovery rather than deleted.
- Propagates macOS quarantine metadata from downloaded archives to extracted executable content.
- Never persists archive passwords.
- Passes creation passwords through controlled standard input instead of command-line arguments; control characters and oversized passwords are rejected. ZIP passwords are limited to ASCII for 7-Zip interoperability, while 7Z supports Unicode passwords.
- Prevents an archive from being created inside a folder that is itself being compressed.
- Preflights compression inputs without following symbolic links, accounts for per-entry/path/TAR overhead, monitors free space while writing, verifies the completed archive, and publishes it with a no-replace operation from a private same-volume staging directory.

Archives remain untrusted input. The bundled 7-Zip parser runs locally in a non-sandboxed process, so these defenses reduce risk but do not guarantee that every future parser vulnerability is contained. Please report suspected vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Selected compression inputs are read from their original locations after validation. If another process changes those files while compression is running, the resulting archive may reflect the concurrent changes; the output remains staged, space-monitored, verified, and published only after completion.

## Localization

English and Simplified Chinese localizations cover the SwiftUI interface, task states, errors, password and conflict dialogs, Finder service names, app metadata, and documentation. macOS selects the language automatically.

## Third-Party Software

The app bundles the official 7-Zip 26.02 macOS command-line component. See `ThirdPartyNotices.txt` in the app and the [7-Zip license](https://www.7-zip.org/license.txt).

## License

Original project code is available under the [MIT License](LICENSE), copyright 2026 zhaochengxiaohao-design. The MIT License does not relicense 7-Zip or any other third-party component; those components retain their own terms.
