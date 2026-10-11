# Hongyan 鸿雁

**Back up your iPhone photo library to your own S3 or Cloudflare R2 bucket, in the background.**

[![Release](https://img.shields.io/github/v/release/jstdlee/hongyan?label=release)](https://github.com/jstdlee/hongyan/releases/latest)
![iOS 26.1+](https://img.shields.io/badge/iOS-26.1%2B-black)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange)
![Storage](https://img.shields.io/badge/storage-R2%20%C2%B7%20S3%20%C2%B7%20MinIO%20%C2%B7%20B2-blue)

<p>
  <img src="docs/gallery/1-backing-up.png" width="24%" alt="Backing up">
  <img src="docs/gallery/3-settings.png" width="24%" alt="Settings">
  <img src="docs/gallery/4-help.png" width="24%" alt="Help">
  <img src="docs/gallery/5-dark.png" width="24%" alt="Dark mode">
</p>

- **Your storage.** Photos go to your own bucket: Cloudflare R2, AWS S3, MinIO, Backblaze B2 or any S3-compatible service.
- **In the background.** iOS uploads the photos for the app, also when it is closed or the phone is locked.
- **Delta sync.** Each sync uploads only new and edited photos into one folder.
- **Never lost.** The sync progress is recorded on the phone and in the bucket. Each sync checks the bucket first, uploads missing files again, and continues where it stopped, also after a reinstall or on a new phone.
- **Full copies, if you prefer.** A complete snapshot every N days; keep the latest X.
- **Simple and native.** One status screen, settings that save as you type, SF Symbols, haptics, VoiceOver, light and dark mode. English, 简体中文, 日本語 and 한국어.
- **No third-party code.** Apple frameworks only. No accounts, no tracking.

## The name

**鸿雁传书 — the goose carries the letter.** Su Wu, a Han envoy, was held by the Xiongnu for 19 years.
Then a Han envoy said that the emperor had shot a wild goose with a letter from Su Wu on its foot,
and the Xiongnu let Su Wu go home.

| The goose | Hongyan |
|---|---|
| carries the letter far away | carries your photos to your own storage |
| flies in its season | iOS picks the time, every N days |
| flies in order, the flock stays together | one library folder with an index |
| always arrives | missing and failed files are sent again |

## How it works

```
 iPhone                                                   your bucket
┌───────────────────────────────┐   presigned PUT    ┌──────────────────────────────┐
│ Photos library                │ ─────────────────▶ │ <prefix>/library/2026/09/…   │
│   │                           │   iOS upload       │ <prefix>/.hongyan/index.json │
│   ▼                           │   service          │ <prefix>/.hongyan/rounds/…   │
│ Hongyan engine ── jobs ──▶ iOS│                    └──────────────────────────────┘
│ (app or upload extension)     │
└───────────────────────────────┘
```

The app never reads photo bytes for normal backups. It gives iOS a list of upload jobs: "send this photo
to this URL". iOS does the transfers when the network and battery allow. Each URL is an S3 presigned PUT,
valid for up to 7 days; a job that waits longer is created again with a fresh URL.

**Each delta sync**

```
1. read the index        local copy, or .hongyan/index.json from the bucket
2. verify                list library/ → forget files that are gone, so they upload again
3. walk the photos       same version → skip · in the bucket but not in the index → record
                         new or edited → upload
4. checkpoint            index to the bucket every 500 files
5. finish                index.json + a record of the sync in .hongyan/rounds/
```

File names stay stable: `IMG_1234_1a2b3c4d.HEIC`, where the suffix is a hash of the photo's library ID.
An edited photo replaces its own file. Photos deleted on the phone stay in the bucket.

**Bucket layout**

```
Sync changes (default)                                   Full copies
<prefix>/library/2026/09/IMG_1234_1a2b3c4d.HEIC          <prefix>/snapshots/20260929T020000Z/manifest.json
<prefix>/library/2026/09/IMG_1234_1a2b3c4d.MOV           <prefix>/snapshots/20260929T020000Z/2026/09/…
<prefix>/.hongyan/index.json
<prefix>/.hongyan/rounds/20260929T020000Z.json
```

**Keep running (optional).** Settings › Keep running keeps the app awake during a backup with silent
audio or coarse location, and the app uploads by itself. Use it when iOS doesn't schedule the upload
extension. It costs battery, and Apple doesn't allow it in App Store apps.

## Install

1. Download the IPA from the [release page](https://github.com/jstdlee/hongyan/releases/latest).
2. Sign and install it with your own Apple ID, for example with [Sideloadly](https://sideloadly.io)
   or [AltStore](https://altstore.io). On the iPhone, turn on **Settings › Privacy & Security › Developer Mode**,
   then trust your Apple ID in **Settings › General › VPN & Device Management**.
3. Open Hongyan, add your storage, tap **Test connection**, then **Turn on background backup**.

Limits of a release IPA:
- It uploads only under the address it was built with (Apple's `BackgroundUploadURLBase`). The release
  page names it. For your own endpoint, build from source.
- A free Apple ID signs for 7 days, and may drop the App Group that background backup needs.
  For full background support, build in Xcode with your own developer team.

To look around without storage, turn on **Help › Demo › Show sample data**.

## Set up Cloudflare R2

1. In the Cloudflare dashboard, open **R2** and create a bucket, for example `photos`.
2. Open **R2 › Manage API tokens** and create a token with **Object Read & Write**, scoped to that bucket.
3. In Hongyan › Settings › Storage, enter:

| Field | Value |
|---|---|
| Endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| Region | `auto` |
| Bucket | `photos` |
| Folder | optional, for example `iphone` |
| Path-style URLs | on |
| Access key / Secret | from the token |

## Restore

Your photos are plain files in your bucket. Use any S3 tool, or the script with the AWS CLI:

```bash
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… AWS_DEFAULT_REGION=auto
export S3_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com S3_BUCKET=photos S3_PREFIX=iphone
scripts/restore.sh library ./restore      # delta sync
scripts/restore.sh latest ./restore       # full copies: newest complete snapshot
```

## Build from source

You need a Mac with Xcode 26.1+ and a real iPhone. The upload extension doesn't run in the Simulator.

1. In `project.yml`, set `HONGYAN_BUNDLE_ID`, `HONGYAN_UPLOAD_URL_BASE` (your endpoint) and `DEVELOPMENT_TEAM`.
2. Run the script:

```bash
scripts/mac.sh all            # setup, tests, build, screenshots
open Hongyan.xcodeproj        # sign with your team, run on your iPhone
```

| Command | What it does |
|---|---|
| `scripts/mac.sh setup` | Installs XcodeGen and xcbeautify, generates `Hongyan.xcodeproj` |
| `scripts/mac.sh test` | Runs the 177 HongyanCore tests on an iPhone Simulator |
| `scripts/mac.sh r2test` | Runs the engine against a real bucket (`HONGYAN_IT_*` variables) |
| `scripts/mac.sh build` | Builds the app and extension for the Simulator and a device |
| `scripts/mac.sh shots` | Takes the gallery screenshots in demo mode |
| `scripts/mac.sh release vX.Y.Z` | Tests, unsigned IPA, tag, release page with notes from `CHANGELOG.md` |

GitHub Actions workflows are in `.github/workflows/`. They do the same steps and are turned off.

## Project layout

```
HongyanCore/         Swift package with the logic that doesn't need PhotoKit
  Sources/…/S3/      SigV4 signing, S3 client, XML parsing, endpoint config
  Sources/…/Backup/  engine, delta sync, key layout, schedule, retention, state files
  Tests/             177 tests: AWS SigV4 vectors, engine scenarios with fakes, real-bucket tests
iOS/App/             SwiftUI app: status, settings, help, keep running, direct uploads
iOS/UploadExtension/ PhotoKit background upload extension
iOS/Shared/          PhotoKit adapters, Keychain and App Group settings, engine factory
project.yml          XcodeGen project: app + extension + package
scripts/             mac.sh, restore.sh, screenshots.sh, pick-simulator.sh
docs/                TEST_PLAN.md (on-device scenarios), r2-test-run.md, gallery
```

## Tested

- **177 unit tests** for the core: SigV4 against AWS's published vectors, S3 requests, file names,
  schedule, retention, state files, and the engine in both modes with fake PhotoKit and a fake bucket.
- **Real Cloudflare R2** ([run log](docs/r2-test-run.md)): first sync, no changes, new and edited photos,
  a file deleted in the bucket, wiped local state, lost index, an interrupted sync, and full copies with
  retention. All passed, with no duplicate uploads.
- **Not yet on a real iPhone.** PhotoKit, iOS's upload service and the screens need a device;
  [docs/TEST_PLAN.md](docs/TEST_PLAN.md) lists the scenarios.

## Known limits

- iOS decides when uploads run. "Every N days" means "not before N days".
- A developer-forum report says iOS doesn't run the upload extension when iCloud Photos is on.
  Keep running is the fallback; test this first.
- Files over 5 GiB, such as long 4K videos, fail: S3 accepts at most 5 GiB in one upload.
- The upload address is fixed per build.
- iOS 27 replaces the extension protocol with an async one; the iOS 26.1 protocol still works.

## History

Hongyan was called Shoebox before v0.3.0. All changes are in [CHANGELOG.md](CHANGELOG.md).
