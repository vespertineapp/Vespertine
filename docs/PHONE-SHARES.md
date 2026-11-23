# Playing from an SMB share on the iPhone or iPad

The phone can play a music folder on a NAS (or any computer's shared folder) by itself: no Mac running, no Vespertine anywhere but on
the phone. Away from home the same share is reached over Tailscale or another VPN, by the address typed for it.

## Using it

First screen › **Add an SMB Share**. Type the share as `smb://server/share/folder` (also accepted: `//server/share`, `\\server\share`,
`server/share`, with an optional `user@` and `:port`), the account and the password. For a share that lets guests in, leave the account
and password empty. The app signs in once before it keeps the share, so a wrong address or password is said in the form. The share then appears under **Your Shares** next to the paired Macs.
To choose from a server's shares instead of typing one, type only the server (`smb://nas.local`) and press Add: the app signs in and
lists the server's disk shares under **Choose a Share** (printers, `IPC$` and hidden shares ending in `$` are left out). A server that
won't list its shares is said so, with how to type the share instead.

Opening a share scans it: the app walks the folders, reads each song's tags (a few kilobytes per file, never the whole file) and keeps
the list on the phone. Each song is one round trip to the server: the app opens the file, reads its first 64 KiB and closes it in a
single compound request, and stops reading a FLAC once it has the tags and the front cover. Each folder is one round trip too (open,
list, list again to see that was all, close). Songs are read over six connections at once while a seventh lists the folders. Before
this, a song took about five round trips one after another, and an iPhone's Wi-Fi, which naps between answers, made that about a second. The first scan of a large library
still takes a while; what has been found so far is kept every few seconds and can be browsed and played while it runs, and a scan cut
short (the app closed, the line dropped) carries on from where it stopped. When the app leaves the screen mid-scan, the scan keeps
going for as long as iOS lets the app run, and the app asks iOS for background time to carry on later (iOS picks when, mostly with the
phone idle and charging). Later scans read only
new and changed files. A scan runs by itself when a share is opened and its list is more than a day old, and from Output › **Scan
Again**.

A share is browsed and played with the same screens and the same player as a Mac's library when "This iPhone" is the output: the song's
own file is read from the share in pieces and decoded on the phone, so lossless and hi-res files reach the output as they are, with the
same read-back of what iOS does to them. Keeping albums on the device goes through the same code as with a Mac (see "Keeping music on
the device" below).

For the address, use a name or address that works where the phone is: the NAS's Tailscale name (`nas.tail1a2b3.ts.net`) or its
100.x address works at home and away as long as Tailscale is connected on the phone; a `.local` name or a 192.168 address works only at
home. Now Playing says **SMB share** as the source, and Output shows the share, whether it answers, and the network its address is on.

## What it opens, and what it doesn't

| | |
|---|---|
| Played from a share | FLAC, ALAC and AAC (`.m4a`, `.mp4`, `.m4b`), WAV (also RF64), AIFF, MP3, stereo or mono DSD (`.dsf`, `.dff`), and in stereo or mono: APE, WavPack (`.wv`), Ogg Vorbis (`.ogg`, `.oga`) and Opus (`.opus`, `.ogg`) |
| Counted as "Files that need the Mac", not listed | DSD in surround or packed with DST, WavPack holding DSD, APE, WavPack, Vorbis and Opus in surround, FLAC or Speex in Ogg, TTA, WMA, DTS, TrueHD/MLP, AC-3/E-AC-3, MKA, ISO, TAK |
| Covers | `cover`, `folder`, `front`, `album` or `albumart` `.jpg`/`.jpeg`/`.png` in the album's folder, else the picture inside a file (not read from inside APE, WavPack, Ogg and Opus files) |
| ReplayGain | Read from the file's own tags when Output › ReplayGain is on: Vorbis comments in FLAC, `TXXX` frames in ID3 (MP3, WAV, AIFF), named iTunes items or QuickTime keys in MPEG-4. Not read from APE, WavPack, Ogg or Opus files. Read again from the file each time a song is played, so an index made by an earlier version needs no rescan |
| Not there | Playlists (they are the Mac's), CUE sheets |

MP3 and AAC albums on a share join without a gap, like the lossless ones: the phone's decoder reads the encoder's delay and padding
from each file and leaves them out (see `docs/REMOTE-STREAMING.md`).

Tapping "Files that need the Mac" lists them by what they are, each with its number of files: DSD in surround, DSD (DST), DTS, Dolby TrueHD and MLP, Dolby Digital, TTA, TAK, WMA, Matroska (MKA), disc images (ISO), surround in other formats, and other formats. The screen says that Vespertine on a Mac opens them. A share scanned before this version shows the count alone until its next scan.

Folders a NAS keeps for itself (`@eaDir`, `#recycle`, `$RECYCLE.BIN`, `System Volume Information`, `lost+found`, snapshots), hidden files
and names starting with a dot are skipped. Songs without tags are filed by their folder and file name.

## DSD from a share

The phone reads a DSF or DSDIFF file's audio itself (`DSDFile.swift`, `DSDRendering.swift`) and plays it one of two ways:

- **As DoP** to a USB DAC that passed "Play DSD natively?" on this phone, with the volume at 100%: the DSD bits go out unchanged
  inside 24-bit PCM at one sixteenth of the DSD rate (176.4 kHz for DSD64). Now Playing says **NATIVE DSD · DoP**. The rules are the
  ones for DSD from a Mac: an untested DAC, a DAC that stops below the carrier rate, or a volume below 100% gets PCM, never DoP.
- **As PCM** everywhere else (the speaker, AirPods, an untested DAC): the phone converts the DSD to 24-bit PCM at the highest rate
  of the song's family that the output takes, up to one eighth of the DSD rate (88.2, 176.4 or 352.8 kHz for DSD64). Now Playing
  says **CONVERTED ON THIS DEVICE**. The conversion is a linear-phase low-pass that keeps everything to 20 kHz (to 40 kHz at 176.4 kHz and
  above), with the 6 dB of gain usual for DSD, and peaks above full scale clipped.

Nothing is stored on the share or converted ahead of time: the phone reads the part of the file it needs as it plays or seeks. The
PCM is this app's own conversion, so it is not sample-for-sample what the Mac's converter makes of the same file. Surround DSD and
DST-packed DSDIFF (from an SACD) still need the Mac. A share scanned before this version lists its DSD files after its next scan
(by itself after a day, or **Scan Again**).

## APE, WavPack, Ogg Vorbis and Opus

iOS opens none of these, so the app brings a decoder for each (`Packages/VespertineDecoders`): the Monkey's Audio SDK, libwavpack,
libvorbisfile and opusfile. All four are BSD-3-Clause, and they are the same builds the Mac app decodes these files with, so a file
decodes to the same samples on the phone as on the Mac. The app carries no FFmpeg and nothing under the LGPL: the App Store exception
covers only Vespertine's own code, and a library that asks for relinking doesn't fit an App Store build. That is why TTA (LGPL), and
TAK, WMA, DTS and TrueHD (FFmpeg on the Mac) stay with the Mac. Their licenses are in the app under Settings › About › Licenses.

A file is decoded as it plays: the player is given PCM (whole numbers for APE and WavPack, 32-bit floats for Vorbis and Opus) and each
range it asks for is decoded from the frames it covers, so seeking works and nothing is converted ahead of time. Now Playing says
**ORIGINAL FILE**, as for a FLAC: the samples are the file's own. Reading in order, and any seek in APE, WavPack and Vorbis, gives
exactly the samples the Mac decodes. Opus carries what it has decoded from packet to packet, so a seek starts decoding a second early and
throws that second away: what plays is the same sound as reading in order, to within rounding.

Only stereo and mono play here. A share scanned before this version lists these files after its next scan (by itself after a day, or
**Scan Again**).

## The SMB client

`Packages/VespertineRemoteKit/Sources/VespertineShare` is a small read-only SMB client written for this app (Foundation and POSIX
sockets only; no third-party code), because the libraries that exist are under licenses that don't fit an App Store build.

- Dialects: SMB 2.0.2, 2.1, 3.0, 3.0.2 and 3.1.1; the server picks the newest it has. Not SMB 1, which is said in plain words when
  adding the share.
- SMB 3.1.1: the messages that agree the version and sign in are bound into the session's keys (pre-authentication integrity,
  SHA-512), and the server's signature on its last sign-in answer is checked with them. If anything in those messages was changed on
  the way, for example to strike out a version or a cipher, the sign-in fails instead of going on with less.
- Encryption: when the server asks for it for the whole session, or the share asks for it, every request after that is sent encrypted
  and every answer must arrive encrypted; an answer whose tag is wrong, or one that arrives in the clear, is refused. On SMB 3.1.1 the
  client offers AES-128-GCM, AES-128-CCM, AES-256-GCM and AES-256-CCM in that order (Windows' own), so a server that takes either size
  keeps the faster AES-128 and one set to take only AES-256 gets it; the AES-256 keys come from the whole session key with L = 256
  (MS-SMB2 3.2.5.3.1). SMB 3.0 and 3.0.2 have AES-128-CCM only. The client does not turn encryption on by itself for a server that
  doesn't ask.
- Sign-in: NTLMv2 inside SPNEGO, with the message integrity code and the mechanism-list signature. `user`, `DOMAIN\user` and
  `user@domain` are accepted. No Kerberos. Where the server offers NTLM's key exchange (Windows, Samba and a Mac all do), the client
  takes it: the session's key is 16 random bytes made on the phone and sent wrapped in the key the password gives. A Mac's File
  Sharing needs this: it checks the mechanism-list signature as it stands after a key exchange whether one was made or not, and
  refused the sign-in without one.
- Guests: with no account typed, the client signs in under the name `guest` with an empty password (what a NAS with its guest account
  on, a Mac, Windows, and Samba set to `map to guest = Bad User` take), and where that name is refused, with no name at all (which
  Samba takes for a share with `guest ok`). A guest session has no keys: nothing in it is signed or encrypted, so a server or share
  that requires either turns guests away. An account that was typed is never swapped for a guest's.
- Every request after sign-in is signed (HMAC-SHA-256 on SMB 2, AES-CMAC with the SP 800-108 derived key on SMB 3) unless it is
  encrypted, and every signed reply is verified; a reply whose signature is wrong is refused, and said.
- Reads: a read longer than one request is sent as several requests at once, as many as the server's credits allow (up to 16, a
  megabyte each at most, 64 KB on SMB 2.0.2), and the answers are matched to their requests by message ID, so they may come back in
  any order. A file read straight through (a song as it plays, a song being kept) is read ahead: the next pieces are asked for before
  they are wanted, starting at the size of the last read and doubling with each read in a row up to 8 MB, so a scan that reads a few
  kilobytes of tags is not made to fetch megabytes. A jump, closing the file or its end gives up what was read ahead. Read-ahead always
  leaves two credits for requests that aren't reads.
- It only ever opens folders for listing and files for reading. There is no code path that writes, renames or deletes a file. To list
  a server's shares it asks the server's share service (MS-SRVS NetrShareEnum over DCE/RPC on the `srvsvc` pipe of `IPC$`, with
  FSCTL_PIPE_TRANSCEIVE): a request and an answer on a pipe, allowed only on `IPC$` and only for `srvsvc`.
- The password is kept in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: this device only, not in iCloud Keychain
  or a backup restored elsewhere) and is used only to compute the NTLMv2 answer; it is never sent.
- A dropped connection (the phone changed networks, the server restarted) is made again and the request repeated once. A change of
  network lets go of the connections at once, so the next read goes over the new one instead of waiting out a dead line.

### How fast

Measured with `VESPERTINE_SMB_BENCH` against the Samba 4.19 test server (`scripts/samba-test`, in Docker under colima on the hub,
with netem adding a delay to everything the server sends), reading a 64 MiB file 32 MiB at a time (16 MiB at +150 ms), one run each,
23 November 2026. "Before" is one request at a time with no read-ahead, as the client was; the player reads 256 KB at a time.

| Added delay | Session | Player, before | Player, now | 1 MB reads, before | 1 MB reads, now |
|---|---|---|---|---|---|
| none | signed | 64 MB/s | 159 MB/s | 82 MB/s | 188 MB/s |
| 20 ms | signed | 8.6 MB/s | 38 MB/s | 26 MB/s | 28 MB/s |
| 50 ms | signed | 4.5 MB/s | 34 MB/s | 14 MB/s | 35 MB/s |
| 150 ms | signed | 1.5 MB/s | 7.5 MB/s | 4.5 MB/s | 8.1 MB/s |
| 50 ms | AES-128-GCM | 4.3 MB/s | 29 MB/s | 14 MB/s | 34 MB/s |
| 150 ms | AES-128-GCM | 1.5 MB/s | 8.1 MB/s | 4.4 MB/s | 7.7 MB/s |

For scale: 24/192 PCM needs about 1.2 MB/s, DSD256 about 2.8 MB/s. Before, the player's reads at a 150 ms round trip (a Tailscale
relay can be that slow) came to 1.5 MB/s, short of DSD256; now they come to 7.5 MB/s. The numbers at +150 ms are capped by the test
set-up (colima forwards the port over SSH, whose window limits a long link), not by the client. These are a Mac and a container, not
a phone on cellular: what a real phone gets over Tailscale is still to be measured (bench B9).

