# ManzanaVision

[English](README.md) · **Español** · [Português](README.pt-BR.md)

Una app para Mac para ver televisión digital abierta **ISDB-T** con un sintonizador USB **DiBcom STK8096GP**. Maneja el dispositivo por sí misma desde el espacio de usuario con libusb: sin extensiones de kernel, sin DriverKit, sin `sudo` y sin nada más que instalar.

macOS no toma control de este dispositivo (USB `10b8:1fa0`), así que un programa común puede abrirlo y hacer todo lo que hace el driver `dvb-usb-dib0700` de Linux: cargar el firmware del puente, inicializar el demodulador y el sintonizador, enganchar un canal y recibir el transport stream MPEG. ManzanaVision hace eso y luego decodifica y reproduce la imagen y el sonido de forma nativa.

## Descarga

Descarga el DMG desde [Releases](https://github.com/kddlb/ManzanaVision/releases), ábrelo y arrastra ManzanaVision a Aplicaciones. La app está firmada con un Developer ID y notarizada por Apple.

- Un Mac con Apple silicon y macOS 27 o posterior
- Un DiBcom STK8096GP (`10b8:1fa0`) y una antena UHF

El firmware del sintonizador y libusb vienen incluidos en la app.

## Uso de la app

- **Buscar** (botón de la barra de herramientas) sintoniza los canales UHF 14 a 51, o el rango que quieras, y muestra lo que encuentra en cada frecuencia. En la barra lateral los canales se agrupan por emisora. Los servicios one-seg (móviles) quedan ocultos a menos que los actives en Ajustes.
- **Cambiar de canal:** haz clic en uno, usa ⌘↑/⌘↓ o Re Pág/Av Pág, o escribe su número (`9.1`, o solo `9`) y presiona Retorno. La app recuerda el último canal.
- **Imagen:** 1080i, 1080p y 720p, desentrelazada con YADIF a 60 fps (hay otros modos en Ajustes), además de servicios one-seg y de radio.
- **Información de señal** (⌘I) muestra SNR, nivel, el enganche y la modulación de cada capa, errores, los formatos de video y audio, los búferes y los contadores de recuperación.
- **Subtítulos ocultos** (⇧⌘C, o Canal → Subtítulos ocultos) muestran los subtítulos ARIB/ABNT del canal donde el canal los ubica y con sus colores. También aparecen en imagen dentro de imagen, y lo exportado para QuickTime los lleva como una pista de subtítulos que se puede activar. Vienen activados si en Accesibilidad → Subtítulos está elegido preferir subtítulos ocultos.
- **Los problemas se explican en pantalla:** sintonizador desconectado, en uso por otro programa, sin señal, recepción débil o mala. Tras un corte, la imagen se difumina mientras la app vuelve a sintonizar sola, y retoma la reproducción cuando se vuelve a conectar el sintonizador.
- **Pantalla completa** muestra solo la imagen: haz doble clic sobre ella y presiona Esc para salir. **Imagen dentro de imagen** está en el menú Canal (⌃⌘P).
- **Grabar** (⌘R, o Canal → Grabar durante) guarda el canal tal como se transmite, en MPEG-TS, en Películas/ManzanaVision; VLC, IINA y mpv lo reproducen. **Archivo → Exportar grabación para QuickTime** convierte una grabación en un MP4 (HEVC, desentrelazado a 60 fps, AAC) para QuickTime, Fotos o un iPhone.
- **Sin guía de programación (EPG).** No se puede desarrollar ni probar aquí, porque ninguno de los canales que se reciben en Antofagasta transmite una utilizable: Mega cifra su guía completa (H-EIT) y en la de one-seg (L-EIT) solo manda secciones de ahora/siguiente vacías y con sumas de verificación corruptas, y CNC no transmite datos de guía.
- La app está en inglés, español y portugués de Brasil.

La numeración de canales sigue el plan ABNT/SBTVD que se usa en Brasil, Chile y el resto de Latinoamérica: el canal *n* está centrado en 473 + 6·(n−14) + 1/7 MHz.

## Herramienta de línea de comandos

`manzanavision` hace lo mismo desde la terminal y comparte la lista de canales con la app (`~/Library/Application Support/ManzanaVision/channels.tsv`; se puede cambiar con `MANZANA_CHANNELS`).

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
./manzanavision probe                  # carga el firmware e identifica los chips
./manzanavision scan                   # escanea UHF 14–51 y guarda la lista de canales
./manzanavision channels               # muestra los canales guardados
./manzanavision watch 9.1 | ffplay -   # ve un canal (también: watch 9, watch "MEGA HD")
./manzanavision scan --from 20 --to 40 --json
./manzanavision tune 27                # sintoniza un canal y lista sus servicios
./manzanavision tune 27 --dump rf27.ts --seconds 30
./manzanavision signal 23 --beep       # medidor de señal en vivo para orientar la antena
```

- **`scan`** reporta cada múltiplex que engancha: intensidad de señal y SNR, los parámetros TMCC (modo, intervalo de guarda y, por capa, modulación, tasa de código y segmentos) y qué capas se están decodificando, y los servicios con sus nombres y números de canal virtual según PAT/SDT/NIT. Los agrega a la lista de canales; un múltiplex que no engancha en un escaneo posterior conserva sus canales guardados.
- **`signal`** actualiza SNR, nivel, el enganche de cada capa y los paquetes no corregibles por segundo cuatro veces por segundo. Con `--beep` emite un tono de búsqueda como el de los receptores satelitales: el tono sube con el SNR, es continuo cuando todas las capas están enganchadas, intermitente cuando solo algunas lo están y se calla sin enganche. Puedes orientar la antena de oído.
- **`watch`** entrega un solo programa como MPEG-TS, con una PAT que lista solo ese servicio, así que ffplay, mpv o VLC (`| /Applications/VLC.app/Contents/MacOS/VLC -`) lo abren sin opciones. Usa `--output ARCHIVO` para grabar. Si la señal se cae por 2 segundos, vuelve a sintonizar y continúa.
- `-v` activa el registro de depuración de los drivers y `-vv` agrega una traza de I²C. Van antes del comando, por ejemplo `./manzanavision -v tune 27`.

Para ver una captura en VLC, agrega `--ts-standard=dvb`. Si no, VLC asume texto ARIB japonés y los nombres de los servicios latinoamericanos aparecen como kanji.

## Compilación

El firmware (`firmware/dvb-usb-dib0700-1.20.fw`, de linux-firmware) viene incluido; DiBcom permite redistribuirlo bajo los términos de [`firmware/LICENSE.dib0700`](firmware/LICENSE.dib0700). Define `MANZANA_FIRMWARE` para usar otra copia.

- **App:** abre `App/ManzanaVision/ManzanaVision.xcodeproj` en Xcode 27 y ejecútala. Define `MANZANA_RECORDINGS` con una carpeta de capturas `rfNN….ts` para usarlas en lugar del sintonizador.
- **Bibliotecas y herramienta de desarrollo:** `swift build` y `swift test` (paquete Swift en la raíz, con libusb compilado desde `vendor/libusb`).
- **Herramienta de línea de comandos:** `make`, que necesita `brew install libusb pkg-config`.
- **Publicación:** `scripts/release.sh` archiva, firma, notariza y engrapa la app y el DMG.

## Cómo funciona

```
src/bridge/          puente USB DiB0700 sobre libusb: firmware, GPIO, reloj, I²C, streaming de TS
src/frontends/       demodulador DiB8000 + sintonizador DiB0090, tomados sin cambios de Linux
src/compat/          la pequeña capa de compatibilidad con la API del kernel que usan esos drivers
src/board/           código de la placa STK8096GP, copiado de dib0700_devices.c de Linux
src/ts/              análisis de PAT/SDT/NIT y números de canal virtual ISDB-T
src/core/            la API en C (manzana.h): sintonizar, escanear, transmitir, filtro de programa, lista de canales
src/cli/             el comando manzanavision
Sources/ManzanaTuner     actor de Swift sobre el núcleo en C, conexión en caliente, firmware y lista de canales
Sources/ManzanaStream    demultiplexor TS y análisis de H.264 y AAC (ADTS, LATM)
Sources/ManzanaPlayback  decodificación con VideoToolbox, desentrelazado con Metal, audio, sincronía A/V
Sources/ManzanaTV        la sesión en vivo: estado, recepción, resintonización, búsqueda
App/                     la app en SwiftUI
```

Los drivers del demodulador y del sintonizador son unas 7.000 líneas de máquinas de estado sensibles a los tiempos, así que se compilan **sin modificar** desde el árbol de Linux en vez de reescribirlos. `src/frontends/PATCHES.md` registra cualquier cambio local (hasta ahora ninguno), para poder mantener los archivos al día con upstream.

Notas de la puesta en marcha con hardware real:

- El firmware del puente vive en RAM. El dispositivo arranca "en frío" y necesita que se le cargue el firmware después de cada reconexión; la app y la herramienta lo hacen solas.
- Linux maneja esta placa con las peticiones I²C antiguas del puente (`0x02`/`0x03`). Las nuevas (`0x12`/`0x13`) se traban apenas el DiB8000 cambia a su reloj PLL.
- Si un múltiplex engancha pero muestra `B: … NO LOCK`, la señal es demasiado débil para la capa full-seg en 64QAM, mientras la capa one-seg sí se decodifica. Es un problema de antena, no del driver.
- Los canales de aquí transmiten 1080i como imágenes de campo (PAFF) o MBAFF, y HE-AAC en LATM o AAC en ADTS (uno etiqueta ADTS como LATM). La reproducción empareja los campos y desentrelaza en la GPU, porque el desentrelazador de VideoToolbox solo entrega 30 fps.

## Licencia

GPL-2.0-only, igual que los drivers de Linux en los que se basa. Ver [LICENSE](LICENSE). libusb es LGPL-2.1; el firmware tiene su propia licencia (ver arriba).
