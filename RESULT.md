# Sonos and output routes: result

Branch `feat/sonos-and-output-routes`, local commits only, not pushed; `git log --format=%G?` shows a good signature on every commit since `main`. Target: 1.2.4 (build 77). Nothing here has been heard on a real Sonos; Sonos-specific behaviour is verified against a pretend Sonos on 127.0.0.1 and against Sonos's documentation and the SoCo library's source. The checklist at the end is the first real test.

## What the branch adds

- **Sonos rooms as outputs**, behind Settings › Playback › Network Players (Sonos and UPnP, beta), off by default (no search, no port until switched on). One row per room or group; surrounds, Sub and the second speaker of a pair aren't listed.
- **Sonos's limits applied by one table** (`StreamLimits.sonos`, `.sonosS1`): the file itself when it fits (per codec within a file type); otherwise FLAC at 48 or 44.1 kHz (whichever divides the source rate), 24-bit on S2 and 16-bit on S1 (or a speaker that doesn't say), folded to stereo, DSD as PCM. Written whole before Sonos is told, so it can seek.
- **No silent downgrade**: every output row says what the loaded song would be played as ("Will play 24-bit / 48 kHz FLAC, stereo (source 24/96)", copper when samples change); while playing, the badge (RESAMPLED / FOLDED TO STEREO / DSD AS PCM · 24/48 SENT) and a "Player limit" line in the signal path. Same planner for DACs, HDMI, Bluetooth, AirPlay and other network players.
- **Sonos volume** slider (room or group), the room's details (speaker setup, Music Playback Ambient/Full, read only), plain error for "couldn't fetch" (firewall), `vespertine-probe sonos`, and docs/output-routes.md.

## This pass: the third review's findings (2026-11-23, 07:45 onwards)

A third independent review of 3e6cd9b9 still said not to ship. Each of its three findings has a test written first and seen failing (`build/logs/r3/red-*.log`), then the fix (`green-*.log`). Signed commits 9bed9b51, 86835ab1, a1f8bc30 (and ee0d1fc0 for the docs); nothing pushed.

1. **P1, switching from a network player to the Mac failed the song.** A streamed song is one shared copy in the playback cache. If the listener switched from a network player to the Mac while the current song was still downloading, the Mac's engine picked up that same copy, and then the player's preparation, being given up, cancelled the copy outright (`entry.cancel()` in `StagedRemoteFile.stage`). The Mac then failed with "The operation was cancelled." Now a preparation that gives up only lets go of its hold on the copy. The download is cancelled when nobody holds it any more, so it carries on for the Mac. Test (`StagedHandoffTests`, real engine): a slow stream that sends 256 KiB and then pauses. The player's preparation is waiting on it, the engine starts the same song and waits on the same copy, the player gives up, then the rest arrives. The Mac must play. Before the fix it failed with exactly "The operation was cancelled." A player that gives up a download nobody else holds still cancels it at once; the existing `remoteDownloadFreesTheQueue` and `remoteDownloadStop` tests check that, and still pass.
2. **P2, a failed clear of the old next song let it go too early.** After a queue edit Vespertine tells the player to drop its old next song (an empty NextURI). If that call failed, Vespertine let the old song go anyway (its web address and its copy) while the player might still hold it and move on to it. Now the song is kept, as a stale next song, until a clear or a new next song is confirmed. The status polls send the clear again, once a second and ten times at most, so a player that always refuses an empty NextURI isn't asked for ever. If the player moves on to the stale song anyway, Vespertine recognises it, never announces it, and plays the song the queue has after the one that ended, or stops the player at the end of the queue. A failed hand-over of a new next song now keeps what the player held in the same way, instead of letting it go. Tests (a transport that refuses any change of the next song): the song stays held while the clear is refused, and is cleared and let go once the player answers again; a player that moves on to it is put right, both when the queue has a song after it and when it doesn't. All of them failed before the fix.
3. **P2, xHE-AAC left the AAC filter.** The last pass named xHE-AAC separately so Sonos would get it as FLAC. As a side effect the library filed those songs under "Other lossy" instead of AAC, and the tag editor's footer said "tags" instead of "MP4 atoms", even with Network Players off. Both now treat "xHE-AAC" as AAC (`FormatKind.of`, and `TagEditorView.tagFormat(codec:)`, which was pulled out of the footer so it can be tested). The codec name stays "xHE-AAC" for the players. Tests: `LibraryFilterTests.xheAACIsAAC` (a song's facts, a filter set to AAC, an album's facts read from the database) and the app test `TagEditorFormatTests`. Both failed before the fix. For the app test, the one-line fix was taken out and put back to see it fail.

