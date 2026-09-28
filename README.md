# ManzanaVision

**English** · [Español](README.es.md) · [Português](README.pt-BR.md) · [日本語](README.ja.md)

A userspace ISDB-T driver and channel scanner for the **DiBcom STK8096GP** USB tuner on macOS, built on libusb. No kernel extension, no DriverKit, no `sudo`.

macOS doesn't claim this device (USB `10b8:1fa0`), so a regular program can open it and do everything the Linux `dvb-usb-dib0700` driver does: upload the bridge firmware, bring up the demodulator and tuner, lock onto a channel, and stream the MPEG transport stream.

## What it does

- Scans UHF channels 14–51 and reports every multiplex that locks, with:
  - signal strength and SNR
  - TMCC parameters (mode, guard interval, and each layer's modulation, code rate and segments), plus which layers are actually decoding
  - the services on the mux, with names and virtual channel numbers (for example 9.1, 9.2 and 9.31), read from PAT/SDT/NIT
- Tunes a single channel and saves the raw TS to a file you can play in VLC or ffplay.

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

Channel numbering follows the ABNT/SBTVD plan used in Brazil, Chile and the rest of Latin America: channel *n* is centred on 473 + 6·(n−14) + 1/7 MHz.

## Requirements

- macOS on Apple silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`)
- libusb and pkg-config: `brew install libusb pkg-config`
- A DiBcom STK8096GP (`10b8:1fa0`) and a UHF antenna

## Build

```sh
make
```

The DiB0700 bridge firmware (`firmware/dvb-usb-dib0700-1.20.fw`, from linux-firmware) is included. DiBcom allows it to be redistributed under the terms in [`firmware/LICENSE.dib0700`](firmware/LICENSE.dib0700). Set `MANZANA_FIRMWARE` to use a different copy.

## Usage

```sh
./manzanavision probe                  # upload firmware, identify the chips
./manzanavision scan                   # scan UHF 14–51 and save the channel list
./manzanavision channels               # show saved channels
./manzanavision watch 9.1 | ffplay -   # watch a channel (also: watch 9, watch "MEGA HD")
./manzanavision scan --from 20 --to 40 --json
./manzanavision tune 27                # tune one channel and list its services
./manzanavision tune 27 --dump rf27.ts --seconds 30
./manzanavision signal 23 --beep     # live signal meter for aiming the antenna
```

`signal` redraws SNR, level, per-layer lock and uncorrectable packets per second four times a second, and re-tunes if the lock drops. With `--beep` it plays a finder tone like a satellite receiver's: the pitch rises with SNR, steady when every layer is locked, pulsing when only some are, and silent with no lock. You can aim the antenna by ear.

`scan` merges what it finds into `~/Library/Application Support/ManzanaVision/channels.tsv` (override with `MANZANA_CHANNELS`), a plain tab-separated file you can read or edit. A mux that doesn't lock on a later scan keeps its saved channels. `watch` tunes a saved channel and writes just that program as MPEG-TS, with a PAT listing only that service, its PMT and its streams, so ffplay, mpv or VLC (`| /Applications/VLC.app/Contents/MacOS/VLC -`) open it without any flags. Use `--output FILE` to record instead. If the signal drops for 2 seconds, `watch` re-tunes on its own and resumes, and the player just sees a short gap. It stops when the player exits or on Ctrl-C.

`-v` turns on the drivers' debug log and `-vv` adds an I²C trace. Put them before the command, for example `./manzanavision -v tune 27`.

To watch a capture, tell VLC to treat the stream as DVB so the service names decode correctly:

```sh
/Applications/VLC.app/Contents/MacOS/VLC --ts-standard=dvb rf27.ts
```

VLC otherwise assumes Japanese ARIB text, and Latin American service names come out as kanji.

## How it works

```
src/bridge/     DiB0700 USB bridge on libusb: firmware, GPIO, clock, I²C, TS streaming
src/frontends/  DiB8000 demod + DiB0090 tuner, vendored unmodified from Linux
src/compat/     the small kernel-API shim those drivers build against
src/board/      STK8096GP board glue, copied from Linux dib0700_devices.c
src/ts/         PAT/SDT/NIT parsing and ISDB-T virtual channel numbers
src/scan.c      tune → read TMCC → collect PSI → report
```

The demod and tuner drivers are about 7,000 lines of timing-sensitive state machines, so they are compiled **unmodified** from the Linux tree rather than rewritten. `src/frontends/PATCHES.md` records any local change (there are none so far), so the files can be kept in sync with upstream.

Notes from bringing it up on real hardware:

- The bridge firmware lives in RAM. The stick powers up "cold" and needs the firmware uploaded after every replug. `probe`, `scan` and `tune` all do this automatically.
- Linux drives this board with the bridge's legacy I²C requests (`0x02`/`0x03`). The newer requests (`0x12`/`0x13`) stall as soon as the DiB8000 switches to its PLL clock.
- If a mux locks but shows `B: … NO LOCK`, the signal is too weak for the 64QAM full-seg layer while the one-seg layer still decodes. That's an antenna problem, not a driver one.

## Status

The MVP works: on the author's stick the scanner locks and lists services on every mux that has usable signal, and TS captures are lossless (17.3 Mbit/s, no continuity errors). Live viewing works by piping `watch` into a player. Next steps could include an EPG, serving channels on the network as an HDHomeRun-compatible tuner, and a Mac app.

## License

GPL-2.0-only, the same as the Linux drivers it is built from. See [LICENSE](LICENSE).
