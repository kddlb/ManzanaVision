# ManzanaVision

[English](README.md) · **Español** · [Português](README.pt-BR.md) · [日本語](README.ja.md)

Driver ISDB-T en espacio de usuario y escáner de canales para el sintonizador USB **DiBcom STK8096GP** en macOS, construido sobre libusb. Sin extensiones de kernel, sin DriverKit y sin `sudo`.

macOS no toma control de este dispositivo (USB `10b8:1fa0`), así que un programa común puede abrirlo y hacer todo lo que hace el driver `dvb-usb-dib0700` de Linux: cargar el firmware del puente, inicializar el demodulador y el sintonizador, enganchar un canal y recibir el transport stream MPEG.

## Qué hace

- Escanea los canales UHF 14 a 51 y reporta cada múltiplex que engancha, con:
  - intensidad de señal y SNR
  - parámetros TMCC (modo, intervalo de guarda y, por capa, modulación, tasa de código y segmentos), además de qué capas se están decodificando
  - los servicios del múltiplex, con nombre y número de canal virtual (por ejemplo 9.1, 9.2 y 9.31), leídos de PAT/SDT/NIT
- Sintoniza un canal y guarda el TS en un archivo que se puede ver con VLC o ffplay.

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

La numeración de canales sigue el plan ABNT/SBTVD que se usa en Chile, Brasil y el resto de Latinoamérica: el canal *n* está centrado en 473 + 6·(n−14) + 1/7 MHz.

## Requisitos

- macOS en Apple silicon o Intel
- Command Line Tools de Xcode (`xcode-select --install`)
- libusb y pkg-config: `brew install libusb pkg-config`
- Un DiBcom STK8096GP (`10b8:1fa0`) y una antena UHF

## Compilación

```sh
make
scripts/fetch-firmware.sh   # descarga dvb-usb-dib0700-1.20.fw desde linux-firmware
```

El firmware no viene en el repositorio. El script lo descarga desde linux-firmware y verifica su SHA-1. También puedes apuntar `MANZANA_FIRMWARE` a una copia que ya tengas.

## Uso

```sh
./manzanavision probe                  # carga el firmware e identifica los chips
./manzanavision scan                   # escanea UHF 14–51
./manzanavision scan --from 20 --to 40 --json
./manzanavision tune 27                # sintoniza un canal y lista sus servicios
./manzanavision tune 27 --dump rf27.ts --seconds 30
./manzanavision signal 23 --beep     # medidor de señal en vivo para orientar la antena
```

`signal` actualiza cuatro veces por segundo el SNR, el nivel, el enganche de cada capa y los paquetes con errores incorregibles por segundo, y vuelve a sintonizar si se pierde el enganche. Con `--beep` emite un tono como el de los decodificadores satelitales: el tono sube con el SNR, es continuo cuando todas las capas enganchan, intermitente cuando solo algunas lo hacen y se calla si no hay enganche. Así puedes orientar la antena de oído.

`-v` activa el log de depuración de los drivers y `-vv` agrega una traza de I²C. Van antes del comando, por ejemplo `./manzanavision -v tune 27`.

Para ver una captura, dile a VLC que trate el stream como DVB para que los nombres de los servicios se vean bien:

```sh
/Applications/VLC.app/Contents/MacOS/VLC --ts-standard=dvb rf27.ts
```

Si no, VLC asume texto japonés ARIB y los nombres latinoamericanos aparecen como kanji.

## Cómo funciona

```
src/bridge/     puente USB DiB0700 sobre libusb: firmware, GPIO, reloj, I²C, streaming del TS
src/frontends/  demodulador DiB8000 + sintonizador DiB0090, copiados sin cambios de Linux
src/compat/     la pequeña capa de compatibilidad con la API del kernel que esos drivers necesitan
src/board/      código de la placa STK8096GP, copiado de dib0700_devices.c de Linux
src/ts/         lectura de PAT/SDT/NIT y números de canal virtual ISDB-T
src/scan.c      sintonizar → leer TMCC → recolectar PSI → reportar
```

Los drivers del demodulador y del sintonizador son unas 7.000 líneas de máquinas de estado sensibles a los tiempos, así que se compilan **sin modificar** desde el árbol de Linux en vez de reescribirlos. `src/frontends/PATCHES.md` registra cualquier cambio local (por ahora ninguno), para poder mantener los archivos sincronizados con upstream.

Notas de la puesta en marcha con el hardware real:

- El firmware del puente vive en RAM. El dispositivo parte "en frío" y hay que cargarle el firmware cada vez que se enchufa. `probe`, `scan` y `tune` lo hacen solos.
- Linux maneja esta placa con los comandos I²C antiguos del puente (`0x02`/`0x03`). Los nuevos (`0x12`/`0x13`) se traban en cuanto el DiB8000 pasa a su reloj PLL.
- Si un múltiplex engancha pero muestra `B: … NO LOCK`, la señal no alcanza para la capa full-seg en 64QAM, aunque la capa one-seg sí se decodifica. Es un problema de antena, no del driver.

## Estado

El MVP funciona: en el dispositivo del autor el escáner engancha y lista los servicios de cada múltiplex con señal utilizable, y las capturas de TS salen sin pérdidas (17,3 Mbit/s, sin errores de continuidad). Los siguientes pasos podrían ser reproducción en vivo, EPG y una app para Mac.

## Licencia

GPL-2.0-only, igual que los drivers de Linux en los que se basa. Ver [LICENSE](LICENSE).