A share takes the place of a Mac behind the same interface (`ShareMac` is a `RemoteChannel`, as the demo is), so the library screens,
the queue, the player and kept albums are the ones a Mac's library uses. The index is `library.json` under Application Support, with
favorites beside it; covers are fetched when first shown and kept at the sizes asked for.

## Keeping music on the device

"Keep on This Device" on an album or playlist fetches its songs whole, one at a time, into Application Support (`Kept/<source>/`,
excluded from backups). With a share:

- **The original file.** Songs are kept as the file is, unless Settings › Keep Smaller Copies is on. A DSD song is kept as its own
  DSF or DSDIFF file, not PCM made for the output of the day: each time it plays, the phone makes DoP or PCM of it for whatever it is
  plugged into, exactly as it would from the share (`KeptDSD.swift`; the same bytes, checked in `DSDTests.swift`). With smaller copies
  it is kept as PCM at 44.1 or 48 kHz.
- **Carrying on.** A song cut off part way (the line went, the app was closed, iOS ended its time in the background) keeps what
  arrived, with a note beside it of which ranges those are and whose bytes they are (tag and size). The next try fetches only the
  rest; if the file changed on the server meanwhile, it starts again.
- **Checked whole.** A song counts as kept only once its size is what the share said and, for a FLAC file, its decoded samples match
  the MD5 its encoder wrote into it, so a byte changed anywhere in the audio is caught. A damaged song is fetched again from the start
  once; a second damaged copy is left out until the app next opens, and the page says so.
