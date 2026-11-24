# Vespertine iOS: shares at speed, and keeping music offline (M1 and M3)

Branch `feat/ios-smb-offline` (worktree `~/Workspace/vt-ios-smb`). Every commit is signed. Plan:
`~/Workspace/scratch/2026-11-23-vtios-smb/PLAN.md`. Logs: the `logs/` folder beside it (23 Nov) and
`~/Workspace/scratch/2026-11-24-vtios-pr/` (24 Nov).

## Finishing for the PR (24 November 2026)

- **PR:** https://github.com/vespertineapp/Vespertine/pull/490 (open, not merged). No build bump, nothing uploaded to TestFlight, App Store Connect untouched.
- **Favorites UI test: it was already failing on main.** `AdaptiveNavigationTests.testAFavoriteInTwoCopiesIsOneRowWithItsCopies`
  fails on a clean build of origin/main (bfa65c0b, its own worktree `~/Workspace/vt-ios-smb-main`). It was run alone on simulator
  VT-SMB-Test (64374B85…, iOS 27.0), which was shut down afterwards. It fails at the same line (80: "2 COPIES" never appears within
  15 s), the same way as on this branch before and after the rebase (`main-ui-fav.log`, `branch-ui-fav.log`). The PR says so. It is
  left as it is.
- **Rebased on origin/main** (#483 to #489). Two conflicts, both with #487 (iPhone share scan):
  - `SMBConnection`: #487's compound requests (`peek`, `list(folder:)`) read the answers straight off the socket. With this branch's
    read-ahead, that would have thrown away read-ahead answers arriving at the same time. `compound()` now sends its parts and
    collects each one with `receive(_:)` by message ID. `arrival()` splits a frame carrying chained answers. New test
    `SMBPipelineTests.aPeekWhileASongIsReadAheadLeavesEveryAnswerWithItsRequest`, with answers in order and swapped. The fake
    server now answers compound requests in one chained message.
  - Background tasks: both `share-scan` (#487) and `keep.overnight`/`keep.continued.*` are registered and permitted.
    `letLibrariesRest()` does nothing while a keep run is active. When a keep run ends, it leaves the share session open if a scan
    is still running.
- **Flaky test fixed:** `cancellingKeepsWhatArrivedForNextTime` (from this branch) failed once in the first full run, at load
  average ~300 on the hub. It cancelled after a fixed 100 ms. It now waits for the 4000-byte progress mark. It passed 5 of 5 alone
  before the change and 3 of 3 after.
- **Tests after the rebase:**
  - VespertineRemoteKit `swift test`: **787 passed, 0 failed** (`pkg-tests-2.log`).
  - Live Samba 4.19.9, `SMBLiveTests`, 7 modes (3.1.1 signed, 3.1.1 AES-128-GCM, AES-256-GCM only, AES-256-CCM only, 3.0.2 CCM, 2.0.2,
    guest): **all 9 passed in each mode**, including #487's compound `peek`/`list(folder:)` and a 64 MiB file compared byte for byte
    (`live.log`).
  - iOS build-for-testing: **succeeded**. iOS unit tests: **132 Swift Testing + 18 XCTest passed, 0 failed** (`ios-unit.log`).
  - The full UI suite was not run again after the rebase. Only the Favorites test was.
- **Store text:** `STORE-TEXT.md` in this worktree (gitignored, not in the PR) has three What's New options and a feature blurb for
  Alex to approve.
- **Real-phone test pending** (bench B9/B11), as below.

The sections below are from 23 November, before the rebase.

## M1: share throughput

What the share client now does (`Packages/VespertineRemoteKit/Sources/VespertineShare`):

- **Several reads at once.** A read longer than one request goes out as up to 16 requests together, as many as the server's
  credits allow (1 MB each at most, 64 KB on SMB 2.0.2). Answers are matched by message ID, so the order they come back in
  doesn't matter.
- **Reading ahead.** A file read straight through (a song playing or being kept) asks for the next pieces before they're
  needed. It starts at the size of the last read and doubles up to 8 MB, so a tag scan isn't made to fetch megabytes. A jump,
  closing the file or reaching its end drops what was read ahead. Two credits are always kept free for requests that aren't reads.
- **AES-256.** On SMB 3.1.1 it offers AES-128-GCM, AES-128-CCM, AES-256-GCM and AES-256-CCM, in Windows' order. It derives
  256-bit keys with L = 256 (MS-SMB2 3.2.5.3.1).
- **Listing a server's shares.** It calls MS-SRVS NetrShareEnum over the `srvsvc` pipe on `IPC$`. In the app, Add a Share
  now accepts just a server (`smb://nas.local`), signs in and lists the disk shares to pick from. The new UI text is
  translated into all 44 languages.
- The client still has no way to write, rename or delete anything. The pipe request is only allowed on `IPC$`/`srvsvc`.

### Measured throughput

Setup: `SMBLiveTests.measuresThroughput` against Samba 4.19.9 in Docker under colima on dormhub (`scripts/samba-test`).
netem adds a delay to everything the server sends. Each run reads a 64 MiB file, 32 MiB per run (16 MiB at +150 ms), one run
each. "Before" means one request at a time with no read-ahead, which is how the client worked. The player reads 256 KB at a time.

| Added delay | Session | Player, before | Player, now | 1 MB reads, before | 1 MB reads, now |
|---|---|---|---|---|---|
| none | signed | 64 MB/s | 159 MB/s | 82 MB/s | 188 MB/s |
| 20 ms | signed | 8.6 MB/s | 38 MB/s | 26 MB/s | 28 MB/s |
| 50 ms | signed | 4.5 MB/s | 34 MB/s | 14 MB/s | 35 MB/s |
| 150 ms | signed | 1.5 MB/s | 7.5 MB/s | 4.5 MB/s | 8.1 MB/s |
| 50 ms | AES-128-GCM | 4.3 MB/s | 29 MB/s | 14 MB/s | 34 MB/s |
| 150 ms | AES-128-GCM | 1.5 MB/s | 8.1 MB/s | 4.4 MB/s | 7.7 MB/s |

Second run today, with the simulator UI tests running at the same time (`logs/bench-samba-rerun.tsv`):

- **+0 ms, signed:** player went from 75 to 209 MB/s; 1 MB reads from 99 to 196 MB/s.
- **+0 ms, AES-256-GCM only:** player went from 130 to 321 MB/s; 1 MB reads from 141 to 278 MB/s.
- **+50 ms, signed:** player went from 4.4 to 33 MB/s; 1 MB reads from 13.5 to 34 MB/s.
- **+50 ms, AES-256-GCM:** player went from 3.9 to 33 MB/s; 1 MB reads from 12.7 to 35 MB/s.

For scale, 24/192 PCM needs about 1.2 MB/s and DSD256 about 2.8 MB/s. At a 150 ms round trip, the player used to get 1.5 MB/s,
which isn't enough for DSD256. It now gets 7.5 MB/s. The +150 ms numbers are held down by the test setup (colima forwards the
port over SSH, and the SSH window limits a long link), not by the client. All of this is a Mac talking to a container. A real
phone over Tailscale/cellular has not been measured.

## M3: keeping music offline in the background

What Keep on This Device now does (`VespertinePhonePlayer`, app `Kept.swift` and `KeepInBackground.swift`):

- **Resumes by byte offset.** If a song is cut off (lost connection, app closed, iOS ended the background time), the bytes that
  arrived are kept. A note beside the file records which ranges they are plus the file's tag and size. The next attempt fetches
  only the rest. If the file changed on the server in the meantime, it starts over.
- **Integrity check.** A song only counts as kept once its size matches what the share reported. For FLAC, the decoded samples
  must also match the encoder's MD5. A damaged copy is fetched again from the start once. If the second copy is damaged too,
  the song is skipped until the app next opens, and the album page says so ("damaged" status, in 44 languages).
- **DSD keeps the original file.** A DSD song is stored as its own `.dsf`/DSDIFF file, not as PCM. Each time it plays, it is
  converted to DoP or PCM for the current output (`KeptDSD`, `KeptDSDSource`). With Settings › Keep Smaller Copies turned on,
  it is stored as 44.1/48 kHz PCM instead.
- **Pausing**, and a `KeepingRun` that gives its time back after a minute of no progress (no connection, no room, or cellular
  data off).
- **Background, using only iOS's background tasks; it never plays silence.**
  - On iOS 26 and later, choosing Keep on This Device starts a `BGContinuedProcessingTask`. The download keeps going after the
    app is left, with progress shown by iOS. This is behind `#available`, and the deployment target stays at iOS 17.
  - On every version, leaving the app with songs still to fetch schedules an overnight `BGProcessingTask` that needs power and
    a network.
  - Changes: Info.plist gains `processing` and `BGTaskSchedulerPermittedIdentifiers` (`…keep.overnight`, `…keep.continued.*`).
    Connections stay up while a run is active and are released afterwards.
- `URLSession` background transfers were not used because shares are SMB, not HTTP. The background-task route covers shares
  and the Mac the same way.

## Builds and tests (all passing at HEAD unless noted)

| What | Result |
|---|---|
| macOS app (`Vespertine` scheme, Debug, from the generated project with pinned packages) | **Build succeeded** (`logs/mac-build.log`) |
| iOS app (`VespertineRemote`, Debug, simulator) | **Build succeeded**, build-for-testing too |
| VespertineRemoteKit package (`swift test`, 13:03, HEAD code) | **778 passed, 0 failed**, across 6 test bundles: 188 share tests (VespertineShareTests), 304 phone-player tests (Keep on This Device: KeptTests, KeptCheckTests, KeptAdoptTests, Downloader, KeepingRunTests), plus 111, 156, 15 and 4 in the other bundles. The branch adds about 21 share tests and 18 keeping tests. |
| Live against Samba 4.19.9 (`SMBLiveTests`, 9 tests per mode) | **All passed** for 5 modes: SMB 3.1.1 signed, 3.1.1 AES-256-GCM only, 3.1.1 AES-256-CCM only, 2.0.2, and 3.1.1 guest. Covers share list `archive,music`, a 64 MiB file compared byte for byte, and a 3 MB file (`logs/live-samba.log`) |
| iOS app unit tests (one simulator, `VT-SMB-Test` 64374B85…, iOS 27.0) | **132 Swift Testing + 18 XCTest passed, 0 failed** (includes the new KeepInBackgroundTests) |
| iOS app UI tests (same simulator) | **19 passed, 2 skipped (iPad/capture-only), 1 failed**: `AdaptiveNavigationTests.testAFavoriteInTwoCopiesIsOneRowWithItsCopies`. It fails the same way when run alone (`logs/ios-ui-favorites.log`). The accessibility snapshot shows the demo Favorites list sorted by title, with only Allegro…Evergreen on screen. "Harbor Lights" and its "2 COPIES" button sit below the fold, so the 15 s wait never finds them. The branch changes nothing in Favorites, sorting, copies or the demo library, so this looks like it was already broken (screen size or sort order), (24 Nov: confirmed, it fails on origin/main too; see the top). After printing its results, xcodebuild hung until the simulator was shut down, then exited with TEST FAILED (exit 65, that one test). |

Rerun the live tests with `scripts/samba-test/run.sh MODE`, then `VESPERTINE_SMB=…` (see docs/PHONE-SHARES.md, "Testing").

## What is left

- **M0 / real-phone testing (Vesper's):** run on a real iPhone. Covers the throughput a phone gets from a real NAS over
  Wi-Fi and over Tailscale on cellular (bench B9), and how long iOS actually lets a continued task run and how often the
  overnight task fires (bench B11). The plan's test for that is a 20-album queue with the phone locked, counted after 30
  minutes and again after a night on the charger. None of this can be checked in the simulator.
- **Real servers:** only Samba in Docker has been tested. Synology, QNAP, TrueNAS, macOS and Windows file sharing are not yet tried.
- **Store text:** the App Store description and What's New don't yet mention choosing a share from a list, AES-256, or keeping
  music in the background. That copy still needs writing and Alex's approval.
- (24 Nov) Pushed and PR opened: see the top. The store text is drafted in `STORE-TEXT.md` and needs Alex's approval.
