# ManzanaVision

**English** · [Español](README.es.md) · [Português](README.pt-BR.md)

A Mac app for watching free-to-air **ISDB-T** digital TV with a **DiBcom STK8096GP** USB tuner. It drives the stick itself from user space with libusb: no kernel extension, no DriverKit, no `sudo`, and nothing else to install.

macOS doesn't claim this device (USB `10b8:1fa0`), so a regular program can open it and do everything the Linux `dvb-usb-dib0700` driver does: upload the bridge firmware, bring up the demodulator and tuner, lock onto a channel and stream the MPEG transport stream. ManzanaVision does that, then decodes and plays the picture and sound natively.

## Download

Get the DMG from [Releases](https://github.com/kddlb/ManzanaVision/releases), open it and drag ManzanaVision to Applications. The app is signed with a Developer ID and notarised by Apple.

- A Mac with Apple silicon, running macOS 27 or later
- A DiBcom STK8096GP (`10b8:1fa0`) and a UHF antenna

The tuner firmware and libusb are built into the app.

## Using the app

- **Scan** (toolbar button) tunes UHF channels 14–51, or any range, and lists what it finds on each frequency. Channels are grouped by broadcaster in the sidebar. One-seg (mobile) services are hidden unless you turn them on in Settings.
- **Changing channels:** click one, press ⌘↑/⌘↓ or Page Up/Down, or type its number (`9.1`, or just `9`) and press Return. The app remembers the last channel.
- **Picture:** 1080i, 1080p and 720p, deinterlaced with YADIF at 60 fps (other modes in Settings), plus one-seg and radio services.
- **Signal info** (⌘I) shows SNR, level, each layer's lock and modulation, errors, the video and audio formats, buffer levels and recovery counters.
- **Problems are explained on screen:** tuner not plugged in, in use by another program, no signal, weak or poor reception. After a dropout the picture blurs while the app re-tunes by itself, and it picks up again when the stick is plugged back in.
- **Full screen** shows nothing but the picture: double-click it, press Esc to leave. **Picture in Picture** is in the Channel menu (⌃⌘P).
- The app is in English, Spanish and Brazilian Portuguese.

Channel numbering follows the ABNT/SBTVD plan used in Brazil, Chile and the rest of Latin America: channel *n* is centred on 473 + 6·(n−14) + 1/7 MHz.

## Command-line tool

`manzanavision` does the same from a terminal, and shares the channel list with the app (`~/Library/Application Support/ManzanaVision/channels.tsv`, override with `MANZANA_CHANNELS`).

```
$ ./manzanavision scan
RF 27  551.143 MHz  LOCK  strength  61%  SNR 20.5 dB
       mode 3  GI 1/8  | A:  1 seg QPSK 2/3 I=4 ok | B: 12 seg 64QAM 3/4 I=2 ok
       TSID 0x0930  ONID 0x0930  network "MEGAMEDIA"  ts "MEGAMEDIA"
        9.1   MEGA HD                  TV    sid 0x2600  pmt 0x0064
        9.2   MEGA 2 HD                TV    sid 0x2601  pmt 0x00c8
        9.31  MEGA MOVIL               1seg  sid 0x2618  pmt 0x1fc8
...
4 muxes locked
```

```sh
./manzanavision probe                  # upload firmware, identify the chips
./manzanavision scan                   # scan UHF 14–51 and save the channel list
./manzanavision channels               # show saved channels
./manzanavision watch 9.1 | ffplay -   # watch a channel (also: watch 9, watch "MEGA HD")
./manzanavision scan --from 20 --to 40 --json
./manzanavision tune 27                # tune one channel and list its services
./manzanavision tune 27 --dump rf27.ts --seconds 30
./manzanavision signal 23 --beep       # live signal meter for aiming the antenna
```

- **`scan`** reports each multiplex that locks: signal strength and SNR, TMCC parameters (mode, guard interval, and each layer's modulation, code rate and segments) and which layers are decoding, and the services with their names and virtual channel numbers from PAT/SDT/NIT. It merges them into the channel list; a mux that doesn't lock on a later scan keeps its saved channels.
- **`signal`** redraws SNR, level, per-layer lock and uncorrectable packets per second four times a second. With `--beep` it plays a finder tone like a satellite receiver's: the pitch rises with SNR, steady when every layer is locked, pulsing when only some are, and silent with no lock. You can aim the antenna by ear.
- **`watch`** writes one program as MPEG-TS, with a PAT listing only that service, so ffplay, mpv or VLC (`| /Applications/VLC.app/Contents/MacOS/VLC -`) open it without any flags. Use `--output FILE` to record instead. If the signal drops for 2 seconds it re-tunes and resumes.
- `-v` turns on the drivers' debug log and `-vv` adds an I²C trace. Put them before the command, for example `./manzanavision -v tune 27`.

To watch a raw capture in VLC, add `--ts-standard=dvb`. VLC otherwise assumes Japanese ARIB text, and Latin American service names come out as kanji.

## Building

The firmware (`firmware/dvb-usb-dib0700-1.20.fw`, from linux-firmware) is included; DiBcom allows it to be redistributed under the terms in [`firmware/LICENSE.dib0700`](firmware/LICENSE.dib0700). Set `MANZANA_FIRMWARE` to use a different copy.

- **App:** open `App/ManzanaVision/ManzanaVision.xcodeproj` in Xcode 27 and run. Set `MANZANA_RECORDINGS` to a folder of `rfNN….ts` captures to use them in place of the tuner.
- **Libraries and dev tool:** `swift build` and `swift test` (Swift package at the root, with libusb built from `vendor/libusb`).
- **Command-line tool:** `make`, which needs `brew install libusb pkg-config`.
- **Release:** `scripts/release.sh` archives, signs, notarises and staples the app and the DMG.

## How it works

```
src/bridge/          DiB0700 USB bridge on libusb: firmware, GPIO, clock, I²C, TS streaming
src/frontends/       DiB8000 demod + DiB0090 tuner, vendored unmodified from Linux
src/compat/          the small kernel-API shim those drivers build against
src/board/           STK8096GP board glue, copied from Linux dib0700_devices.c
src/ts/              PAT/SDT/NIT parsing and ISDB-T virtual channel numbers
src/core/            the C API (manzana.h): tune, scan, stream, program filter, channel list
src/cli/             the manzanavision command
Sources/ManzanaTuner     Swift actor around the C core, hot-plug, firmware and channel stores
Sources/ManzanaStream    TS demux, H.264 and AAC (ADTS, LATM) parsing
Sources/ManzanaPlayback  VideoToolbox decoding, Metal deinterlacing, audio, A/V sync
Sources/ManzanaTV        the live session: status, reception, re-tuning, scanning
App/                     the SwiftUI app
```

The demod and tuner drivers are about 7,000 lines of timing-sensitive state machines, so they are compiled **unmodified** from the Linux tree rather than rewritten. `src/frontends/PATCHES.md` records any local change (there are none so far), so the files can be kept in sync with upstream.

Notes from bringing it up on real hardware:

- The bridge firmware lives in RAM. The stick powers up "cold" and needs the firmware uploaded after every replug; the app and the CLI do this automatically.
- Linux drives this board with the bridge's legacy I²C requests (`0x02`/`0x03`). The newer requests (`0x12`/`0x13`) stall as soon as the DiB8000 switches to its PLL clock.
- If a mux locks but shows `B: … NO LOCK`, the signal is too weak for the 64QAM full-seg layer while the one-seg layer still decodes. That's an antenna problem, not a driver one.
- Broadcasters here send 1080i as field pictures (PAFF) or MBAFF, and HE-AAC in LATM or AAC in ADTS (one labels ADTS as LATM). Playback pairs fields itself and deinterlaces on the GPU, because VideoToolbox's own deinterlacer only gives 30 fps.

## License

GPL-2.0-only, the same as the Linux drivers it is built from. See [LICENSE](LICENSE). libusb is LGPL-2.1; the firmware has its own licence (above).
