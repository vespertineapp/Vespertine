# Sonos and output routes: result

Branch `feat/sonos-and-output-routes`, local commits only, not pushed; `git log --format=%G?` shows a good signature on every commit since `main`. Target: 1.2.4 (build 77). Nothing here has been heard on a real Sonos; Sonos-specific behaviour is verified against a pretend Sonos on 127.0.0.1 and against Sonos's documentation and the SoCo library's source. The checklist at the end is the first real test.

## What the branch adds

- **Sonos rooms as outputs**, behind Settings › Playback › Network Players (Sonos and UPnP, beta), off by default (no search, no port until switched on). One row per room or group; surrounds, Sub and the second speaker of a pair aren't listed.
- **Sonos's limits applied by one table** (`StreamLimits.sonos`, `.sonosS1`): the file itself when it fits (per codec within a file type); otherwise FLAC at 48 or 44.1 kHz (whichever divides the source rate), 24-bit on S2 and 16-bit on S1 (or a speaker that doesn't say), folded to stereo, DSD as PCM. Written whole before Sonos is told, so it can seek.
- **No silent downgrade**: every output row says what the loaded song would be played as ("Will play 24-bit / 48 kHz FLAC, stereo (source 24/96)", copper when samples change); while playing, the badge (RESAMPLED / FOLDED TO STEREO / DSD AS PCM · 24/48 SENT) and a "Player limit" line in the signal path. Same planner for DACs, HDMI, Bluetooth, AirPlay and other network players.
- **Sonos volume** slider (room or group), the room's details (speaker setup, Music Playback Ambient/Full, read only), plain error for "couldn't fetch" (firewall), `vespertine-probe sonos`, and docs/output-routes.md.

## The ninth review's findings (2026-11-23, 13:55 onwards)

A ninth review (Codex, run 8028b6) found two P2s in `RendererPlayback.swift` and two points of hygiene. Signed commits 2a1c2149 (P2 1), 4b4e15ce (P2 2) and 42b17abd (hygiene), each with its test written first and seen failing, and two RESULT commits (c708e200, interim, and this one); nothing pushed.

**P2 1, a refused pause or resume was put right over a newer command.** A pause or resume the player refused twice asked it for its status and set `wantsPlaying` and the snapshot from the answer. With a song chosen (or a Stop, pause or resume given) while that status was on its way, the answer was still the old song's. If the old song was paused, the chosen song's start found `wantsPlaying` false and paused it on the player, and the old refusal was reported. Now pause and resume carry the intent they set (`State.intent`, which every pause, resume, stop and song chosen counts up). The second try isn't sent once a newer one has come. The resync, under the generation lock and then the state lock (as `play()` and `stop()` take them), applies the player's state and reports the refusal only while that intent is still the last one asked for, in the same step.
- `staleResumeResyncAfterSelection`: Play is refused; the status asked for after the second refusal is held while a song is chosen, then answered with the old song, paused. **Red before** (5 issues: the chosen song never started, `wantsPlaying` false, the snapshot and the player paused, the notice delivered). New test hooks: `GatedTransport.failsPlay`, `holdsStatusAfterFailedPlay`.

**P2 2, a song prepared as the next was played with the settings it was made with.** Since the eighth pass, a change of settings queued before a song chosen no longer restarts the old song, so it doesn't prepare the next song again either. When the song chosen was the one already prepared as the next, `start` took that entry as it was: a processed stream made with the old settings, so a -6 dB change was lost for that song. Now every change of settings counts up `State.settingsRevision`, and each entry records the revision it was made with, read together with the settings. `start` reuses the prepared next song only when it was made with the settings in force. Otherwise the song is made again, and the one prepared is let go of with the old songs once the new one is loaded.
- `preparedNextRebuiltForNewSettings`: the converted song is prepared as the next with the default settings; the worker is held in a poll while a -6 dB change and then a play of that song are queued. **Red before** (3 issues: no stream made again, the old stream loaded, the volume stage not -6 dB).

**Hygiene.** The public initialiser took a `pollInterval` of 0 (or less, or not a number) as "no poller", a mode meant for tests: an app passing one would never see a song start or end, or a renderer lost. It now keeps the interval between `minimumPollInterval` (50 ms) and `maximumPollInterval` (60 s), and a value that isn't a number gets the default (0.5 s). The no-poller mode moved to an internal initialiser (`polling: nil`), which the test rigs use. `queueSettingsForTests` (it skips the settings pause and moves `settingsGeneration` on) is now compiled in debug builds only (`#if DEBUG`), and so are the two tests that use it, `settingsRestartQueuedBeforeCommand` and `preparedNextRebuiltForNewSettings`: `swift test -c release` doesn't run them.
- `pollIntervalClamped` (3 cases: 0, -1, NaN, through the public initialiser): **red before, all 3** (the song never announced: no poller). The checks of the interval kept (and of 2 s and infinity) were added with the fix, since the property didn't exist before.
- Red run: `build/logs/r11/red.log` (3 tests, 5 cases, 11 issues; all 5 cases red). After each fix its test passed (`fix1-green.log`, `fix2-green.log`, `fix3-green.log`).

Not changed: the other test hooks (`settleForTests`, `queuePollForTests`, `restartForTests`) are still compiled in release builds. They are internal, so outside the package they can only be reached through `@testable import`. A refused seek still isn't tagged; it checks its own target in `seek`. A player that goes on by itself to a next song made just before a change of settings plays it as it was made: the change makes the next song again, but the player may already have reached it.

### Test figures, this pass

Logs: `build/logs/r11/` and the audit folder named below. All from the code at 42b17abd. Other work was running on the machine (load average 13 to 32 on 8 cores).

