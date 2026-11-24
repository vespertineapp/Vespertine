# Tested devices

What Vespertine has been run on, and what each test did and did not show. A **reported** result is one the developer observed in the app; it is not a measurement of the samples at the device unless the row says a capture was made. Reports for other hardware are welcome through the [device report form](https://github.com/vespertineapp/Vespertine/issues/new?template=dac_report.yml).

| Device | Connection | What was tested | Result | Status |
|---|---|---|---|---|
| FiiO K11 | USB | PCM at every rate to 384 kHz, DSD to DSD128 over DoP, 32-bit integer mode. **DoP by carrier rate on 2026-11-18** (DSD test tones from the Mac, `vespertine-probe doptest`, one pass, heard by a microphone at its speakers) | BIT-PERFECT badge shown (app readback). DoP on 2026-11-18: the tones played at the 176.4 and 352.8 kHz carriers (DSD64, DSD128) and the DAC did not play them at 192 and 384 kHz (DSD at 3.072 and 6.144 MHz, the 48 kHz family; the recording of the 384 kHz run holds no tone and three bursts of noise about 10 dB under the tone's level), so DSD at those two rates is converted to PCM for it (`noDoPCarriers` in [`dop-dacs.json`](../Packages/VespertineKit/Sources/VespertineAudio/Resources/dop-dacs.json)). In the same pass the owner heard loud static. Which run it was in is not established: the recording of the 352.8 kHz run has a voice over it and the tone under the voice is clean (though 9 dB quieter after a pause long enough to let the DAC go and a resume, cause not known), and the noise that is on record is in the 384 kHz run, which is no longer sent as DoP. The pass has not been repeated | Reported |
| FiiO KA15 | USB (2972:0104, no USB serial number) | DSD to DSD256 over DoP end to end: Vespertine's one-tap DoP test passed (music heard, not hiss) and DSD then played natively over DoP, several times, plus DoP turned on by hand. Core Audio UID `AppleUSBAudioEngine:FIIO:FIIO KA15:<USB location>:2`: the third field is the USB location, so the UID changes with every port | DSD64 to DSD256 played natively over DoP (developer report, 2026-11-21). Its DoP choice used to be lost when it came back in another USB port; since 2026-11-21 a choice follows the DAC to any port, and it is on the [known-DoP list](../Packages/VespertineKit/Sources/VespertineAudio/Resources/dop-dacs.json) | Reported (developer), 2026-11-21 |
| Fosi Audio ZD3 | USB (XMOS XU316, 152a:889b) | **Output formats read from Core Audio on 2026-10-28:** PCM 44.1 kHz to 768 kHz at 24 and 32 bit, so the DoP carriers for DSD64, DSD128 and DSD256 (176.4, 352.8, 705.6 kHz) exist. Planning for those is unit-tested; DSD512 would need a 1411.2 kHz carrier and is converted to PCM | DSD played over DoP on 2026-10-28; the ZD3's display showed DSD (owner report, Vespertine 0.13.2). PCM playback tested up to 768 kHz and DSD up to DSD256, natively over DoP (owner report, 2026-10-28). DoP is on by default for it, see [DoPDefaults](../Packages/VespertineKit/Sources/VespertineAudio/DoPDefaults.swift). On 2026-11-18 DSD test tones from the Mac played at the 176.4, 192, 352.8 and 384 kHz carriers (`vespertine-probe doptest`, one pass, heard by a microphone at its speakers) | Tested (owner report), 2026-10-28 |
| iBasso DC07 Pro | USB-C | DSD64 (DSDIFF) with DoP switched on, Vespertine 1.0.1 on macOS 27.2.1 | Played as native DSD over DoP; with DoP off it was converted to PCM (user report, [#247](https://github.com/vespertineapp/Vespertine/issues/247)). DoP is on by default for it, see [`dop-dacs.json`](../Packages/VespertineKit/Sources/VespertineAudio/Resources/dop-dacs.json) | Reported (user), 2026-11-11 |
| AirPods Max | USB-C and Bluetooth | 48 kHz lossless over USB-C; AAC reported over Bluetooth | As documented in [FEATURES](FEATURES.md) | Tested |
| MacBook Pro speakers | Built in | Stereo playback | Plays | Tested |
| **Onkyo TX-NR717 (AV receiver)** | HDMI, exclusive (hog) mode, 5.1 speakers | **5.1 and 7.1 FLAC at 32, 44.1, 48, 88.2, 96, 176.4 and 192 kHz; 384 and 768 kHz files; 5.1 DSD64; gapless; volume in Vespertine; Spatialize stereo; Dolby Digital and DTS CD bitstream; a speaker group with the Mac's speakers** | **Every channel reached its own HDMI channel, BIT-PERFECT, checked with a capture of each channel and by ear; see below** | **Tested (capture and developer listening), 2026-11-23** |
| **Sony TV (HDMI)** | HDMI, exclusive (hog) mode | **Six-channel 5.1 FLAC, 7.1 FLAC folded to 5.1, and 5.1 DSD64 converted to PCM, and Dolby Atmos rendered by macOS (tentative)** | **Each of the six channels went to its matching speaker position; BIT-PERFECT shown** | **Reported, 2026-10-19** |

DACs known to decode DoP, with the source for each entry, are listed in [`dop-dacs.json`](../Packages/VespertineKit/Sources/VespertineAudio/Resources/dop-dacs.json); [DOP-AUTO-SETUP.md](DOP-AUTO-SETUP.md) explains the list, the one-tap DoP test for DACs that aren't on it, and how to add one.

## Onkyo TX-NR717 AV receiver over HDMI (first receiver)

**Setup.** MacBook Pro (Apple M5 Pro) on HDMI to an Onkyo TX-NR717 with 5.1 speakers (left, centre, right, two surrounds and a subwoofer). Exclusive (hog) mode on, volume in Vespertine off unless a row says otherwise. Test files were generated for the purpose: a different tone or a spoken speaker name on each channel.

**How it was checked.** A macOS process tap recorded exactly what Vespertine sent on each of the eight HDMI channels, and the channel each tone arrived on was identified. Separately, a voice was played straight onto each raw HDMI channel and the developer noted which speaker it came from: 1 front left, 2 front right, 3 subwoofer, 4 centre, 5 surround left, 6 surround right (7 and 8 are the surround back pair, which this setup doesn't have). That is the order macOS names (L R LFE C Ls Rs Lrs Rrs), so the capture shows which speaker each channel reached.

**What the receiver advertises.** Linear PCM up to 8 channels, 16, 20 and 24 bit, at 32, 44.1, 48, 88.2, 96, 176.4 and 192 kHz. The list of sample rates macOS shows also says 768 kHz, but there is no format at that rate; Vespertine does not use it.

| Test | Result |
|---|---|
| 5.1 FLAC, 32 to 192 kHz | The output switched to each rate; every channel on its own HDMI channel, the back pair silent; BIT-PERFECT |
| 7.1 FLAC, 48 kHz | Side pair on 5 and 6, back pair on 7 and 8; BIT-PERFECT |
| 5.1 at 384 kHz, stereo at 768 kHz | Converted to 192 kHz, badged RESAMPLED |
| 5.1 DSD64 (DSF) | Converted to 176.4 kHz PCM, every channel in place; the receiver does not take DoP |
| Three files played back to back | No discontinuity at either boundary |
| Volume in Vespertine at -10 dB | Every channel exactly 10 dB lower, badged DIGITAL GAIN |
| Spatialize stereo | Stereo upmixed to 5.1: left and right kept, centre and surrounds derived |
| Dolby Digital, DTS CD (DTS in WAV) | Sent to the receiver untouched as IEC 61937 |
| Speaker group: the receiver plus the MacBook Pro speakers | Played as one 10-channel group; rates put back afterwards |

**Things to know about receivers.**

- macOS reports an HDMI output's speakers for the channel count the link is at now. Before November 2026, a receiver left at 2 or 6 channels by another app read as a stereo or 5.1 setup and surround was folded down; Vespertine now always uses an 8-channel receiver's 8-channel layout.
- With the receiver's Audio TV Out, HDMI CEC or HDMI Through switched on, it sometimes renegotiated the HDMI link by itself and offered the Mac only 2 channels, and 8-channel audio was silent until it offered 8 again. With all three off it stayed at 8 channels.
- The receiver takes a second or two to lock onto a new stream, so the first moment of a song can be lost when the format changes.
- Speakers wired to the wrong terminals (surrounds on the surround back terminals) sound like a channel-mapping fault. The receiver's own level calibration test tone tells them apart.

**What this does not show.** One receiver, one Mac. The Speakers sheet, Fill the Room, Mac Sound Output, the equalizer and room correction were not exercised on it, and the measured timing between the receiver and another output in a group was not obtained.

## Sony TV over HDMI (first multichannel result)

**Setup.** MacBook Pro (Mac17,8, Apple M5 Pro, macOS 27.0), Vespertine 0.13.0, a 2018 Sony TV ("SONY TV  *00", manufacturer code SNY, product ID 0x7c04) on HDMI through a DisplayPort/HDMI connection. Exclusive (hog) mode on, volume in Vespertine at unity (0.0 dB).

**What the TV advertises** (read from its EDID, the data the TV sends the Mac):

- Linear PCM: up to 6 channels, 32, 44.1, 48, 88.2, 96, 176.4 and 192 kHz, 16, 20 and 24 bit.
- Dolby Digital and DTS: 6 channels, up to 48 kHz. Dolby Digital Plus: up to 8 channels, 44.1 and 48 kHz.
- Speaker allocation: front left/right, centre, LFE and rear left/right, so a 5.1 layout. It does not advertise 7.1.

Vespertine's output device panel showed the same facts: 6 channels, speakers L R LFE C Ls Rs, sample rates 32 to 192 kHz, bit depths 16 / 20 / 24 integer, DoP off.

**5.1 FLAC.** Elton John, "Goodbye Yellow Brick Road" (FLAC, 16-bit / 44.1 kHz, 5.1) played with the **BIT-PERFECT** badge. The signal path read: sample rate switched to match the source (44.1 kHz native), channels 5.1 discrete with every channel to its speaker, volume unity, device output 24-bit / 44.1 kHz integer over HDMI exclusive. A 24-bit / 88.2 kHz 5.1 FLAC (Fleetwood Mac, "Dreams") did the same at 88.2 kHz.

![Vespertine playing a 5.1 FLAC to a Sony TV over HDMI: BIT-PERFECT, exclusive, 5.1 discrete, six channels each on its matching speaker](screenshots/multichannel-sony-tv-hdmi-5-1.png)

**7.1 on a 5.1 device.** Billie Eilish, "bad guy" (24-bit / 44.1 kHz 7.1 FLAC) played with a **7.1 → 5.1** badge instead of BIT-PERFECT, because the TV has no 7.1 layout. The signal path showed a standard channel-layout downmix, "7.1 folded into 5.1 by speaker position". Vespertine did not claim bit-perfect for it, which is the intended behavior.

![A 7.1 FLAC folded into 5.1 for the Sony TV, badged 7.1 to 5.1, with the downmix named in the signal path](screenshots/multichannel-sony-tv-hdmi-7-1-to-5-1.png)

**5.1 DSD on a PCM-only HDMI device.** Elton John, "Rocket Man (I Think It's Going to Be a Long, Long Time) (5.1 mix)" (DSF, DSD64, 5.1) played as **DSD → PCM**, not bit-perfect, and the app said so: DSD decimated to 352.8 kHz / 32-bit float, then sample-rate conversion to 176.4 kHz, delivered as 24-bit integer to the TV with every channel on its matching speaker. The TV does not accept DoP over HDMI (its audio formats are PCM, Dolby Digital, DTS and Dolby Digital Plus), so a conversion is the only way to play DSD to it.

![5.1 DSD64 played to the Sony TV as DSD to PCM, with the decimation and sample-rate conversion named in the signal path and a six-channel readout](screenshots/multichannel-sony-tv-hdmi-dsd-to-pcm.png)

**Dolby Atmos (tentative).** Elton John, "I'm Still Standing" (Dolby Digital Plus with Atmos, 5.1 bed) played with the badge **OBJECTS RENDERED BY MACOS**: the signal path shows macOS rendering the Atmos objects to the TV's own speaker layout, with the frames going to macOS untouched and Vespertine's spectrum and channel meters not applying (the Visualizer, which draws the decoded Dolby bed, came later). The developer's note is that Atmos "also works, I think", so treat it as playing and unconfirmed by listening notes. It was **not** sent as a bitstream to the TV; Atmos bitstream to this device is not supported or tested.

![Dolby Atmos played to the Sony TV with objects rendered by macOS, the output's own speaker layout, and frames passed to macOS untouched](screenshots/multichannel-sony-tv-hdmi-atmos-macos-rendered.png)

**What this does not show.**

- No loopback or HDMI capture is recorded for this test, so it is the developer's report and the app's own signal-path readout, not a measurement of the samples at the TV. What the TV does after HDMI (speakers, processing, room correction) is outside Vespertine.
- A TV is a multichannel HDMI sink, not a multichannel USB DAC or an AV receiver. Multichannel USB DACs and receiver bitstream (Dolby Digital, DTS, Dolby Atmos in Dolby Digital Plus) remain untested on real hardware.
- One TV, one Mac, one macOS version.