- **In the background**, through iOS's background tasks only (the app never plays silence to stay awake): on iOS 26 and later,
  choosing Keep on This Device starts a continued processing task, so fetching goes on after the app is left, with its progress shown
  by iOS, until it is done or iOS needs the time back. On any version, leaving the app with songs still to keep asks iOS for an
  overnight processing task on power and a network; iOS decides when it runs. A run that can't move for a minute (no connection, no
  room, cellular data off) gives its time back. The app's minimum stays iOS 17; the continued task is used where it exists.

Not yet seen on a device: how long iOS lets a continued task run, and how often the overnight task runs (bench B11 and the plan's
background test: a 20-album queue with the phone locked, counted after 30 minutes and after a night on a charger).

## How it is tested

- Digests, ciphers and keys against the published vectors (RFC 1320, 1321, 2202, 3610, 4231, 4493, FIPS 180 and 197, SP 800-38C, the
  GCM specification's test cases, RFC 6229), NTLMv2 against the example in MS-NLMP 4.2.4 with and without its key exchange, and the
  system's CryptoKit/CommonCrypto against the portable code where both exist.
- The sign-in against a Mac's side of it written out from Apple's published source (`MacSignInTests.swift`): the challenge a Mac
  builds and each check it makes on the answer, in its order. The sign-in without a key exchange is refused there, at the check that
  refused it on macOS 27; with one it is taken.
- SMB 3's own steps against the vectors Microsoft published from Windows talking to Windows (`SMBVectors.swift`): the running digest
  of the opening messages, the signing and encryption keys made from it, the signature on the last sign-in answer, and whole encrypted
  messages in AES-128-GCM and AES-128-CCM, for SMB 3.1.1 and SMB 3.0. AES-256 (no Microsoft vectors exist for it): the cipher
  against the GCM specification's 256-bit test cases and FIPS 197's AES-256 example, and the 256-bit key derivation against values
  worked out apart from the code with Python's `hmac`.
- The client against recorded conversations with Samba 4.19 (`SMBRecordings.swift`, recorded again on 23 November 2026 when the client
  began offering AES-256, with `scripts/samba-test`): SMB 2.0.2, 2.1, 3.0.2 and 3.1.1 signed; SMB 3.1.1 encrypted for the whole
  session (GCM) and for one share (CCM); a server taking only AES-256-GCM, and one taking only AES-256-CCM; SMB 3.0.2 encrypted; a
  guest let in by name and one let in with no name; and a listing of the server's shares, signed, encrypted, on SMB 3.0.2 and as a
  guest. The same bytes must be sent, and the recorded replies' signatures or tags must verify. Changed in the recording, each is
  refused: a signed answer, an encrypted answer, an answer in the clear where an encrypted one is due, and the server's first message
  of an SMB 3.1.1 connection.
- The tag reader against files made with FFmpeg and checked with ffprobe (`SongFixtures.swift`).
- DSD (`DSDTests.swift`): DSF and DSDIFF files made in the test from a 1-bit modulator. As DoP, the words must equal the DoP test
  clip's (`DoPProbeClip`) for the same DSD, whatever the file kind, bit order or the way the reads are cut up. As PCM, a tone must come
  out at its level (within 0.2%) at every rate, and DSD silence as digital silence. On a Mac, the player's own decoder must read
  the stream back to the same 24-bit words.
- The decoders (`PhoneDecodersTests.swift` in VespertineKit, which has the Mac's decoder to compare with): APE at 16 and 24 bits,
  WavPack, Ogg Vorbis and Opus fixtures must decode to exactly the samples SFBAudioEngine decodes on the Mac, read in pieces; a read
  from any frame must be the same samples as reading in order (Opus: the same sound); DSD in WavPack and 5.1 Opus must be left to the
  Mac; a share that stops answering must be said as that, not as a damaged file. `DecodedFormatsTests.swift` covers the scan and
  `ShareMac` with a made-up decoder, and the player's own decoder reading 16, 24 and 32-bit and float samples back exactly.
- The scan, the library and `ShareMac` on a made-up share in memory, including a share that stops answering mid-scan.
- Reading several requests at once and reading ahead (`SMBPipelineTests.swift`), against a made-up server whose answers take a set
  round trip and bandwidth on a clock of its own, so the timings are the same on any machine: requests in flight, never more than the
  credits granted, answers out of order, the end of the file in the middle, SMB 2.0.2, a jump while reading ahead, and a scan's small
  reads not being read far ahead.
- Kept songs (`KeptTests.swift`, `KeptCheckTests.swift`, `StreamDownloaderTests.swift`): carrying on after the line went and after
  the app was opened again, a changed file starting again, part files cleared when nothing wants them, FLAC files made by Core
  Audio's encoder checked against their MD5 (and caught with one byte changed), the original asked for unless smaller copies are on,
  and a kept DSD file asked to be made into what the output takes.
- Against a real server when one is named: `VESPERTINE_SMB="host:port/share/user/password" swift test --package-path
  Packages/VespertineRemoteKit --filter SMBLiveTests` (`host:port/share` alone signs in as a guest). The share needs a `Music` folder
  with a 3,000,000-byte `random.bin` in it, and `VESPERTINE_SMB_FILE` names a local copy of that file to compare a read with.
  `VESPERTINE_SMB_BIG` (a path on the share) and `VESPERTINE_SMB_BIG_FILE` (a local copy) add a large file read through and compared
  byte for byte. `VESPERTINE_SMB_EXPECT=311,encrypted` fails the run unless the server agreed to that version and to encryption
  (`guest` likewise). The run prints the version, and whether the session is encrypted or a guest's. `VESPERTINE_SMB_SHARES=archive,music`
  checks the server's share list. `VESPERTINE_SMB_BENCH=<file>` with `VESPERTINE_SMB_BIG` measures throughput (the table above).
  `scripts/samba-test/run.sh MODE` starts a Samba 4.19 server in Docker set up for any of the recorded cases. CI names none.

What has been run against a real server: Samba 4.19.9 in Docker on the hub (every recorded case, including AES-256-only servers and a
64 MiB file compared byte for byte). What has not been measured: a real NAS (Synology, QNAP, TrueNAS, a Mac's or Windows' file sharing), a real phone over Tailscale, and
keeping albums from a share on a phone. DSD from a share has not been heard on a phone or seen on a DAC's display (bench B8, step 13). APE, WavPack, Ogg Vorbis and
Opus have been decoded on a Mac only: not yet built into an app on a phone, or heard there.
Samba is what most NAS boxes run, but that is not the same as having tried them.