- **UPnP and Sonos** (`swift test --filter VespertineUPnPTests`, debug, 14:05 to 14:06, load average 15 to 18): **passed**, 190 tests in 33 suites, 0 failed (187 before, plus the 3 new tests, 5 cases) (`upnp.log`).
- **The rest of the audit** (`audit-rest.sh`, `scripts/audit.sh` without its first step, the same script as in the last four passes; 14:06 to 14:26, `build/audit-rest-20261123-140647/`, load average 13 to 32): **script exit 0, "All audit checks passed"**. **Release-mode package tests** (`swift test -c release`): engine **1484 tests in 235 suites, passed**; UPnP and Sonos **188** (the 190 above less the two debug-only tests), library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four: **every group passed, 0 failed**. Analysis package **72 tests in 8 suites, passed**. Sanitizer runs (address/undefined, thread) clean; DST audit "1800 random frames, 1712 rejected; crafted frames handled"; static analysis 0 findings for both. **App tests** (`xcodebuild test`, Debug, `build/AuditDD`) **284 tests in 61 suites, passed** (`** TEST SUCCEEDED **`; the app's one `RendererPlayback(...)` call is unchanged and now goes through the public initialiser's clamp). Release universal build `** BUILD SUCCEEDED **` (so the `#if DEBUG` hook isn't needed there); `git diff --check` clean.

Not run this pass: `scripts/audit.sh`'s first step, the whole package in debug mode. Nothing here has been heard on a real Sonos.

## The eighth review's findings (2026-11-23, 12:50 onwards)

An eighth review (Codex, run 8ec6f3) found two P2s in `RendererPlayback.swift`. The first is the gap the seventh pass left open (its "Not changed" note, below). Signed commits 13b4db2c (P2 1) and fd43c53f (P2 2), each with its test written first and seen failing, and two RESULT commits (8c8f6604, interim, and this one); nothing pushed.

**P2 1, a change of settings queued before a Stop or a song chosen overtook it.** A change of settings that restarts the song playing (any change for a processed stream, or one that changes what is done to the song) ran on the worker as an unconditional `play(…, announce: false)`, the same pattern as the seventh pass's seek. Queued ahead of a song chosen, it moved the generation past the chosen song's play, which was dropped as stale, and the old song was loaded again. Queued ahead of a Stop, it loaded the old song again after the Stop (paused). Now `apply` reads the song loaded and the play it was loaded for (`currentGeneration`) in one step. It restarts the song only while that is still the current play, checked under the generation lock (generation, then state, as `play()` and `stop()` take them). The settings are kept either way, so the song chosen, or a restart already queued, is made with them. It checks the generation, not the selection as the seek does: if a restart is already queued (a seek or an earlier change), the song is made again with the settings in force when its turn comes, so this one needn't restart it too.
- `settingsRestartQueuedBeforeCommand` (2 cases, Stop or a song chosen): the converted song plays from a stream that is never finished. The worker is held in a poll while the change (a volume, through a new hook `queueSettingsForTests`) and then the command are queued. It also checks that the settings still apply: the song chosen, or the song played after the Stop, is made with them. **Red before, both cases** (8 issues: the old song's stream was made and loaded again; after Stop it stayed loaded; the chosen song never started).

**P2 2, a seek that landed left the start's older pending seek.** A song started part-way in keeps its position as a pending seek until a poll sees it play. A seek asked for before then was carried out, but `pendingSeek` and its count of tries were left, so the next poll sent the start's older position after it and the song jumped back. The seek's own state update, already checked against the selection and the song it was asked for, now clears both. A refused seek leaves them as they were.
- `explicitSeekClearsPendingSeek`: no polls but the test's own (the rig now takes a `pollInterval`); the song is started at 30 s, loaded, seeked to 60 s, and settled twice. **Red before** (a `Seek` to 30 s sent after the one to 60 s, and the position left at 30 s).
- Red run: `build/logs/r10/red.log` (2 tests, 3 cases, 10 issues; all 3 cases red). With the first fix alone, its test passed (`fix1-green.log`); after both, `NextPreparationTests`: 33 tests, all passed (`green.log`).

### Test figures, this pass

Logs: `build/logs/r10/` and the audit folder named below. All from the code at fd43c53f. Other work was running on the machine (load average up to 577 on 8 cores during the red run, 175 to 380 for the UPnP run).

- **UPnP and Sonos** (`swift test --filter VespertineUPnPTests`, debug): **passed**, 187 tests in 33 suites, 0 failed (185 before, plus the 2 new tests, 3 cases) (`upnp.log`).
- **The rest of the audit** (`audit-rest.sh`, `scripts/audit.sh` without its first step, the same script as in the last three passes; 13:12 to 13:51, `build/audit-rest-20261123-131256/`, load average 32 to 513): **script exit 0, "All audit checks passed"**. **Release-mode package tests** (`swift test -c release`): engine **1484 tests in 235 suites, passed**; UPnP and Sonos **187**, library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four: **every group passed, 0 failed**. Analysis package **72 tests in 8 suites, passed**. Sanitizer runs (address/undefined, thread) clean; DST audit "1800 random frames, 1712 rejected; crafted frames handled"; static analysis 0 findings for both. **App tests** (`xcodebuild test`, Debug, `build/AuditDD`) **284 tests in 61 suites, passed** (`** TEST SUCCEEDED **`; no app code changed). Release universal build `** BUILD SUCCEEDED **`; `git diff --check` clean.

Not run this pass: `scripts/audit.sh`'s first step, the whole package in debug mode (its engine group has failed timing tests on this loaded machine in each of the last runs; the same 1484 engine tests passed in release mode here). Nothing here has been heard on a real Sonos.

## The seventh review's findings (2026-11-23, 11:55 onwards)

A seventh review (Codex, run fbdae0) found two P2s in `RendererPlayback.swift`, both there before this branch's review passes. Signed commits d9750e53 (P2 1) and 69447320 (P2 2), each with its test written first and seen failing, and this RESULT commit; nothing pushed.

**P2 1, a seek queued before a Stop or a song chosen overtook it.** A seek in a processed stream the player can't seek in (one offered while it was still being written) starts the song again at the position. That restart ran on the worker as an unconditional `play(…, announce: false)`. Queued ahead of a song chosen, it moved the generation past the chosen song's play, which was then dropped as stale, and the old song was loaded again. Queued ahead of a Stop, it loaded the old song again after the Stop (paused). Now `seek(to:)` notes the selection (`State.selection`) and the song shown when it is asked for. On the worker the seek does nothing unless both still hold for the song loaded, and the restart is made only while the selection is unchanged, checked under the generation lock, where `stop()` and `play()` move it. It checks the selection, not the generation, because a restart for an earlier seek or a change of settings moves the generation on, and the last seek asked for must still win. A seek the player does itself updates the snapshot only while the same check holds. Checking the song as well means a seek asked for just before the player went on to its next song isn't applied to that next song.
- `processedSeekQueuedBeforeCommand` (2 cases, Stop or a song chosen): the converted song plays from a stream that is never finished. The worker is held in a poll while the seek and then the command are queued. **Red before, both cases** (7 issues: the old song's stream was made and loaded again; after Stop it stayed loaded; the chosen song never started).

**P2 2, a pending seek was carried to the song the player went on to.** A song started part-way in keeps its position as a pending seek until the player plays it. If the player refused that seek and then went on to its next song by itself, the poll that followed it made the next song current but kept `pendingSeek` and its count of tries. It then sent the old song's position to the new song. The poll that follows the player now clears both, with the rest of the song's state.
- `pendingSeekNotCarriedToNextSong`: the first song is started at 1 s and is kept from playing until its next song has been handed to the player. Then it plays, the seek is refused once, and the poll after it is held while the player goes on. **Red before** (a `Seek` was sent to the next song). New test hooks: `GatedTransport.holdsStatusAfterFailedSeek`, `FakeRenderer.playOnDevice`.
- Red run: `build/logs/r9/red.log` (2 tests, 3 cases, 8 issues; all 3 cases red). After both fixes, `NextPreparationTests`: 31 tests, all passed (`green.log`).

Not changed then (closed in the eighth pass, above): a change of settings while a song plays restarts it the same way (`apply`, an unconditional `play(…, announce: false)` on the worker). A `.settings` command already queued when Stop is pressed, or when a song is chosen, looks open to the same overtaking. The review didn't name it.

### Test figures, this pass

Logs: `build/logs/r9/` and the audit folder named below. All from the code at 69447320. Other work was running on the machine (load average 38 to 103 on 8 cores).

- **UPnP and Sonos** (`swift test --filter VespertineUPnPTests`, debug, 12:05 to 12:07): **passed**, 185 tests in 33 suites, 0 failed (183 before, plus the 2 new tests, 3 cases) (`upnp.log`).
- **The rest of the audit** (`audit-rest.sh`, `scripts/audit.sh` without its first step, the same script as in the last two passes; 12:07 to 12:38, `build/audit-rest-20261123-120718/`, load average 38 to 75): **script exit 0, "All audit checks passed"**. **Release-mode package tests** (`swift test -c release`): engine **1484 tests in 235 suites, passed**; UPnP and Sonos **185**, library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four: **every group passed, 0 failed**. Analysis package **72 tests in 8 suites, passed**. Sanitizer runs (address/undefined, thread) clean; DST audit "1800 random frames, 1712 rejected; crafted frames handled"; static analysis 0 findings for both. **App tests** (`xcodebuild test`, Debug, `build/AuditDD`) **284 tests in 61 suites, passed** (`** TEST SUCCEEDED **`; no app code changed). Release universal build `** BUILD SUCCEEDED **`; `git diff --check` clean.

Not run this pass: `scripts/audit.sh`'s first step, the whole package in debug mode. On this loaded machine its engine group failed timing tests in each of the last runs (above); the same 1484 engine tests passed in release mode here.

## The two gaps the sixth pass left open (2026-11-23, 10:40 onwards)

Closes the sixth pass's "Not changed (unverified)" note (below). Signed commits 6cb41f71 (`fail()`) and 58e969c0 (the seek notice), each with its tests written first, and this RESULT commit; nothing pushed.

**`fail()` checked, then failed the song, outside the lock and untagged.** A start that couldn't prepare its song checked `overtaken()` and then marked it failed and emitted `.failed`, with nothing holding the generation between the two. A start whose load the player refused (the catch in `run()`) didn't check at all: a Stop given while the load was on its way was followed by the old error, and a song played again then loaded paused, since the failure set `wantsPlaying` to false after the new play had set it. Now `fail()` takes the play's generation and, under the generation lock in one step, checks that it is still the current play (and the output still held), marks the song failed and reads `State.selection`; `.failed` carries that selection and is checked again on the main actor, like the other events. The failure now names the song that failed (the item the start was for), not the song still loaded on the player, which the app's handler (`PlayerController`, "about a song skipped past") would have compared against the song it asked for.
- `loadFailureOvertaken` (2 cases, Stop or Play again): the test transport holds the load, decided to fail, while the command is given. **Red before, both cases** (5 issues: the failure reported; for Play again the song never started, `wantsPlaying` false, paused).
- `preparationFailureOvertakenBeforeDelivery` (2 cases): the stream maker fails; the main actor is kept busy until the song has been failed, then the command is given there. **Red before, both cases** (the failure delivered).

**The seek given up wasn't tagged.** The notice that a pending seek (a song started part-way in) was given up after five refusals now carries the selection read in the same locked step that gives the seek up.
- `seekGivenUpOvertakenBeforeDelivery`: the test transport refuses every seek; the main actor is kept busy until the fifth refusal, then Stop is pressed there. **Red before** (the notice delivered after Stop).
- `seekGivenUpReported`: with nothing in between the notice is still given (passed before and after; it guards the tag dropping too much).
- Red run: `build/logs/r8/red.log` (4 tests, 6 cases, 8 issues; 5 cases red). After the first fix only the seek test was red (`fail-green.log`); after both, `NextPreparationTests`: 29 tests, all passed (`green.log`).

Not changed: the notices for a refused pause, play or seek given by the listener (`retrying`) stay untagged; they answer the listener's own command, not a song's progress.

### Test figures, this pass

Logs: `build/logs/r8/` and the audit folders named below. All from the code at 58e969c0. Other work was running on the machine the whole time (load average 56 to 210 on 8 cores).

- **`scripts/audit.sh`, whole, first run** (10:49 to 11:09, `build/audit-20261123-104954/`, load average 150 to 210): it stopped at its first step (whole package, debug). Engine (`VespertineAudioTests`): 1484 tests in 235 suites, **8 failed** (11 issues), all timing tests starved by the load: `VisualizerTapTests` neverBlocksNeverTears ("elapsed < 20"), `NetworkPriorityTests` playbackPreemptsScan and scanPausesThenResumes (120 s time limit), `ShareCloseTests` pressWhileCloseWaits and skipWhileCloseWaits, `AtmosRouteChangeTests` otherRenderersIgnored and refedFromTheFlushTime ("fed"), `PlayPauseStateTests` pauseWhileSessionReplaced. Each took 70 to 620 s. Every other group passed: **UPnP and Sonos 183 tests in 33 suites** (179 before, plus the 4 new tests, 6 cases), library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four. The 8 run again alone (`engine-failing-alone.log`, load about 85): **8 tests in 5 suites, passed**.
- **`scripts/audit.sh`, whole, second run** (11:10 to 11:27, `build/audit-20261123-111005/`, load average 70 to 110): it stopped at the same step. Engine 1484 tests, **7 failed** (11 issues), all timing tests: `RateJoinStopTests` stopDuringRateJoin (skip case), `BedMeterTests` rendererInputUntouched ("run.exhausted"), and `ShareCloseTests` pressWhileCloseWaits and skipWhileCloseWaits, `NetworkPriorityTests` playbackPreemptsScan and scanPausesThenResumes, `AtmosRouteChangeTests` refedFromTheFlushTime again. Every other group passed, with the same counts as above. The 7 run again alone (`engine-failing2-alone.log`): **7 tests in 5 suites, passed**. None of the 11 distinct failing tests touches the renderer code. Two of them, `RateJoinStopTests` and `AtmosRouteChangeTests`, also failed under load in the earlier full audit (below).
- **The rest of the audit** (`audit-rest.sh`, the script minus its first step, the same as in the earlier pass; 11:27 to 11:48, `build/audit-rest-20261123-112729/`, load average 57 to 81): **script exit 0, "All audit checks passed"**. **Release-mode package tests** (`swift test -c release`): engine **1484 tests in 235 suites, passed**; UPnP and Sonos **183**, library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four: **every group passed, 0 failed**. Analysis package **72 tests in 8 suites, passed**. Sanitizer runs (address/undefined, thread), the DST audit (1800 random frames, 1712 rejected; crafted frames handled) and the static checks were clean. **App tests** (`xcodebuild test`, Debug) **284 tests in 61 suites, passed** (`** TEST SUCCEEDED **`). The Release universal build reported `** BUILD SUCCEEDED **`, and `git diff --check` was clean.

So every step of `audit.sh` passed, except that the debug engine group never passed whole on this loaded machine. Its failing tests passed on their own runs and in release mode.

## The sixth review's findings (2026-11-23, about 10:00 to 10:45)

A sixth review (Codex) found a P2 and a P3 in `RendererPlayback.swift`. Signed commits 335bba05 (P2) and d24ef998 (P3), each with its tests, and this RESULT commit; nothing pushed.

**P2, a failing poll queued before a song chosen let the player go as lost.** This closes the "Not changed (unverified)" note in the pass below. When a poll failed for the last time before the player counted as lost, it cleared the songs and set `wantsPlaying` to false, whichever play it had been asked for. If that poll was queued ahead of a song chosen (`play()` had already moved the generation on), the chosen song loaded paused, and the player was reported lost even though it answered again. Now the poll notes the play of the song loaded (`currentGeneration`) before it asks for the status. It lets the player go as lost only while that is still the current play, checked under the generation lock in the same step as the clean-up (`ifStill`). The failed poll is still counted; the start that follows resets the count.
- Test `lostPollQueuedBeforeSelection`: the test transport fails status requests (decided when each request begins) and holds one past `lostAfter` (1 s) while a song is chosen. **Red before** (4 issues: the chosen song never started, "lost" reported, `wantsPlaying` false, not playing).

**P3, the start timeout's failure was reported after a Stop or Play again.** The timeout failed the old song under the lock, then waited for the player to stop before it emitted `.failed`. A Stop or Play pressed during that wait still had the old error delivered, and so did one pressed before the event's turn came on the main actor. Announcements (`trackStarted`) had the same gap. Now each event about a song carries the selection it was decided in. `State.selection` counts up at every stop and every song chosen, but not when the same song is restarted at a position (a seek in a processed stream, a change of settings), which also moves the generation on. The tag is read in the same locked step as the state change, and checked again on the main actor just before the handler runs, which is where the app gives its commands. Tagged: the start timeout's `.failed`, `trackStarted`, `deviceLost`, and `queueEnded` on both of its paths (the put-right path also waits for a Stop before it emits).
- `timeoutFailureOvertakenDuringStop` (2 cases, Stop or Play again): the test transport holds the timeout's Stop while the command is given. **Red before, both cases** (the old failure was delivered).
- `timeoutFailureOvertakenBeforeDelivery` (2 cases): the main actor is kept busy until the failure has been sent, then the command is given there. **Red before, both cases.**
- `announcementOvertakenBeforeDelivery`: the same for a song's start and Stop. **Red before** (the song was announced after Stop).
- Red runs: `build/logs/r7/red.log` (all 4 tests, 9 issues; the first version of the P3 tests waited up to 30 s on the stuck next song), and `p3-red.log` (the final P3 tests against the P2 commit: 5 issues in 5 cases). After both fixes, `NextPreparationTests`: 25 tests, all passed (`green.log`).

Not changed then (closed in the pass above): `fail()`, which a start uses when its song can't be prepared or loaded, still checks `overtaken()` and then marks the song failed and emits outside the generation lock, with no tag. A Stop in that narrow window could still be followed by the old error. Not tested. The seek-gave-up `.notice` isn't tagged either.

### Test figures, the sixth pass

Logs: `build/logs/r7/`. Other work was running on the machine (load average 115 to 130).

- **UPnP and Sonos** (`swift test --filter VespertineUPnPTests`, debug): **passed**, 179 tests in 33 suites, 0 failed (175 before, plus the 4 new tests, 6 cases) (`upnp.log`).
- **App tests** (`xcodebuild test`, Debug, macOS, as `scripts/audit.sh` runs it, `-derivedDataPath build/AuditDD`): **passed**, 284 tests in 61 suites, 0 failed (`** TEST SUCCEEDED **`; no app code changed) (`app-tests.log`).

Not run this pass: the engine group, the release-mode tests and the rest of `scripts/audit.sh`.

## This pass: the rest of what a stale poll did (2026-11-23, 09:18 onwards)

Closes the gap the fifth pass left open (its "Not changed" note below). Signed commit 27536cca (fix and tests) and this RESULT commit; nothing pushed.

**A poll queued before a Stop or a song chosen still acted on the old song in four more ways.** 79fe6586 tied the poll's put-right, song end and snapshot to the play of the song it inspects (`currentGeneration`). The same poll, beginning after the command had moved the generation on, still:
- followed the player to the old song's next song (made it the current song, released the old one, planned the one after it) and announced that next song as started;
- announced the old song itself as started, if this was the poll that first saw it play;
- sent the old song's pending seek (a song started part-way in) to the player;
- past the start timeout, failed the old song: the listener was told it couldn't be played, `wantsPlaying` went to false, and the song chosen then loaded paused and never started.

Now each of these is done only while the inspected play is still the current one, checked under the generation lock together with the state change (a new helper, `ifStill(polled)`, the same rule as 79fe6586). The start timeout's failure (stopped, the error, `wantsPlaying` false) is applied in that same step, no longer in `fail()` afterwards, so a song chosen between the check and the failure can't be paused by it. A stale poll leaves the old song to the command queued behind it, which replaces or stops it and lets go of its entries.

Tests, written first, using `queuePollForTests()` and a new test-transport switch that holds the first status request after a load:
- `timedOutPollQueuedBeforeSelection`: the player takes the first song and never starts it; the first poll after the load is held past the start timeout (0.5 s), a second poll is queued, then a song is chosen. **Red before** (4 issues: the old song was reported failed, the chosen song never started, `wantsPlaying` false, the snapshot not playing).
- `followPollQueuedBeforeCommand` (2 cases, Stop or a song chosen): the worker is held in a poll and the player goes on to the next song by itself. **Red before, both cases** (the old next song announced as started after the command).
- `startedPollQueuedBeforeCommand` (2 cases): the first song is started at 1 s, the first poll after its load is held while the player plays. **Red before, both cases** (4 issues: the old song announced after the command, and a `Seek` sent to the player after it).
- Red run saved: `build/logs/r6/red.log` (3 tests, 5 cases, 10 issues). After the fix: `NextPreparationTests` 21 tests, all passed (`green.log`).

Not changed then (closed in the sixth pass, above): a poll that fails (no answer) still counts towards the player being lost without regard to the play; lost, it clears the songs and sets `wantsPlaying` false, which could leave a song chosen just then paused. The stale-clear retry and reconcile in a stale poll are also left as they were (the command queued behind lets go of the stale songs).

### Test figures, this pass

Logs: `build/logs/r6/`. Other work was running on the machine.

- **UPnP and Sonos** (`swift test --filter VespertineUPnPTests`, debug): **passed**, 175 tests in 33 suites, 0 failed (172 before, plus the 3 new tests, 5 cases) (`upnp.log`).
- **`scripts/audit.sh`, first step (whole package, debug)** (`audit-debug-tests.log`, 09:25 to 09:41, load average 23 to 68 on 8 cores from other work): 1484 engine tests in 235 suites with **2 failed**; every other group passed (UPnP and Sonos 175, library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four). The two: `RateJoinStopTests` "Stop while the next song at another rate waits on its share" (skip case: "The share is mounted but isn't answering") and `AtmosRouteChangeTests` "A read that doesn't return…" ("the renderer never asked for a buffer"); both took 334 s, timing tests starved by the load. Neither touches the renderer code. Run again alone (`engine-failing2-alone.log`): **4 tests in 2 suites, passed**. `audit.sh` stops at a failed step, so the rest of it was run as its own lines (`audit-rest.sh`, the script minus its first step).
- **The rest of the audit** (`audit-rest.sh`, from 09:42, load average 54 to 104 from other work): **release-mode package tests** (`swift test -c release`) at 09:58, built from this pass's code: engine (`VespertineAudioTests`) **1484 tests in 235 suites, passed**; UPnP and Sonos 175, library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four: **every group passed, 0 failed** (`release-tests.log`). Then, all passed (script exit 0, "All audit checks passed", finished 10:11): analysis package **72 tests in 8 suites, passed**; sanitizer runs (address/undefined, thread) and the DST audit and static checks clean; **app tests (`xcodebuild test`, Debug) 284 tests in 61 suites, passed** (`** TEST SUCCEEDED **`); Release universal build `** BUILD SUCCEEDED **`; `git diff --check` clean (`analysis-tests.log`, `app-tests.log`, `universal-build.log`; the rest in `build/audit-rest-20261123-094158/`). So every step of `audit.sh` passed, with the two engine timing tests in its first step passing on their own run and in release mode.

## The fifth review's finding (2026-11-23, 09:00 onwards)

A fifth review (Codex, run 481a9a) found one P2 left in the fourth pass's fix 2. Signed commit 79fe6586 (fix and tests) and this RESULT commit; nothing pushed.

**P2, a poll queued before a Stop or a song chosen could still override it.** The poll noted `generation` when it began. A poll already queued on the worker ahead of the command could begin after `stop()` or `play()` had moved the generation on, while the old song was still loaded (the command's own turn comes after the poll). It took the new generation as its own, passed the `ifStill` check, and put the stale next song right after the Stop, or over the song chosen. Now the poll takes the generation the loaded song was started for (`currentGeneration`), read together with that song, so a command queued behind it always wins. The song-end path (fix 2's "same pattern") uses the same value.

Writing the test turned up a second effect of the same ordering. The queued poll, finding the old song stopped, paused the song just chosen. It judged the song's end by the snapshot, where the selection had already set the position to 0, so it took the stop for a stop on the player and set `wantsPlaying` to false; the chosen song then loaded paused. Now what a poll finds is applied to the snapshot under the generation lock, and only while its play is still the current one.

Tests, written first: the worker is held in a poll waiting for the player's answer, a second poll is queued behind it (new test hook `queuePollForTests`), and then Stop or another song is chosen.
- `pollQueuedBeforeCommandWins` (2 cases): the player is on the stale next song. **Red before the fix, both cases** (7 issues: after Stop the queue's next song started and playback was still on; the chosen song never started, the queue's next song played instead).
- `endedPollQueuedBeforeCommandWins` (2 cases): the player stopped at the song's end. **Red before, the selection case** (the chosen song never started, left paused). The Stop case passed before too: the song-end path already did nothing once `stop()` had set `wantsPlaying` to false, so it guards behaviour rather than showing a bug.
- After the fix, both new tests and `commandDuringStalePollWins` passed (6 cases). The red runs were read from the terminal and not saved to a log.

Not changed then (closed in the next pass, above): the other things such a poll does to the old song (announcing it, following the player to its next song, a pending seek, the start timeout) are still not tied to its play. Those are put right by the command queued behind the poll. The start timeout would fail the old song after a song was chosen and could leave the chosen one paused; no test covers that.

### Test figures, the fifth pass

Logs: `build/logs/r5/`. Other work was running on the machine.

- **UPnP and Sonos** (`swift test --filter VespertineUPnPTests`, debug): **passed**, 172 tests in 33 suites, 0 failed (170 before, plus the 2 new tests, 4 cases) (`upnp.log`).
- **App tests** (`xcodebuild test`, Debug, macOS, `-derivedDataPath build/DD`): **passed**, 284 tests in 61 suites, 0 failed (`** TEST SUCCEEDED **`; no app code changed) (`app-tests.log`).

Not run this pass: the engine group, the release-mode tests and the rest of `scripts/audit.sh`.

## The fourth review's findings (2026-11-23, 08:35 onwards)

A fourth independent review (Codex) agreed the cache fix (third review, item 1) and the xHE-AAC fix (item 3) are right, and said the fix for a failed clear of the next song (item 2) was incomplete, with three findings. Each has a test written first and seen failing, then the fix. Signed commits 655f9413, 7f3dc007, e5cf73c9, and a docs/RESULT commit; nothing pushed.

1. **P2, a clear refused by the player made the transport forget the song it still held.** `AVTransportControl.replaceNext` set its `next` before the call to the player. Refused, the transport had forgotten the old next song, so `status()` filtered its address out and `RendererPlayback` never saw the player go on to it. The third pass's tests missed this because their transport threw before the real one was reached. Now `next` changes only once the player has taken the change. A next song replaced on the player also stays recognised until a status asked for after the change shows the player still on the song before. If the player is found on such a song, that address is reported and becomes the transport's current song. Tests, with the failure injected by the pretend player itself (`FakeRenderer.fail("SetNextAVTransportURI", …)`): `avRefusedClearKeepsNext` (a refused clear, and a refused new next song: the transport still reports the song the player moved on to), `avClearedAfterAdvance`, and `playerRefusedClearMovesOn` (2 cases: put right to the queue's next song, or stopped at the queue's end; the old song never announced).
2. **P2, putting a stale next song right overrode a Stop or a song chosen meanwhile.** The poll that found the player on the stale song called `play(following)` without checking the play it began in. A Stop pressed while the poll waited for the player's answer was followed by the queue's next song, and a song chosen then was overtaken. Now the poll notes the generation before it asks, and the put-right, or the stop at the queue's end, is carried out only while that is still the current play. The check and the change are made together under the generation lock, which `stop()` now takes for its own state change too. If a command came in between, it lets go of the stale song itself. The same guard now covers a song that simply ended (the same pattern; no review finding, no separate test). Test `commandDuringStalePollWins` (2 cases): the poll's status request is held, the player goes on to the stale song, then Stop, or another song is chosen, then the answer is let through. The stop or the choice stands, and the queue's next song never starts. This test can only fail once fix 1 lets the stale song be seen; it was seen failing at 655f9413 (fix 1 in, fix 2 not).
3. **P2, a confirmed clear let the old song go before the player's song was checked.** After a successful clear, the old next song was let go of at once. A player that moved on to it between the poll's status answer and the clear arriving then played a song Vespertine had forgotten: not put right, its address released. Now a next song replaced on the player (by a clear, or by a new next song, confirmed or not) stays stale, with its address and copy, until reconciled. Once the change is confirmed, no further clear is sent. The next poll, whose status was asked for after the confirmation, either puts it right (the player is on it) or lets it go (the player is on anything else). Stale songs are now a list, so a new next song confirmed while one was stale keeps both until then. Test `advanceBeforeClearCompletes`: the clear retried by a poll reaches the pretend player only after it has moved on to the old next song, and then succeeds. The queue's next song must play and the old one must never be announced. It failed before the fix, including with fixes 1 and 2 in (`red-3-isolated.log`).
4. **Retry exhaustion** (asked for, not a finding): `staleClearExhausted` (2 cases, ended by a stop or by a shutdown). A clear refused every time is sent exactly ten more times, then only watched. The song stays held and is not let go of meanwhile (its media token is still registered). A stop or a shutdown then lets go of it exactly once, and a shutdown after the stop doesn't release it again. Counting uses a new test hook (`releasesForTests`); the clears' one-second spacing is now a setting a test can shorten. This passed before fix 3 as well; it guards the behaviour, it didn't find a bug.

Not changed: OpenHome's `replaceNext` still ignores a failed `DeleteId` of the old next song (`try?`) and forgets it. That is the same kind of gap on the OpenHome side; the review named only the AV transport, and Sonos uses AV. Not tested.

docs/output-routes.md now says the old song is kept until Vespertine has seen which song Sonos is on, and that a Stop or a song chosen wins.

### Test figures, the fourth pass

On this machine, 2026-11-23 from 08:35, other work running throughout (load average 13 to 22 on 8 cores). Logs: `build/logs/r4/`.

- **Before and after**: `red-1-3.log` (all new tests, before any fix: the transport tests, `playerRefusedClearMovesOn`, `advanceBeforeClearCompletes` failed; `commandDuringStalePollWins` passed, as it can't fail before fix 1; `staleClearExhausted` failed on the test's own count, which missed the empty NextURI the first song's load sends, and the count was corrected), `red-2.log` (after fix 1: `commandDuringStalePollWins` failed, both cases), `red-3-isolated.log` (fixes 1 and 2 only), then `green-2.log` and `green-3.log`.
- **UPnP and Sonos** (`VespertineUPnPTests`, debug): **170 passed**, 0 failed (164 before, plus the 6 new tests) (`upnp.log`). A first run (`upnp-stale-binary.log`, 1 failure) used a test binary left from the red-3 check, with fix 3 out; rebuilt, it passed.
- **The new tests, repeated**: `NextPreparationTests` and the two transport tests, 18 tests, 3 runs in a row: all passed each time (`repeat-3.log`).
- **App tests** (`xcodebuild test`, Debug, macOS, `-derivedDataPath build/DD`) at e5cf73c9: **passed**, 284 tests in 61 suites, 0 failed (`** TEST SUCCEEDED **`; `app-tests.log`). No app code changed in this pass.
- **Release-mode package tests** (`swift test -c release`, scratch path `build/swiftpm-release`, run once): **passed**, every group, 0 failed, 08:53 to 08:59 (build included). Engine (`VespertineAudioTests`) 1484 tests in 235 suites; UPnP and Sonos 170 (the new tests among them, so built from this pass's code); library 274; AirPlay 2 211; and 151, 73, 37 and 31 in the other four (`release-tests.log`).
- Not run this pass: the whole package in debug mode, the analysis package, the sanitizer checks, the Release app build.

## The third review's findings (2026-11-23, 07:45 onwards)

A third independent review of 3e6cd9b9 still said not to ship. Each of its three findings has a test written first and seen failing (`build/logs/r3/red-*.log`), then the fix (`green-*.log`). Signed commits 9bed9b51, 86835ab1, a1f8bc30, the follow-up 7dd60ab6 (see item 2), and ee0d1fc0 for the docs; nothing pushed.

1. **P1, switching from a network player to the Mac failed the song.** A streamed song is one shared copy in the playback cache. If the listener switched from a network player to the Mac while the current song was still downloading, the Mac's engine picked up that same copy, and then the player's preparation, being given up, cancelled the copy outright (`entry.cancel()` in `StagedRemoteFile.stage`). The Mac then failed with "The operation was cancelled." Now a preparation that gives up only lets go of its hold on the copy. The download is cancelled when nobody holds it any more, so it carries on for the Mac. Test (`StagedHandoffTests`, real engine): a slow stream that sends 256 KiB and then pauses. The player's preparation is waiting on it, the engine starts the same song and waits on the same copy, the player gives up, then the rest arrives. The Mac must play. Before the fix it failed with exactly "The operation was cancelled." A player that gives up a download nobody else holds still cancels it at once; the existing `remoteDownloadFreesTheQueue` and `remoteDownloadStop` tests check that, and still pass.
2. **P2, a failed clear of the old next song let it go too early.** After a queue edit Vespertine tells the player to drop its old next song (an empty NextURI). If that call failed, Vespertine let the old song go anyway (its web address and its copy) while the player might still hold it and move on to it. Now the song is kept, as a stale next song, until a clear or a new next song is confirmed. The status polls send the clear again, once a second and ten times at most, so a player that always refuses an empty NextURI isn't asked for ever. If the player moves on to the stale song anyway, Vespertine recognises it, never announces it, and plays the song the queue has after the one that ended, or stops the player at the end of the queue. A failed hand-over of a new next song now keeps what the player held in the same way, instead of letting it go. In a follow-up commit (7dd60ab6, found when re-reading the change), the stale song is let go of as soon as it is put right. Otherwise, if the right song then failed to start, every poll would find the stale song again and try to start the right one again. Tests (a transport that refuses any change of the next song): the song stays held while the clear is refused, and is cleared and let go once the player answers again; a player that moves on to it is put right, both when the queue has a song after it and when it doesn't. All of them failed before the fix.
3. **P2, xHE-AAC left the AAC filter.** The last pass named xHE-AAC separately so Sonos would get it as FLAC. As a side effect the library filed those songs under "Other lossy" instead of AAC, and the tag editor's footer said "tags" instead of "MP4 atoms", even with Network Players off. Both now treat "xHE-AAC" as AAC (`FormatKind.of`, and `TagEditorView.tagFormat(codec:)`, which was pulled out of the footer so it can be tested). The codec name stays "xHE-AAC" for the players. Tests: `LibraryFilterTests.xheAACIsAAC` (a song's facts, a filter set to AAC, an album's facts read from the database) and the app test `TagEditorFormatTests`. Both failed before the fix. For the app test, the one-line fix was taken out and put back to see it fail.

Also: docs/output-routes.md describes items 1 and 2.

### Test figures, third pass

On this machine, 2026-11-23 from 07:45. The machine was busy with other work throughout: load averages of 15 to 18 on 8 cores before anything of mine started.

- **The new tests, before and after**: all four package tests failed before their fixes and passed after (`build/logs/r3/red-1-3.log`, `green-1-3.log`); the app test likewise (`red-app-tageditor.log`, `green-app-tageditor.log`).
- **UPnP and Sonos** (`VespertineUPnPTests`, debug): **164 passed**, 0 failed (162 before this pass, plus the 2 new tests; the "moves on" test runs 2 cases). Run once after the three fixes, and again after the follow-up commit 7dd60ab6 (`upnp.log`, `upnp-final.log`).
- **Library group, and the cache and stream suites fix 1 touches** (`VespertineLibraryTests`, `NetworkPlaybackCacheTests`, `RemoteReaderRegistryTests`, `RemoteEarlyStartTests`, `StagedHandoffTests`, debug): 274 + 38 passed, 0 failed (`library-cache.log`).
- **App tests** (`xcodebuild test`, Debug, macOS, `-derivedDataPath build/DD` as in the earlier passes): **passed**, 284 tests in 61 suites, 0 failed (`** TEST SUCCEEDED **`; 283 in 60 before, plus `TagEditorFormatTests`). Log: `build/logs/r3/app-tests.log`. They first ran at a1f8bc30, and again at bfab9b4b (the code as at 7dd60ab6, the last code change): 284 passed again (`app-tests-head.log`).
- **The new tests, repeated**: `StagedHandoffTests`, the two refused-clear tests, the earlier queue-edit and download tests, 5 runs in a row: all passed each time (`repeat-5.log`).

**`scripts/audit.sh`, step by step** (evidence: `build/audit-20261123-080658-r3/`, exit codes in `steps.txt`). audit.sh stops at its first failure (`set -e`). Its first step, the whole package in debug mode, has failed timing tests on `main` and on this branch before (see the earlier passes), and would have stopped the script before the steps asked for. So its later steps were run one by one with its own commands (`build/r3-audit-steps.sh`), each one whether or not the one before passed. Two differences: the release-mode tests used a build folder of their own (`--scratch-path build/swiftpm-release`), warmed while the fixes were written, so their build took minutes instead of starting from nothing; and the Release app build was started once by hand first, for the same reason, while the release-mode tests were still compiling and in the first minutes of their run. Every step passed:

| Step (audit.sh's command) | Result |
|---|---|
| Release-mode package tests (`swift test -c release`) | **passed**, every group: engine 1484 tests in 235 suites (1483 before, plus `StagedHandoffTests`), UPnP and Sonos 164, library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four; 0 failed (6 min, build included). It compiled the renderer at 08:09:42, after its last change (08:07:20). |
| Analysis package tests (`VespertineAnalysis`) | passed, 72 tests in 8 suites |
| Real-time code under AddressSanitizer + UndefinedBehaviorSanitizer, and under ThreadSanitizer (`tests/rt-audit.c`) | built and ran clean, exit 0 both |
| Static analysis of the real-time code and of the DST decoder (`clang --analyze`) | 0 findings each |
| DST decoder on invalid frames under ASan + UBSan (`tests/dst-audit.c`) | clean: "1800 random frames, 1712 rejected; crafted frames handled" |
| XcodeGen | done |
| Release build, universal (`-configuration Release`, `generic/platform=macOS`, `ONLY_ACTIVE_ARCH=NO`) | `** BUILD SUCCEEDED **`, at the final code |
| `zsh -n` on the release scripts, `git diff --check` | clean |

audit.sh's own app-test step (Debug, `build/AuditDD`) is the app run above (in `build/DD`, as in the earlier passes).

**audit.sh's first step too, the whole package in debug mode** (`swift test`, run once at the end with nothing else of mine running, 08:18 to 08:31, 12 min 43 s; log `build/audit-20261123-080658-r3/debug-tests.log`). Every group passed except the engine group: UPnP and Sonos 164, library 274, AirPlay 2 211, and 151, 73, 37 and 31 in the other four. The engine group: 1484 tests, **5 failed** (8 issues), each after waiting 350 to 430 s:

- "Stop while the next song at another rate waits on its share" (`RateJoinStopTests`): failed on `main` and in both earlier passes.
- "Play pressed twice while the share is quiet…" (`ShareCloseTests`): failed on `main` and in the last pass ("the next song was copied" not reached).
- "With a scan in flight, the song's copy goes over the link…" (`NetworkPriorityTests`): failed on `main` and in the first pass ("the scan never got going").
- "The compressed frames macOS is handed are byte-identical…" (`BedMeterTests`): failed in the last pass.
- **The new handoff test, `StagedHandoffTests`.** Its own precondition failed: under the whole run's load, the engine took more than the test's 60 s to begin waiting on the shared copy. The check that matters passed in the same run: the player gave up and the Mac still played (before the fix, that check is what failed, with "The operation was cancelled."). The 60 s limits were mine, set tighter than the engine's other tests, which wait without a short deadline (`Patience` stops at 600 s). Commit 933cdbdd removes them. That change came after this whole run, so the whole run was not repeated with it.

Run alone right after: the handoff test with the change, 3 times, passed each time (`handoff-after-patience.log`); the four other failing suites, 26 tests, all passed (`engine-failing-alone.log`). None of those four tests, nor the code they exercise (share copies, rate changes, a scan's turn on the link, compressed pass-through to a device), was changed by this pass. The release-mode run of the same package, an hour earlier on a less loaded machine, passed all 1484.

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
