# Sonos and output routes: result

Branch `feat/sonos-and-output-routes`, local commits only, not pushed; `git log --format=%G?` shows a good signature on every commit since `main`. Target: 1.2.4 (build 77). Nothing here has been heard on a real Sonos; Sonos-specific behaviour is verified against a pretend Sonos on 127.0.0.1 and against Sonos's documentation and the SoCo library's source. The checklist at the end is the first real test.

## What the branch adds

- **Sonos rooms as outputs**, behind Settings › Playback › Network Players (Sonos and UPnP, beta), off by default (no search, no port until switched on). One row per room or group; surrounds, Sub and the second speaker of a pair aren't listed.
- **Sonos's limits applied by one table** (`StreamLimits.sonos`, `.sonosS1`): the file itself when it fits (per codec within a file type); otherwise FLAC at 48 or 44.1 kHz (whichever divides the source rate), 24-bit on S2 and 16-bit on S1 (or a speaker that doesn't say), folded to stereo, DSD as PCM. Written whole before Sonos is told, so it can seek.
- **No silent downgrade**: every output row says what the loaded song would be played as ("Will play 24-bit / 48 kHz FLAC, stereo (source 24/96)", copper when samples change); while playing, the badge (RESAMPLED / FOLDED TO STEREO / DSD AS PCM · 24/48 SENT) and a "Player limit" line in the signal path. Same planner for DACs, HDMI, Bluetooth, AirPlay and other network players.
- **Sonos volume** slider (room or group), the room's details (speaker setup, Music Playback Ambient/Full, read only), plain error for "couldn't fetch" (firewall), `vespertine-probe sonos`, and docs/output-routes.md.

## This pass: the review's findings (2026-11-23, later)

An independent review said not to ship yet. Each finding below was fixed with a failing test written first (seen failing, then passing). All commits of this pass are signed; nothing is pushed.

1. **P1, the next song blocked the player's commands.** Preparing the next song (for a Sonos, up to two minutes waiting for a hi-res conversion to be written whole) ran on the serial command worker, so pause, play, seek, stop, skip and the status polls waited behind it. Worse than reported: the status poll that says a song has *started* waited too, so the first song wasn't even announced. Now the next song is prepared beside the worker and handed back to it when ready; it is handed to the player only if it still follows the song playing, for the same play, and is still the queue's next. A stop, a skip, letting go of the output, or a queue change gives it up at once (its wait ends within 20 ms, its encoder stops). A stop or skip also cuts short the wait of the *current* song's preparation. Tests: `NextPreparationTests` (a pretend Sonos and a stream that is never finished: polls, pause, play and seek get through within 2 s; stop, skip and shutdown abandon the stream; a next song ready in time is still handed over). One existing OpenHome test now waits for the next song to be handed over instead of expecting it at the instant the first song starts. Not changed: while the *first* song itself is being prepared, a pause is carried out once it is loaded.
2. **P2, every Sonos got S2's limits.** A speaker's description is now read for `swGen` (1 or 2), else its display version (S1 ends at 11.x, S2 began at 12.0). S1, and a speaker that says neither, get S1's limits: FLAC and Apple Lossless up to 16-bit, everything deeper sent as 16-bit FLAC with TPDF dither (the change named: "Sonos S1 takes up to 16-bit, so this 24-bit song is sent as 16-bit."). The processed stream, the FLAC encoder, the signal path and the DIDL metadata carry 16 bits; a 16-bit song made into a 16-bit stream keeps its samples exactly. The output list, the room's details and its notes say "UP TO 16/48" for such a room (three new strings; their 44 translations are the 24-bit ones with the number changed). `vespertine-probe sonos` prints what the speaker states. Tests: `SonosGenerationTests`, `SonosOutputTests`.
3. **P2, any lossy codec in an allowed file type went as the file.** Acceptance is now per codec within a type: FLAC; ALAC and AAC in M4A; MP3; Vorbis in Ogg; 16-bit PCM in WAV and AIFF. Dolby Digital, Dolby Digital Plus or xHE-AAC in an M4A, and Opus or FLAC in Ogg, are decoded and sent as FLAC, the codec named. Tests: rows added to the Sonos table.
4. **P2, the forecast ignored what the player advertises.** The output list's line for a network player is now made from `RendererMode.decide` itself, with the player's format list, its limits and the listener's chain. A player that takes neither the file nor FLAC shows why ("The player doesn't take FLAC, so this song can't be sent to it processed.", in copper) instead of "Will play…"; one that lists FLAC but not the file's type is forecast FLAC; a rate or channel limit it states is named under the line. Tests: `RouteForecastDecisionTests`, `SonosOutputTests`.
5. **P2, a Sonos volume change could reach a speaker after it was let go of.** The pending send is cancelled when the room is let go of or replaced, when playback leaves network players, and when Network Players is switched off. Tests: `SonosVolumeSendTests`.
6. **P2, version.** `project.yml` is 1.2.4, build 77; the Xcode project was regenerated with XcodeGen (it is not tracked in git). No test: a test pinned to a version number would break at every release.

## Test figures (this machine, after the last change)

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
