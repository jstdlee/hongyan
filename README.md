# Hongyan

[![Release](https://img.shields.io/github/v/release/jstdlee/hongyan)](https://github.com/jstdlee/hongyan/releases/latest)

A small iOS app (Swift, iOS 26.1+) that backs up the whole photo library to
S3-compatible storage, such as Cloudflare R2, AWS S3, MinIO or Backblaze B2, **in the background**.

- **Full backup per run**: every run is a snapshot, a complete copy of the library
  under `snapshots/<timestamp>/`.
- **Every N days**: iOS schedules the work, usually while charging on Wi-Fi.
- **Keep latest X**: older snapshots are deleted automatically.
- **Keep running** (optional): silent audio or location keeps the app awake during a backup, and the
  app uploads by itself. For sideloaded builds; Apple does not allow it in App Store apps.
- **No encryption** and no third-party dependencies. The app uses only Apple frameworks.

## The name

**Hongyan 鸿雁** is the wild goose of the old saying 鸿雁传书, "the goose carries the letter".
Su Wu, a Han envoy, was held by the Xiongnu for 19 years. A Han envoy then said that the
emperor had shot a goose with a letter from Su Wu on its foot, and the Xiongnu let Su Wu go home.

Geese fly far, in their season and in order, and they arrive. Hongyan carries your photos the
same way:

| The goose | The app |
|---|---|
| carries the letter | carries your photos to your own storage |
| flies in its season | iOS picks the time; every N days |
| flies in order, the flock stays together | full snapshots, keep the latest X |
| always arrives | failed files are sent again with a fresh URL |

Hongyan was called Shoebox before v0.3.0.

## Gallery

Screenshots come from the app's demo mode (`scripts/mac.sh shots`).

| Backing up | Up to date | Settings |
|---|---|---|
| ![Backing up](docs/gallery/1-backing-up.png) | ![Up to date](docs/gallery/2-up-to-date.png) | ![Settings](docs/gallery/3-settings.png) |
| **Help** | **Dark mode** | **First run (日本語)** |
| ![Help](docs/gallery/4-help.png) | ![Dark](docs/gallery/5-dark.png) | ![Japanese](docs/gallery/6-japanese.png) |

The app follows Apple's iOS patterns: a large-title status screen with the main action in thumb
reach, settings one tap away, SF Symbols, Dynamic Type, haptics, VoiceOver labels, and
English, 简体中文, 日本語 and 한국어.

## Download

Get the newest IPA from the [release page](https://github.com/jstdlee/hongyan/releases/latest).
The release page also has the release notes. All versions are in [CHANGELOG.md](CHANGELOG.md).

- The IPA is **unsigned**. Sign and install it with your own Apple ID (Sideloadly, AltStore),
  or build from source (below).
- The upload address is fixed when the app is built. The release page says which address the
  IPA has. For your own endpoint, build from source.

To make a release: add a `## vX.Y.Z — date` section to `CHANGELOG.md`, commit, then on a Mac:

```bash
scripts/mac.sh release vX.Y.Z
```

## How it works

Uploads use PhotoKit's **Background Resource Upload extension** (iOS 26.1). The app
never reads photo bytes itself. It tells iOS "upload this resource to this URL", and
the system does the transfer when conditions allow, even with the app closed or the
phone locked. Each upload URL is an S3 **presigned PUT**, valid for up to 7 days.

```
iOS wakes extension ─┐       ┌─ app opened / Back up now / BG refresh
                     ▼       ▼
             BackupEngine.run()  (one bounded pass, file-locked)
   1. acknowledge finished jobs → record uploaded / retry / failed
   2. no active snapshot and due? → freeze asset list (plan)
   3. create presigned-PUT jobs up to PHAssetResourceUploadJob.jobLimit
   4. all done → PUT manifest.json (marks the snapshot complete)
   5. delete snapshots beyond "keep latest"
```

Bucket layout:

```
<prefix>/snapshots/20260929T020000Z/manifest.json
<prefix>/snapshots/20260929T020000Z/2026/09/IMG_1234_1a2b3c4d.HEIC
<prefix>/snapshots/20260929T020000Z/2026/09/IMG_1234_1a2b3c4d.MOV         (Live Photo)
<prefix>/snapshots/20260929T020000Z/2026/09/IMG_1234_1a2b3c4d_edited.HEIC
```

The suffix is a hash of the photo's library ID. It keeps each file name stable across
snapshots and prevents `IMG_0001` collisions.

## Layout

```
HongyanCore/                  Swift package: logic without PhotoKit
  Sources/HongyanCore/S3/     SigV4, S3 client, XML, config
  Sources/HongyanCore/Backup/ engine, key layout, schedule, retention, state files
  Tests/HongyanCoreTests/     149 XCTests (AWS SigV4 vectors, engine scenarios with fakes)
iOS/Shared/                   PhotoKit adapters, Keychain/App Group settings, engine factory
iOS/UploadExtension/          PHBackgroundResourceUploadExtension entry point
iOS/App/                      SwiftUI app (one settings/status screen)
project.yml                   XcodeGen project (app + extension + package)
scripts/mac.sh                Mac: setup, test, build, screenshots, IPA, release
.github/workflows/            CI and release (disabled; same steps as scripts/mac.sh)
CHANGELOG.md                  release notes, one section per version
scripts/pick-simulator.sh     CI: choose an iPhone simulator
scripts/screenshots.sh        CI: demo-mode screenshots for the gallery
scripts/restore.sh            list / download snapshots with the AWS CLI
docs/TEST_PLAN.md             automated coverage + on-device scenarios
```

## Build, test and release on a Mac

GitHub Actions is turned off (quota). Everything runs on a Mac with Xcode 26.1+ through one script:

```
scripts/mac.sh setup          → xcodegen + xcbeautify, generate Hongyan.xcodeproj
scripts/mac.sh test           → 154 HongyanCore tests on an iPhone Simulator
scripts/mac.sh build          → app + extension for Simulator and device (unsigned)
scripts/mac.sh shots          → demo-mode screenshots into docs/gallery
scripts/mac.sh release v0.3.0 → tests, unsigned IPA, tag, release page with notes from CHANGELOG.md
```

```bash
scripts/mac.sh all
```

To see demo mode, launch the app with `-demo active`, `idle`, `settings`, `help` or `setup`,
or turn on Help › Demo › Show sample data.

The workflows in `.github/workflows/` are kept but disabled. Turn them on again with
`gh workflow enable ci.yml` and `gh workflow enable release.yml`.

## Build the app (Mac, Xcode 26.1+)

1. Edit `project.yml`:
   - `HONGYAN_BUNDLE_ID`: your bundle id.
   - `HONGYAN_UPLOAD_URL_BASE`: your endpoint, e.g. `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.
     Apple requires this in the extension's Info.plist, and uploads outside it are refused.
   - `DEVELOPMENT_TEAM`.
2. `brew install xcodegen && xcodegen generate && open Hongyan.xcodeproj`
3. In the Apple Developer portal, register the App Group `group.<bundle id>` for both
   the app and `<bundle id>.upload`. Xcode's automatic signing usually does this for you.
4. Run on a **real device**. The extension does not run in the Simulator.
5. In the app: fill in the storage fields, tap **Test connection**, **Save**, then
   **Turn on background backup** (full photo access), then **Back up now**.

If XcodeGen can't create the ExtensionKit target, add it by hand: File → New →
Target → Generic Extension named `HongyanUpload`. Add `iOS/UploadExtension` and
`iOS/Shared`, and set these Info.plist keys: `EXAppExtensionAttributes.EXExtensionPointIdentifier =
com.apple.photos.background-upload`, `BackgroundUploadURLBase`, `HongyanAppGroup`,
`HongyanKeychainGroup`. Use the same App Group and Keychain group entitlements as the app.

### Cloudflare R2 setup

- R2 → Create bucket (e.g. `photos`).
- R2 → Manage API tokens → **Object Read & Write**, scoped to that bucket.
- Endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, region `auto`, path style on.

## Restore

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=auto
export S3_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com S3_BUCKET=photos S3_PREFIX=iphone
scripts/restore.sh list
scripts/restore.sh latest ./restore
```

## Known limits and risks

- **iOS decides when uploads run.** "Every N days" means "not before N days", not an exact time.
- **iCloud Photos:** there is a developer-forum report that the extension is never scheduled
  when iCloud Photos is on. Test this first (TEST_PLAN C9).
- **Files over 5 GiB** (long 4K videos) exceed S3's single-PUT limit, so they fail and are listed
  in the manifest. Multipart upload isn't possible through the system uploader.
- **Full backups re-upload everything each time**, so storage grows by about library size × keep latest.
- **The endpoint is fixed per build** (`BackgroundUploadURLBase`).
- **iOS 27** replaces the extension protocol with an async one. 26.1's still works but is
  deprecated; see the comment in `HongyanUploadExtension.swift`.
- CI proves that the app compiles and the core logic works. It can't prove background uploads:
  the extension doesn't run in the Simulator. Use `docs/TEST_PLAN.md` on a real iPhone.