Also: docs/output-routes.md describes items 1 and 2.

### Test figures, this pass

On this machine, 2026-11-23 from 07:45. The machine was busy with other work throughout: load averages of 15 to 18 on 8 cores before anything of mine started.

- **The new tests, before and after**: all four package tests failed before their fixes and passed after (`build/logs/r3/red-1-3.log`, `green-1-3.log`); the app test likewise (`red-app-tageditor.log`, `green-app-tageditor.log`).
- **UPnP and Sonos** (`VespertineUPnPTests`, debug): **164 passed**, 0 failed (162 before this pass, plus the 2 new tests; the "moves on" test runs 2 cases). Run once after the three fixes, and again after the follow-up commit 7dd60ab6 (`upnp.log`, `upnp-final.log`).
- **Library group, and the cache and stream suites fix 1 touches** (`VespertineLibraryTests`, `NetworkPlaybackCacheTests`, `RemoteReaderRegistryTests`, `RemoteEarlyStartTests`, `StagedHandoffTests`, debug): 274 + 38 passed, 0 failed (`library-cache.log`).
- **App tests** (`xcodebuild test`, Debug, macOS, `-derivedDataPath build/DD` as in the earlier passes): **passed**, 284 tests in 61 suites, 0 failed (`** TEST SUCCEEDED **`; 283 in 60 before, plus `TagEditorFormatTests`). Log: `build/logs/r3/app-tests.log`. They ran at a1f8bc30. The follow-up 7dd60ab6 changed only the renderer's recovery path, and the UPnP group was run again after it; the app tests were not.

## The second review's findings (2026-11-23)

An independent re-review of 011bc0a5 said not to release yet. Each finding below has a test written first and seen failing (logs `build/logs/r2-red-*.log`), then the fix (`r2-green-*.log`). All commits signed; nothing pushed.

