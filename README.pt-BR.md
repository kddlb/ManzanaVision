# ManzanaVision

[English](README.md) · [Español](README.es.md) · **Português** · [日本語](README.ja.md)

Driver ISDB-T em espaço de usuário e scanner de canais para o sintonizador USB **DiBcom STK8096GP** no macOS, feito sobre a libusb. Sem extensão de kernel, sem DriverKit e sem `sudo`.

O macOS não assume o controle deste dispositivo (USB `10b8:1fa0`), então um programa comum consegue abri-lo e fazer tudo o que o driver `dvb-usb-dib0700` do Linux faz: carregar o firmware da ponte, inicializar o demodulador e o sintonizador, sintonizar um canal e receber o transport stream MPEG.

## O que ele faz

- Varre os canais UHF 14 a 51 e informa cada multiplex que sintoniza, com:
  - intensidade de sinal e SNR
  - parâmetros TMCC (modo, intervalo de guarda e, por camada, modulação, taxa de código e segmentos), além de quais camadas estão sendo decodificadas
  - os serviços do multiplex, com nome e número de canal virtual (por exemplo 9.1, 9.2 e 9.31), lidos de PAT/SDT/NIT
- Sintoniza um canal e grava o TS em um arquivo que pode ser assistido no VLC ou no ffplay.

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

A numeração dos canais segue o plano ABNT/SBTVD usado no Brasil, no Chile e no restante da América Latina: o canal *n* fica centrado em 473 + 6·(n−14) + 1/7 MHz.

## Requisitos

- macOS em Apple silicon ou Intel
- Command Line Tools do Xcode (`xcode-select --install`)
- libusb e pkg-config: `brew install libusb pkg-config`
- Um DiBcom STK8096GP (`10b8:1fa0`) e uma antena UHF

## Compilação

```sh
make
scripts/fetch-firmware.sh   # baixa o dvb-usb-dib0700-1.20.fw do linux-firmware
```

O firmware não vem no repositório. O script o baixa do linux-firmware e confere o SHA-1. Você também pode apontar `MANZANA_FIRMWARE` para uma cópia que já tenha.

## Uso

```sh
./manzanavision probe                  # carrega o firmware e identifica os chips
./manzanavision scan                   # varre UHF 14–51 e salva a lista de canais
./manzanavision channels               # mostra os canais salvos
./manzanavision watch 9.1 | ffplay -   # assistir a um canal (também: watch 9, watch "MEGA HD")
./manzanavision scan --from 20 --to 40 --json
./manzanavision tune 27                # sintoniza um canal e lista seus serviços
./manzanavision tune 27 --dump rf27.ts --seconds 30
./manzanavision signal 23 --beep     # medidor de sinal ao vivo para apontar a antena
```

`signal` atualiza quatro vezes por segundo o SNR, o nível, o travamento de cada camada e os pacotes com erros não corrigíveis por segundo, e sintoniza de novo se o sinal for perdido. Com `--beep`, ele toca um tom como o dos receptores de satélite: o tom sobe com o SNR, fica contínuo quando todas as camadas estão travadas, intermitente quando só algumas estão e silencia quando não há sinal travado. Dá para apontar a antena só de ouvido.

O `scan` junta o que encontra em `~/Library/Application Support/ManzanaVision/channels.tsv` (dá para trocar com `MANZANA_CHANNELS`), um arquivo de texto separado por tabulações que você pode ler ou editar. Se um multiplex não sintonizar numa varredura posterior, os canais salvos dele são mantidos. O `watch` sintoniza um canal salvo e grava só aquele programa como MPEG-TS, com uma PAT que lista apenas esse serviço, sua PMT e seus streams, então ffplay, mpv ou VLC (`| /Applications/VLC.app/Contents/MacOS/VLC -`) abrem sem opções extras. Com `--output ARQUIVO`, ele grava em vez de exibir. Se o sinal cair por 2 segundos, o `watch` sintoniza de novo sozinho e continua, e o player só vê uma pequena interrupção. Ele para quando o player é fechado ou com Ctrl-C.

`-v` liga o log de depuração dos drivers e `-vv` acrescenta um trace de I²C. Coloque-os antes do comando, por exemplo `./manzanavision -v tune 27`.

Para assistir a uma captura, diga ao VLC para tratar o stream como DVB, para que os nomes dos serviços apareçam corretamente:

```sh
/Applications/VLC.app/Contents/MacOS/VLC --ts-standard=dvb rf27.ts
```

Caso contrário, o VLC assume texto japonês ARIB e os nomes latino-americanos aparecem como kanji.

## Como funciona

```
src/bridge/     ponte USB DiB0700 sobre a libusb: firmware, GPIO, clock, I²C, streaming do TS
src/frontends/  demodulador DiB8000 + sintonizador DiB0090, copiados sem alterações do Linux
src/compat/     a pequena camada de compatibilidade com a API do kernel de que esses drivers precisam
src/board/      código da placa STK8096GP, copiado do dib0700_devices.c do Linux
src/ts/         leitura de PAT/SDT/NIT e números de canal virtual ISDB-T
src/scan.c      sintonizar → ler TMCC → coletar PSI → informar
```

Os drivers do demodulador e do sintonizador somam cerca de 7.000 linhas de máquinas de estado sensíveis a tempo, por isso são compilados **sem modificações** a partir da árvore do Linux em vez de reescritos. O `src/frontends/PATCHES.md` registra qualquer mudança local (até agora, nenhuma), para que os arquivos possam acompanhar o upstream.

Notas da inicialização no hardware real:

- O firmware da ponte fica na RAM. O dispositivo liga "a frio" e precisa receber o firmware a cada vez que é conectado. `probe`, `scan` e `tune` fazem isso automaticamente.
- O Linux controla esta placa com os comandos I²C antigos da ponte (`0x02`/`0x03`). Os novos (`0x12`/`0x13`) travam assim que o DiB8000 passa para o clock do PLL.
- Se um multiplex sintoniza mas mostra `B: … NO LOCK`, o sinal não é suficiente para a camada full-seg em 64QAM, embora a camada one-seg continue sendo decodificada. É um problema de antena, não do driver.

## Situação

O MVP funciona: no dispositivo do autor, o scanner sintoniza e lista os serviços de todo multiplex com sinal utilizável, e as capturas de TS saem sem perdas (17,3 Mbit/s, sem erros de continuidade). Já dá para assistir ao vivo ligando o `watch` a um player. Os próximos passos podem incluir um guia de programação (EPG), servir os canais na rede como um sintonizador compatível com HDHomeRun e um app para Mac.

## Licença

GPL-2.0-only, a mesma dos drivers do Linux em que se baseia. Veja [LICENSE](LICENSE).
