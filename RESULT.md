# Sonos and output routes: result

Branch `feat/sonos-and-output-routes`, local commits only (unsigned, not pushed). Nothing here has been heard on a real Sonos: there is none on the network this was built on. Everything Sonos-specific is verified by tests against a pretend Sonos on 127.0.0.1 and by reading Sonos's own documentation and the SoCo library's source. The first real test is the checklist at the end.

## What was already there, and what this adds

The app already played to network players (UPnP AV and OpenHome: discovery, an HTTP server for the song, transport, the next song handed over, a processed 24-bit FLAC stream) and to AirPlay receivers, and already matched a DAC's sample rate to each song and routed surround channel for channel. A Sonos is a UPnP player with habits of its own, so this work is the Sonos part plus the honesty part:

1. **Sonos is found and listed as rooms.** The search now also asks for Sonos's own device type. Each speaker's description gives its room name; the system's arrangement (ZoneGroupTopology) decides what is listed: one row per room, or per group of rooms ("Living Room + Kitchen"). Surrounds, the Sub and the second speaker of a pair are not listed. A system that doesn't answer the arrangement call keeps every speaker listed, so nothing can vanish.
2. **Sonos's limits are applied, by one table.** Sonos never says "48 kHz, two channels" in its format list, so the limits are written down (`StreamLimits.sonos`) and `StreamNegotiation.plan` decides per song: the file itself when it fits; else 24-bit FLAC at the highest rate Sonos takes that divides the song's own (192 → 48, 176.4 → 44.1), folded to stereo, DSD as PCM. Resampling is the app's existing mastering-quality converter.
3. **The stream is written whole first** for Sonos, so it gets a file with a length it can seek in (the existing stream-as-it-grows path stays for other players). Seeking in such a stream is Sonos's own seek.
4. **Nothing is downgraded silently.** Before choosing: every row of the output list has a line for the song loaded now, "Will play 24-bit / 48 kHz FLAC, stereo (source 24/192)", copper when the samples change, with a sentence for surround and Atmos where they don't arrive. While playing: the badge says RESAMPLED · 24/48 SENT, FOLDED TO STEREO or DSD AS PCM, and the signal path has a "Player limit" line with the reason in a sentence. This forecast covers DACs, HDMI, Bluetooth, Sonos, other network players and AirPlay, from the same planner playback uses.
5. **Sonos volume.** A slider for the room's own volume (the group's when rooms are grouped), as in the Sonos app. It doesn't touch the samples.
6. **The room's details** say what Sonos takes, show the speaker setup ("5.1"), and read (never set) whether the surrounds play music Ambient or Full.
7. **Plain errors.** When Sonos refuses a song with its "couldn't fetch" code, the message says to check the Mac's firewall.
8. **A diagnostic:** `vespertine-probe sonos [files…]` searches, prints what every speaker answered, the raw arrangement, which rooms would be listed and what each file would be sent as. It plays and changes nothing.
9. **docs/output-routes.md:** what each route can carry, with sources.

Transport controls, queue advance, pause, seek, the next song handed over ahead of time, and keeping the Mac awake were already in the network player code and are used unchanged.

## Verified, and how

| What | How it was checked |
|---|---|
| The Sonos format table (27 rows) and rate choice (13 cases) | Unit tests, row by row |
| Reading rooms, groups, surrounds, Sub, stereo pairs | Unit tests on a system description (a sound bar with two surrounds and a Sub, a paired kitchen, an office); format checked against the SoCo library's parser |
| Discovery lists one row per room and hides the parts; regrouping is picked up on the next search | Test against two pretend speakers over real HTTP |
| A 24/96 song arrives as a whole 24/48 FLAC with a length, the right metadata, and the path says why | End-to-end test: real decode, resample, FLAC encode, HTTP fetch by the pretend Sonos, decoded again and measured |
| A 24/48 FLAC goes as the file itself, byte for byte; the next song is handed over and followed | End-to-end test |
| 176.4 → 44.1, 192 → 48, 5.1 → stereo with sound in both channels, mono stays mono | Render tests |
| 24-bit WAV repacked as FLAC keeps every sample | Test, sample for sample |
| Volume (room and group), surround mode read-only | Tests against the pretend Sonos |
| The forecast line for Sonos, other players, AirPlay, DACs, 6-channel devices, Atmos, Bluetooth | Unit tests using the real planner |
| Output list second line and notes for a Sonos room | App tests |
| Sample-rate matching and surround routing on Core Audio devices | Already in place (Match source is the default; `FormatPlanner`, `MultichannelDeviceTests`, golden PCM tests); not changed, tests still pass |

