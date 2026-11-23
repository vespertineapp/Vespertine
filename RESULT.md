# Sonos and output routes: result

Branch `feat/sonos-and-output-routes`, local commits only (unsigned, not pushed). Nothing here has been heard on a real Sonos; Sonos-specific behaviour is verified against a pretend Sonos on 127.0.0.1 and against Sonos's documentation and the SoCo library's source. The checklist at the end is the first real test.

## What the branch adds

- **Sonos rooms as outputs**, behind Settings › Playback › Network Players (Sonos and UPnP, beta), off by default (no search, no port until switched on). One row per room or group; surrounds, Sub and the second speaker of a pair aren't listed.
- **Sonos's limits applied by one table** (`StreamLimits.sonos`): the file itself when it fits; otherwise 24-bit FLAC at 48 or 44.1 kHz (whichever divides the source rate), folded to stereo, DSD as PCM. Written whole before Sonos is told, so it can seek.
- **No silent downgrade**: every output row says what the loaded song would be played as ("Will play 24-bit / 48 kHz FLAC, stereo (source 24/96)", copper when samples change); while playing, the badge (RESAMPLED / FOLDED TO STEREO / DSD AS PCM · 24/48 SENT) and a "Player limit" line in the signal path. Same planner for DACs, HDMI, Bluetooth, AirPlay and other network players.
- **Sonos volume** slider (room or group), the room's details (speaker setup, Music Playback Ambient/Full, read only), plain error for "couldn't fetch" (firewall), `vespertine-probe sonos`, and docs/output-routes.md.

## This pass (2026-11-23)

1. **Translations**: the 47 new strings are in the String Catalog in all 44 languages; `scripts/check-localizations.py` passes. Four keys take integers, so they are `%lld` in the catalog, not `%@` (the check can't tell). The Sonos app's own setting names (Music Playback, Ambient, Full) are translated in the ordinary way; I couldn't check them against Sonos's own translated screens.
2. **6-channel WAV with no channel mask**: was silent when folded to stereo. Now it is taken as L R C LFE Ls Rs (the WAVE_FORMAT_EXTENSIBLE default) and folds sample for sample like the same file with the 5.1 mask; 3, 4, 7 and 8 unnamed channels fold to stereo in WAV order with sound in both channels. Cause: Apple's converter mixes by the *buffer's* layout ("unknown, 6 channels"), whatever its own input format says, so the decoder's buffer is handed over through a second buffer over the same memory carrying the 5.1 layout (`OutputSession.namedForFold`, `EngineDecoding`). This applies to every stereo or mono output, not only network streams. Tests: `LimitedStreamTests`.
3. **Screens** (docs/screens-sonos/): the Debug app was run with Network Players on, a test library, and the tests' pretend Sonos (a Playbar room, 5.1, Ambient) plus a plain OpenHome player. Shots: the output list with a 24/96 song and with a 5.1 song loaded, the Sonos notes, both songs playing (badge, Player limit line), and the volume slider. I read every shot. Two layout fixes: the detail labels were too narrow ("Surrounds for music" wrapped onto two lines), and the Sonos slider ran into Vespertine's own "100% · LOCKED" volume, so the two read as one control; there is now a divider between them. Two QA launch arguments make this repeatable: `-VespertineRendererDemo <description URLs>` (debug builds only: discovery finds exactly those players and sends nothing on the network) and `-VespertineOpenSheet outputs`.
4. **Tests and builds**: below.

## Test and build figures (this machine, after the last change)

TESTS_PLACEHOLDER

## Not verified: needs a real Sonos

- That a real Sonos answers the search and the arrangement call, accepts the metadata, and can fetch from the Mac (macOS asks for local-network access once; the firewall must let Vespertine accept connections).
- **Gapless**: the next song is handed over ahead of time; whether Sonos joins them without a gap is unknown (fallback: a gap of about a second).
- A song that takes over two minutes to prepare is offered while still being written; Sonos may refuse a stream without a length.
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
2. Output list: one row named after the room, `SONOS · 5.1 · UP TO 24/48 · STEREO`, no rows for the Ones or the Sub. Otherwise: `cd Packages/VespertineKit && swift run vespertine-probe sonos` and keep the output.
3. A 16/44.1 FLAC: "Will play 16-bit / 44.1 kHz FLAC, stereo, the file as it is"; plays within seconds; badge `BIT-PERFECT · 16/44.1 SENT`. "UPnP error 716": allow Vespertine in System Settings › Network › Firewall.
4. A 24/96 or 24/192 song: copper "Will play 24-bit / 48 kHz FLAC, stereo (source …)"; up to 20 s "Preparing output…"; badge `RESAMPLED · 24/48 SENT`; "Player limit" in the signal path.
5. Pause, play, seek, skip; move the SONOS volume slider and watch the Sonos app follow.
6. Let one song run into the next: gap or none (the one thing nobody could check in advance).
7. A 5.1 or DSD song: the row says folded / converted before you play it.
8. "Surrounds for music" in the room's details: try Ambient and Full in the Sonos app.
9. Quit Vespertine while playing: the Sonos stops within a couple of seconds.
