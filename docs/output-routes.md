# Output routes: what each one can carry

What reaches the speakers depends on the route, not only on the file. This page says, for every kind of output Vespertine plays to from a Mac, the best the route can carry, what Vespertine sends, and what it tells you when a song has to change to fit. The output list shows the same per song: under each output, "Will play 24-bit / 48 kHz FLAC, stereo (source 24/192)", in copper whenever the samples that arrive are not the file's own.

The rule everywhere: nothing is taken away without saying so. A change shows in the output list before you choose the output, in the status badge while the song plays, and as a sentence in the signal path.

| Route | Best it carries | What Vespertine sends | Surround | Dolby Atmos |
|---|---|---|---|---|
| USB or Thunderbolt DAC | Whatever the DAC lists (PCM to 768 kHz, DSD as DoP) | The file's own samples at the file's own rate, bit-perfect | Every channel, on a multichannel DAC | No (plays the bed) |
| HDMI to an AV receiver | 8 channels of 24-bit / 192 kHz PCM; Dolby Digital (Plus) as a bitstream | PCM channel for channel, or the Dolby frames untouched | Yes, discrete | Yes, from Dolby Digital Plus files, two ways (below) |
| HDMI or eARC to a TV or sound bar | What the TV passes on, often less than it accepts | The same as a receiver | If the TV passes it | If the TV passes Dolby Digital Plus |
| Sonos room (network) | Stereo, 24-bit / 48 kHz, FLAC or Apple Lossless | The file itself within that; else 24-bit FLAC at 48 or 44.1 kHz | No: folded to stereo | No |
| Other network players (UPnP AV, OpenHome) | Whatever the player lists | The file itself | If the player plays the file | No |
| AirPlay (Vespertine's own sender) | Apple Lossless 16-bit / 44.1 kHz stereo; 24-bit / 48 kHz to an Apple TV 4K | The file's samples when they are in that format; else converted | No: folded to stereo | No |
| AirPods and Beats | AAC over Bluetooth; lossless 24-bit / 48 kHz on AirPods Max over USB-C | PCM to macOS | Rendered with Spatial Audio | Rendered by macOS |
| Other Bluetooth | AAC or SBC, always lossy | PCM to macOS | Folded to stereo | No |
| Built-in speakers and headphone jack | 24-bit, up to 96 kHz (the jack) | The file's samples, shared with other apps | Folded to stereo | Rendered by macOS on the speakers |

## USB and Thunderbolt DACs

Core Audio lets one app hold a device exclusively ("hog mode") and set its sample rate and physical format. Vespertine reads the file's true format, sets the DAC to the file's rate before each song (Sample rate: Match source, the default for every device), picks an integer physical format at least as deep as the file, and copies the samples through with no gain, mixer or resampler in the way. When the DAC lacks the rate, the song is resampled with Apple's mastering-quality converter to the nearest rate it has, and the badge changes from BIT-PERFECT to RESAMPLED. DSD goes out as DoP to a DAC marked as taking it, else as PCM. Two songs at the same rate join without a gap; a change of rate reconfigures the DAC, which is a short pause on any player.

- Exclusive access is a per-app setting (off by default so the Mac's other sounds keep working); shared mode is still bit-perfect while no other app is playing to the DAC.
- A multichannel DAC or interface gets each channel on its own output, unmixed.
- How to check it on your own hardware: [VERIFICATION.md](VERIFICATION.md). Design: [ARCHITECTURE.md](ARCHITECTURE.md).

## HDMI: receivers, TVs and sound bars

A Mac's HDMI output carries up to 8 channels of PCM, and macOS shows the receiver as a Core Audio device with the channel count and rates the receiver's EDID lists. Set the speaker layout once in Audio MIDI Setup (Configure Speakers).

- **Surround files** (5.1 or 7.1 FLAC, DTS-HD Master Audio and Dolby TrueHD decoded to PCM, multichannel SACD and DSD converted to PCM) go out channel for channel at the file's rate. A 7.1 file into a 5.1 room is folded by Vespertine, with the channels that have a speaker left untouched.
- **Dolby Digital and Dolby Digital Plus** files can instead be sent as the untouched bitstream (IEC 61937) for the receiver to decode: mark the output as a receiver in its settings. Dolby Digital Plus needs HDMI; optical carries Dolby Digital only.
- **Dolby Atmos.** Only Atmos in Dolby Digital Plus (the kind streaming services and `.ec3` / `.m4a` files hold) can arrive as Atmos, and there are two ways. As a bitstream to an Atmos receiver, the receiver decodes the objects itself. Or macOS renders it: Vespertine hands the frames to the system renderer, which is what Apple Music does. Apple documents HDMI passthrough of Dolby formats for its own apps from macOS Sequoia on.
- **What cannot work from a Mac:** Dolby TrueHD (Atmos included) and DTS-HD as bitstreams. macOS gives apps no high-bit-rate passthrough. Vespertine decodes them and plays the lossless channel bed; the height objects are not rendered.
- **A TV in the middle** often narrows the route. Many TVs accept multichannel PCM over HDMI and pass only stereo PCM or Dolby Digital on to a sound bar over optical or ARC; eARC passes multichannel PCM and Dolby Digital Plus. The Mac sees only the TV, so Vespertine can't tell what the sound bar gets.

Channel-for-channel output and receiver bitstream are tested by automated tests and on one TV, not yet on a range of receivers: see [DEVICES.md](DEVICES.md).

## Sonos

Sonos speakers are network players: Vespertine finds them by SSDP, serves the song over HTTP from this Mac, and tells the room to play it with UPnP AVTransport. It is behind Settings › Playback › Network Players (Sonos and UPnP, beta).

**What Sonos takes from a computer** (Sonos's own list for a music library): mono or stereo files, sample rates up to 48 kHz, FLAC and Apple Lossless up to 24-bit on S2 (16-bit on S1), WAV and AIFF 16-bit, MP3, AAC and Ogg Vorbis up to 320 kbit/s. No multichannel files, no DSD, nothing above 48 kHz.

**What Vespertine does** (`StreamNegotiation`, one table, tested row by row):

| The song | Sent as |
|---|---|
| FLAC or Apple Lossless, up to 24-bit / 48 kHz, mono or stereo | The file itself, byte for byte |
| WAV or AIFF, 16-bit, up to 48 kHz | The file itself |
| MP3, AAC, Ogg Vorbis | The file itself |
| 88.2, 176.4 or 352.8 kHz | 24-bit FLAC at 44.1 kHz |
| 96, 192 or 384 kHz | 24-bit FLAC at 48 kHz |
| DSD (DSF, DSDIFF, SACD image, WavPack DSD) | 24-bit FLAC at 44.1 kHz |
| 5.1, 7.1, Dolby Atmos, DTS, TrueHD | 24-bit FLAC, folded to stereo |
| 24-bit WAV or AIFF, APE, WavPack, TAK, Opus, a track of a CUE sheet | 24-bit FLAC with the same samples |

The rate is always the highest Sonos takes that divides the song's own exactly (192 → 48, 176.4 → 44.1), so the resampler never works at a fractional ratio. The resampler is Apple's mastering-quality converter at its highest setting, the one the rest of the app uses. The stream is written whole before the room is told about it (encoding runs many times faster than the music plays), so Sonos gets a file with a length it can seek in; a song that takes more than two minutes to prepare is offered as it is written instead. Converting runs many times faster than real time, but the first song of a hi-res album still starts some seconds late; the songs after it are prepared while the one before plays.

**Rooms, not speakers.** Every Sonos speaker answers a search, so Vespertine reads the system's own arrangement (ZoneGroupTopology) and lists what plays: one row per room, or per group of rooms playing together ("Living Room + Kitchen"). Surround speakers, a Sub and the second speaker of a stereo pair are parts of their room and are not listed. Commands go to the room that leads its group, which is the only one that takes them.

**A home theater room** (a sound bar with two surrounds and a Sub: "5.1" in the Sonos app) plays two-channel music on all of its speakers, and how the surrounds join in is Sonos's choice, not the player's: Sonos app › Settings › the room › Surround Audio › Music Playback, **Ambient** (quiet, limited range; the default) or **Full** (full range, as loud as the front). The surround level for music is on the same page. That setting doesn't apply to TV sound.

**No surround and no Atmos from a computer.** A Sonos home theater decodes Dolby Digital 5.1 (and, on Arc and Beam Gen 2, Dolby Digital Plus, Atmos, TrueHD and multichannel PCM) only from its TV input, and Atmos music only from streaming services inside the Sonos app. Sonos's music library support is stereo only, and listeners who have tried 5.1 FLAC files report "unsupported format". So a surround song is folded to stereo for Sonos, and the output list says so before you choose it.

**The Playbar in particular** (the original sound bar, optical input only): Stereo PCM and Dolby Digital 5.1 from the TV, DTS on S2; no Dolby Digital Plus and no Atmos, because optical can't carry them; no AirPlay 2 of its own. The network route above is the only lossless way into it from a Mac. The one way to hear discrete 5.1 on it is through the TV: a Dolby Digital 5.1 file sent as a bitstream over HDMI to a TV that passes Dolby Digital on to its optical output. That depends entirely on the TV and is untested.

**Volume.** The slider is the room's own volume (RenderingControl; GroupRenderingControl for several rooms), as in the Sonos app. It never changes the samples sent.

**Gapless.** Vespertine hands Sonos the next song while the current one plays (SetNextAVTransportURI). Whether Sonos then joins the two without a gap for songs played this way has not been checked on a real system; if it doesn't move on by itself, Vespertine starts the next song when the current one ends, which leaves a short gap.

## Other network players (UPnP AV and OpenHome)

A player gets the original file's bytes. Its own format list (ConnectionManager GetProtocolInfo) is shown, and a song beyond what it states is flagged. With Vespertine's equalizer, room correction, ReplayGain or volume on, it gets 24-bit FLAC made after that processing. What the player then does with the stream can't be read back, so the badge says what was sent. OpenHome players and UPnP AV players with SetNextAVTransportURI are gapless.

## AirPlay

Vespertine has its own AirPlay sender (Settings › Playback › AirPlay Players, beta). AirPlay audio is Apple Lossless: 16-bit / 44.1 kHz stereo to every receiver, and 24-bit / 48 kHz to receivers that say they take it (an Apple TV 4K). A CD-quality file arrives as its own samples; anything else is resampled, and reduced to 16 bits with dither where needed, and the path says which. AirPlay carries two channels from Vespertine: surround is folded to stereo, and there is no Atmos over it.

- An Apple TV 4K sends Atmos to a receiver as Dolby MAT, but only for what its own apps play; a Mac can't hand it Atmos over AirPlay audio.
- Choosing an AirPlay device as the Mac's own sound output (Control Center) also works: macOS then encodes and sends it, and Vespertine can't claim more than "sent to macOS".
- Sonos speakers with AirPlay 2 (One, Beam, Arc, Era, Move, Roam, Play:5 gen 2) can be reached this way too, at 16-bit / 44.1 kHz. The network route above is better: 24-bit, and the file itself. A Playbar has no AirPlay 2, and speakers bonded to it as surrounds can't be AirPlay targets.

## Bluetooth

Always lossy. macOS encodes whatever it is given as AAC, or SBC for headphones without AAC. Listeners report that Macs with Apple silicon no longer use aptX; Apple doesn't document it either way. Vespertine sends PCM at the rate macOS has chosen for the link and never marks Bluetooth BIT-PERFECT. While any app holds the headset's microphone open, macOS drops the link to phone quality (24 kHz mono or less), and the output chip says CALL MODE. AirPods and Beats get surround rendered with Spatial Audio, head tracked where macOS provides it. AirPods Max over USB-C are lossless at 24-bit / 48 kHz.

## Sources

- Sonos, "Supported audio formats for Sonos music library": https://support.sonos.com/en-us/article/supported-audio-formats-for-sonos-music-library
- Sonos, "Supported home theater audio formats": https://support.sonos.com/en-us/article/supported-home-theater-audio-formats
- Sonos, "Change surround audio settings" and "Low audio from surround speakers when listening to music": https://support.sonos.com/en-us/article/change-surround-audio-settings , https://support.sonos.com/en-us/article/low-audio-from-surround-speakers-when-listening-to-music
- Sonos Community, 5.1 FLAC from a local library refused: https://en.community.sonos.com/home-theater-228993/playing-local-multi-channel-audio-eg-lpcm-5-1-flac-files-6891817 ; Playbar and Dolby Digital Plus over optical: https://en.community.sonos.com/home-theater-228993/playbar-needs-to-support-dolby-digital-plus-6071515
- AirPlay 2 on Sonos (Playbar not included; grouping only): https://www.macrumors.com/2018/07/11/sonos-speakers-now-support-airplay-2
- Sonos UPnP services as documented by the community (AVTransport, ZoneGroupTopology, RenderingControl): https://sonos.svrooij.io/services/av-transport , https://sonos.svrooij.io/services/zone-group-topology
- Apple, Dolby Atmos in Music on Mac, including HDMI Passthrough: https://support.apple.com/guide/music/mus877f146ac/mac ; MacRumors on HDMI passthrough in macOS Sequoia: https://www.macrumors.com/2024/07/03/macos-sequoia-supports-hdmi-passthrough/
- Apple, "Play audio in Dolby Atmos or surround sound on your Apple TV 4K" (Dolby MAT): https://support.apple.com/102218
- AirPlay's 16-bit / 44.1 kHz ceiling as receiver makers describe it: https://www.cambridgeaudio.com/eur/fr/faqs/can-i-stream-lossless-audio-apple-music-my-network-player ; the format bits AirPlay 2 receivers announce are recorded in `AirPlayFormat.swift`
- Bluetooth codecs on Macs: https://www.macrumors.com/how-to/enable-aptx-aac-bluetooth-audio-codecs-macos , https://forums.macrumors.com/threads/bluetooth-aac-on-apple-silicon-macs.2382779/
- UPnP AV: AVTransport:1 and ConnectionManager:1 service templates, UPnP Device Architecture 1.1 (upnp.org / Open Connectivity Foundation)

Not verified by a source or on hardware, and said so above: whether Sonos joins two songs gaplessly when given the next one this way; Dolby Digital 5.1 through a TV's optical output to a Playbar; the built-in jack's rate ceiling on every Mac model (the device list in the app shows the real one).