**Test runs.**
- New and changed network player tests: 28 Sonos, stream and forecast tests pass, alongside the existing ones in the same target.
- `swift test` in `Packages/VespertineKit` (whole package): 1483 tests, 1478 passed, 5 failed in that parallel run, all in engine tests this work doesn't touch (`BedMeterTests`, `NetworkPriorityTests` ×2, `AtmosRouteChangeTests`, `PlayPauseStateTests`). Run on their own, those four suites pass (32 of 32). I read that as load on this machine during the parallel run, but did not compare with a run of `main`.
- App tests (`xcodebuild … test`, macOS): 276 of 276 pass.
- macOS builds: Debug and universal Release both succeed. Details in the last section.
- iOS: the iPhone and iPad app shares none of this code (it doesn't link VespertineKit), so it was not built. Its output list gets the Mac's new second line for a Sonos through the remote protocol; that was not looked at.

## Not verified: needs a real Sonos

- That Sonos answers the search and its arrangement call as expected, and accepts the song's metadata. High confidence (this is how every third-party Sonos controller works), but unproven here.
- That Sonos can fetch from the Mac. macOS will ask for local-network access once, and the firewall must let Vespertine accept connections.
- **Gapless.** The next song is handed to Sonos ahead of time. Whether Sonos joins the two without a gap for songs played this way is unknown. If it doesn't move on by itself, Vespertine starts the next song when the current one ends: a gap of a second or so.
- The fallback for a song that takes more than two minutes to prepare (it is then offered while still being written). Sonos may not play a stream without a length.
- What a grouped speaker does if rooms are regrouped in the Sonos app between two searches (every 5 minutes and whenever the output list opens). The error message says to choose the room again.
- Everything on screen. The app builds and its tests pass, but I did not look at the output list, the Sonos notes or the volume slider in a running app.

## Known gaps

- **Translations.** 47 new English strings are not in the String Catalog, so `scripts/check-localizations.py` fails (it was clean before). The app shows them in English in every language. They need the usual translation pass before this merges. List: `python3 scripts/check-localizations.py`.
- **First song of a hi-res album starts late.** A song above 48 kHz is converted before Sonos is told about it. Measured here in a debug build with other builds running: 15 to 20 times faster than real time, so about 15 to 20 s for a 5-minute song; a release build should be quicker (not measured). The Inspector shows "Preparing output…" meanwhile. Later songs are prepared while the one before plays. Songs within Sonos's limits start at once.
- **A surround WAV with no speaker names** (plain 6-channel PCM header, no channel mask) came out silent when folded to stereo for a network stream. That is the Apple converter's behaviour the architecture notes already describe; real surround files carry speaker names and fold correctly (tested). Not fixed here.
- **No surround to Sonos, by design of Sonos, not of this work** (next section).
- The first `vespertine-probe sonos` run hung (a deadlock in the new command, since fixed); it was stopped by the harness at its 10-minute limit. The fixed command ran here in about 4 s and found no players, as expected on this network.

## The Playbar, exactly

- **From Vespertine over the network:** stereo, up to 24-bit / 48 kHz. FLAC and Apple Lossless at or under that go as the file itself. Everything else is converted as the table says and labelled.
- **No Dolby Atmos, ever.** The Playbar has no HDMI, and optical can't carry Dolby Digital Plus or Atmos. No Atmos music from services either on this model.
- **No surround from a computer's music files.** Sonos plays only mono and stereo files from a library; 5.1 FLAC is refused by Sonos itself. A 5.1 song is folded to stereo by Vespertine and the list says so first.
- **Stereo into the 5.1 room** is Sonos's doing: all five speakers and the Sub play, and the two Ones follow Sonos app › Settings › the room › Surround Audio › **Music Playback**: *Ambient* (quiet, the default) or *Full* (full range, as loud as the front). The surround level for music is on the same page. Vespertine shows which one is set and doesn't change it; which you prefer is your call.
- **Real 5.1 on the Playbar** exists only through the TV's optical output as Dolby Digital 5.1. In principle a Dolby Digital 5.1 file sent as a bitstream from the Mac over HDMI to the TV could pass through; that depends on the TV and is untested.
- **No AirPlay 2** on the Playbar, and Ones bonded as surrounds can't be AirPlay targets, so the network route above is the only lossless way in from the Mac.

## Five minutes at home

Before: this branch built and running on the Mac you will play from, on the same network as the Sonos (Wi-Fi or Ethernet, not a guest network).

1. **Switch it on.** Settings › Playback › Network Players (Sonos and UPnP, beta). Allow local-network access if macOS asks.
2. **Open the output list** (the output chip in the transport bar). Expect one row named after the room, second line `SONOS · 5.1 · UP TO 24/48 · STEREO`, and no rows for the Ones or the Sub.
   - No row, or extra rows: in Terminal, `cd Packages/VespertineKit && swift run vespertine-probe sonos` and keep the output.
3. **CD-quality song.** Load a 16-bit / 44.1 kHz FLAC. The row should read "Will play 16-bit / 44.1 kHz FLAC, stereo, the file as it is". Choose the row, press play. Sound within a few seconds; badge `BIT-PERFECT · 16/44.1 SENT`.
   - "couldn't play the song (UPnP error 716 …)": System Settings › Network › Firewall, allow Vespertine, try again.
4. **Hi-res song (24/96 or 24/192).** The row should read "Will play 24-bit / 48 kHz FLAC, stereo (source 24/192)" in copper. Play it: expect up to 20 s of "Preparing output…", then sound; badge `RESAMPLED · 24/48 SENT`; the signal path has a "Player limit" line.
5. **Controls.** Pause, play, drag the position, skip forward. Drag the volume slider marked SONOS and watch the Sonos app follow.
6. **Two songs in a row.** Let one end into the next (a live or classical album shows it best). Note: no gap, or a gap of about a second. This is the one thing nobody could check in advance.
7. **A 5.1 or DSD song.** The row should say it is folded to stereo or converted, before you play it.
8. **Surrounds.** In the output list under the room: "Surrounds for music: Ambient" or "Full". Try both in the Sonos app (Settings › the room › Surround Audio › Music Playback) and keep the one you like.
9. **Quit Vespertine** while it plays: the Sonos should stop within a couple of seconds.

For the other outputs you meet that day, the output list's "Will play …" line is the check: read it before choosing the output, and compare with the badge once the song plays. docs/output-routes.md says what each route can carry at best.

## Final build and test figures

All on this machine (macOS, Apple silicon), after the last code change unless noted.

| Check | Result |
|---|---|
| Network player and AirPlay test targets (`swift test --filter "VespertineUPnPTests\|VespertineAirPlayTests"`) | 346 tests, all pass (run after the last change) |
| Whole `Packages/VespertineKit` suite | 1483 tests: 1478 pass, 5 fail in the parallel run and pass on their own (above). Run before the last three small changes (surround mode read, a longer whole-file wait, one message reused) |
| App tests (`xcodebuild … CODE_SIGNING_ALLOWED=NO test`) | 276 tests in 59 suites, all pass (run before the whole-file wait changed from 30 s to 120 s, a one-number change in the package) |
| macOS app, Debug build | Succeeds (after the last change) |
| macOS app, universal Release build (`ONLY_ACTIVE_ARCH=NO`) | Succeeds (before the same one-number change) |
| `git diff --check` | Clean |
| `scripts/check-localizations.py` | **Fails: 47 new strings, English only** |
| iOS app | Not built: shares no code with this change |
| A real Sonos, or any real output | Not tested |

Logs are in `build/logs/` (not committed): `kit-tests.log`, `kit-rerun.log`, `network-tests.log`, `app-tests.log`, `release-build.log`, `localization.log`.