1. **P1, a cancelled download held everything behind it.** A streamed next song was copied whole (`StagedRemoteFile.stage`) without the preparation's cancellation, on the serial preparation queue: a skip or stop left it downloading, and the song skipped to, even a local file, waited behind it. Now the cancellation goes into the staging (the copy is given up within ~25 ms), and is checked again before the file is probed and before an encoder is made. Tests: a pretend stream that never finishes downloading; a skip to a local song plays within 3 s and the download is cancelled; after a stop, `stopAndWait` returns within 2 s and the download is cancelled. (Before: the local song never started within the test's 3 s.)
2. **P1, a stop during the first song's load could miss the next song's preparation.** A stop or shutdown while `start()` was waiting for the player to load the song came before `replanNext()` published the next song's preparation, so nothing gave it up, and its encoder ran on. Now a preparation is planned for the play the song playing was started for (its generation, kept with the song), and published only if that play is still current and the output still held, checked under the lock that a stop's give-up takes (so either the stop finds it or it finds the stop). The worker's own stop gives preparations up again, and `stopAndWait` waits for any preparation still running. Tests: stop and shutdown while a load is held (no stream left being written), and `stopAndWait` with an encoder slow to open (returns with it given up).
3. **P2, a queue edit left the old next song on the player.** With the next song removed, or another inserted before it, the player kept the old one as its next (`state.next` and NextURI) until the new one was ready; a song ending meanwhile went on to the wrong one. Now the old next song is taken off at once (NextURI cleared, the entry let go), then the new one is prepared. Tests (both edits): the new next song is a hi-res one that is never finished; NextURI is empty within 2 s, and when the first song ends mid-preparation the player doesn't move to the old one.
4. **P2, xHE-AAC was called AAC.** The probe had no case for `kAudioFormatMPEGD_USAC` and fell back to the extension's "AAC", which Sonos's table takes in an M4A, so the file went untouched. Now it is "xHE-AAC" (as FFmpeg's profile already names it) and is sent as FLAC with the codec named. Tests through the real probe of the engine's xHE-AAC fixture (Apple's encoder; this Mac can't make one, `afconvert -d usac` fails): the probe's codec, Sonos's plan, and a play to a pretend Sonos that fetches FLAC, not the file. They run only where macOS decodes xHE-AAC, like the engine's own xHE test.
5. **P2, ReplayGain at 16 bits wasn't dithered.** ReplayGain is applied in the decoding, before the chain, so the chain's dither (volume, EQ, room correction) never covered it, and the 16-bit stream's "re-quantised" test left it out: a 16-bit song with ReplayGain went to an S1 room rounded without dither. Applied ReplayGain now counts. Test: a 16-bit song at −3 dB into a 16-bit stream is within 2 LSB of the gain's result and dithered, not just rounded.
6. **The S1 note** said "anything above is resampled", as if a 24/48 file were resampled. It now says a 24-bit song up to 48 kHz is only reduced to 16-bit, not resampled, and only one above 48 kHz is also resampled; both go as 16-bit FLAC. The 44 translations were rewritten for the new sentence (`check-localizations.py`: complete). `SonosOutputTests` checks the wording (added with the change, not run red first). docs/output-routes.md says the same, and describes items 1, 3 and 5.

## The first review's findings (2026-11-23, morning)

An independent review said not to ship yet. Each finding below was fixed with a failing test written first (seen failing, then passing). All commits of this pass are signed; nothing is pushed.

1. **P1, the next song blocked the player's commands.** Preparing the next song (for a Sonos, up to two minutes waiting for a hi-res conversion to be written whole) ran on the serial command worker, so pause, play, seek, stop, skip and the status polls waited behind it. Worse than reported: the status poll that says a song has *started* waited too, so the first song wasn't even announced. Now the next song is prepared beside the worker and handed back to it when ready; it is handed to the player only if it still follows the song playing, for the same play, and is still the queue's next. A stop, a skip, letting go of the output, or a queue change gives it up at once (its wait ends within 20 ms, its encoder stops). A stop or skip also cuts short the wait of the *current* song's preparation. Tests: `NextPreparationTests` (a pretend Sonos and a stream that is never finished: polls, pause, play and seek get through within 2 s; stop, skip and shutdown abandon the stream; a next song ready in time is still handed over). One existing OpenHome test now waits for the next song to be handed over instead of expecting it at the instant the first song starts. Not changed: while the *first* song itself is being prepared, a pause is carried out once it is loaded.
2. **P2, every Sonos got S2's limits.** A speaker's description is now read for `swGen` (1 or 2), else its display version (S1 ends at 11.x, S2 began at 12.0). S1, and a speaker that says neither, get S1's limits: FLAC and Apple Lossless up to 16-bit, everything deeper sent as 16-bit FLAC with TPDF dither (the change named: "Sonos S1 takes up to 16-bit, so this 24-bit song is sent as 16-bit."). The processed stream, the FLAC encoder, the signal path and the DIDL metadata carry 16 bits; a 16-bit song made into a 16-bit stream keeps its samples exactly. The output list, the room's details and its notes say "UP TO 16/48" for such a room (three new strings; their 44 translations are the 24-bit ones with the number changed). `vespertine-probe sonos` prints what the speaker states. Tests: `SonosGenerationTests`, `SonosOutputTests`.
3. **P2, any lossy codec in an allowed file type went as the file.** Acceptance is now per codec within a type: FLAC; ALAC and AAC in M4A; MP3; Vorbis in Ogg; 16-bit PCM in WAV and AIFF. Dolby Digital, Dolby Digital Plus or xHE-AAC in an M4A, and Opus or FLAC in Ogg, are decoded and sent as FLAC, the codec named. Tests: rows added to the Sonos table.
4. **P2, the forecast ignored what the player advertises.** The output list's line for a network player is now made from `RendererMode.decide` itself, with the player's format list, its limits and the listener's chain. A player that takes neither the file nor FLAC shows why ("The player doesn't take FLAC, so this song can't be sent to it processed.", in copper) instead of "Will play…"; one that lists FLAC but not the file's type is forecast FLAC; a rate or channel limit it states is named under the line. Tests: `RouteForecastDecisionTests`, `SonosOutputTests`.
5. **P2, a Sonos volume change could reach a speaker after it was let go of.** The pending send is cancelled when the room is let go of or replaced, when playback leaves network players, and when Network Players is switched off. Tests: `SonosVolumeSendTests`.
6. **P2, version.** `project.yml` is 1.2.4, build 77; the Xcode project was regenerated with XcodeGen (it is not tracked in git). No test: a test pinned to a version number would break at every release.

## Test figures, this pass (this machine, after the last change, 2026-11-23 07:20–07:37)

**App tests** (`xcodebuild test`, Debug, macOS, as before): **passed**, 283 tests in 60 suites, 0 failed (`** TEST SUCCEEDED **`; the S1 wording is a new check in an existing test, so the count is unchanged). Log: build/logs/r2-app-tests.log.

**UPnP and Sonos** (`VespertineUPnPTests`): **162 passed** (154 before this pass: 5 new in `NextPreparationTests` with two of them run for two cases each, 2 in `XHEAACTests`, 1 in `SonosGenerationTests`), alone and again inside the whole run. The new tests and their suites (20 tests) were run 5 more times on their own: all passed each time.

**Engine package tests** (`swift test`, the whole package, run once, nothing else of mine running alongside; 12 min 51 s):

| Test group | Clean `origin/main` (f39e3116, from the first pass) | This branch, first pass | This branch, now |
|---|---|---|---|
| Engine (`VespertineAudioTests`) | 1483 tests, **5 failed** (6 issues) | 1483 tests, **4 failed** (4 issues) | 1483 tests, **3 failed** (6 issues) |
| UPnP and Sonos | 107 passed | 154 passed | 162 passed |
| The six other groups (AirPlay 2 211, 273, 151, 73, 37, 31) | all passed | all passed | all passed |

The three failures now:

- "Stop while the next song at another rate waits on its share" (`RateJoinStopTests`): failed on `main` and on the branch's first pass too.
- "Play pressed twice while the share is quiet…" (`ShareCloseTests`): failed on `main` before.
- "The compressed frames macOS is handed are byte-identical with the meters and the visualizer on or off" (`BedMeterTests`): new on this list. The Mac's own output renderer was never handed the whole stream (`run.exhausted` false) during the whole run's busiest stretch; the test hands compressed audio to the real output device and gives up after 150 s.

All three waited 380 to 445 s, as the earlier timing failures did. Run alone right after (their three suites, 18 tests): **all passed** (build/logs/r2-engine-failing3-alone.log). The engine code this pass touched is two lines' worth: the codec name for USAC in `SourceOpener.codecName` and the ReplayGain term in `NetworkRender`'s dither decision; neither is on these tests' path (share copies, rate changes, compressed pass-through to a device). Logs: build/logs/r2-engine-whole.log.

Not run this pass: the release-mode engine tests, the analysis package tests, the sanitizer checks and the Release build (`scripts/audit.sh`). `scripts/check-localizations.py`: complete, 44 languages.

## Test figures, first pass (2026-11-23, morning)

**App tests** (`xcodebuild test`, Debug, macOS): **passed**, 283 tests in 60 suites, 0 failed (`** TEST SUCCEEDED **`; 276 in 59 before this pass). Log: build/logs/app-tests-1123-final.log.

**Engine package tests** (`swift test` in `Packages/VespertineKit`, the whole package, run once each, nothing else of mine running alongside the branch run; the machine had other load, averages 4 to 15):

| Test group | Clean `origin/main` (f39e3116, 1.2.3) | This branch |
|---|---|---|
| Engine (`VespertineAudioTests`) | 1483 tests in 234 suites, **5 failed** (6 issues) | 1483 tests in 234 suites, **4 failed** (4 issues) |
| UPnP and Sonos (`VespertineUPnPTests`) | 107 passed | 154 passed |
| The six other groups (AirPlay 2 211, 273, 151, 73, 37, 31) | all passed | all passed |
| Time | 15 min 14 s | 12 min 48 s |

**The timing failures were there before.** Clean `main` fails the same kind of tests in a whole run, so they don't come from this branch. Every failure on either side waited 360 to 420 s, or failed while a share was being slow:

- Failed on both: "Stop while the next song at another rate waits on its share" (`RateJoinStopTests`), "A flush notice from another renderer is not this session's business" (`AtmosRouteChangeTests`), "With a scan in flight, the song's copy goes over the link…" (`NetworkPriorityTests`).
- Only on `main`: "Play pressed twice while the share is quiet…" and "A song skipped to while the share is quiet plays…".
- Only on the branch: "Play and pause pressed while the song is still opening on a slow share…" (`PlayPauseStateTests`).

Run alone on the branch right after, the four suites the branch failed in (18 tests) **passed**. Which tests fail changes from run to run (the earlier pass's two runs also failed a different five), and none of these tests or the engine code they exercise was changed by this branch. One caveat: during the `main` run my own test builds for this pass were running at the same time.

Also run: `scripts/check-localizations.py` (complete, 44 languages), and the UPnP group alone four more times after the last renderer change (all passed). The new queue-edit race (below) was run 16 times on its own: 0 failures, against 12 of 25 before its fix.

Not run this pass: the release-mode engine tests, the analysis package tests, the sanitizer checks and the Release build (`scripts/audit.sh` does these).

**A race found and fixed along the way:** the first version of the P1 fix let `settleForTests` return while the next song was still being handed to the player. The OpenHome queue-edit test then failed about half the time (12 of 25 runs on its own). The "being prepared" marker now stays until the hand-over is done. Only the test helper ever read it early; playback itself was not affected.

## Not verified: needs a real Sonos

- That a real Sonos answers the search and the arrangement call, accepts the metadata, and can fetch from the Mac (macOS asks for local-network access once; the firewall must let Vespertine accept connections).
- **Gapless**: the next song is handed over ahead of time; whether Sonos joins them without a gap is unknown (fallback: a gap of about a second).
- A song that takes over two minutes to prepare is offered while still being written; Sonos may refuse a stream without a length.
- **S1 or S2 on a real speaker**: that `swGen` 2 means S2 comes from one community report of real speakers' descriptions, not a Sonos document, and the display-version rule is Sonos's own numbering (S2 is 12.0 and later). Not checked on a real S1 speaker. Run `vespertine-probe sonos` and look at the "software:" line.
- iOS: the iPhone/iPad app shares none of this code; its view of the Mac's new output line wasn't looked at.

## Known gaps

- **First hi-res song starts late**: a song above 48 kHz is converted before Sonos is told (measured about 15–20 s for a 5-minute song in a debug build; release not measured). "Preparing output…" shows meanwhile; later songs are prepared during the one before.
- **No surround or Atmos to Sonos from a computer**: Sonos's design (next section).

## The Playbar, exactly

- From Vespertine over the network: stereo, up to 24-bit / 48 kHz. FLAC and Apple Lossless within that go as the file itself; everything else is converted and labelled.
- No Dolby Atmos (no HDMI on the Playbar; optical can't carry Dolby Digital Plus). No surround from music files: Sonos refuses 5.1 FLAC from a library, so Vespertine folds 5.1 to stereo and says so first.
- Stereo into the 5.1 room plays on all speakers; the surrounds follow Sonos app › Settings › the room › Surround Audio › Music Playback: Ambient (default) or Full. Vespertine shows which and doesn't change it.
- Real 5.1 on the Playbar only via the TV's optical input as Dolby Digital 5.1 (untested from a Mac over HDMI to the TV). No AirPlay 2 on the Playbar.

## Five minutes at home

On the Mac you play from, on the same network as the Sonos (not a guest network):

1. Settings › Playback › Network Players (Sonos and UPnP, beta) on; allow local-network access.
2. Output list: one row named after the room, `SONOS · 5.1 · UP TO 24/48 · STEREO`, no rows for the Ones or the Sub. `UP TO 16/48` means Vespertine took it for S1 or couldn't tell; the probe's "software:" line shows what the speaker stated (please keep it either way). Otherwise: `cd Packages/VespertineKit && swift run vespertine-probe sonos` and keep the output.
3. A 16/44.1 FLAC: "Will play 16-bit / 44.1 kHz FLAC, stereo, the file as it is"; plays within seconds; badge `BIT-PERFECT · 16/44.1 SENT`. "UPnP error 716": allow Vespertine in System Settings › Network › Firewall.
4. A 24/96 or 24/192 song: copper "Will play 24-bit / 48 kHz FLAC, stereo (source …)"; up to 20 s "Preparing output…"; badge `RESAMPLED · 24/48 SENT`; "Player limit" in the signal path.
5. Pause, play, seek, skip; move the SONOS volume slider and watch the Sonos app follow.
6. Let one song run into the next: gap or none (the one thing nobody could check in advance).
7. A 5.1 or DSD song: the row says folded / converted before you play it.
8. "Surrounds for music" in the room's details: try Ambient and Full in the Sonos app.
9. Quit Vespertine while playing: the Sonos stops within a couple of seconds.
