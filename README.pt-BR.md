# ManzanaVision

[English](README.md) · [Español](README.es.md) · **Português**

Um app para Mac para assistir à TV digital aberta **ISDB-T** com um sintonizador USB **DiBcom STK8096GP**. Ele controla o dispositivo sozinho, em espaço de usuário, com a libusb: sem extensão de kernel, sem DriverKit, sem `sudo` e sem mais nada para instalar.

O macOS não assume o controle deste dispositivo (USB `10b8:1fa0`), então um programa comum consegue abri-lo e fazer tudo o que o driver `dvb-usb-dib0700` do Linux faz: carregar o firmware da ponte, inicializar o demodulador e o sintonizador, sintonizar um canal e receber o transport stream MPEG. O ManzanaVision faz isso e depois decodifica e reproduz a imagem e o som de forma nativa.

## Download

Baixe o DMG em [Releases](https://github.com/kddlb/ManzanaVision/releases), abra-o e arraste o ManzanaVision para Aplicativos. O app é assinado com um Developer ID e notarizado pela Apple.

- Um Mac com Apple silicon e macOS 27 ou posterior
- Um DiBcom STK8096GP (`10b8:1fa0`) e uma antena UHF

O firmware do sintonizador e a libusb já vêm dentro do app.

## Usando o app

- **Buscar** (botão da barra de ferramentas) sintoniza os canais UHF 14 a 51, ou o intervalo que você escolher, e mostra o que encontra em cada frequência. Na barra lateral, os canais ficam agrupados por emissora. Os serviços 1seg (celular) ficam ocultos, a menos que você os ative nos Ajustes.
- **Trocar de canal:** clique em um, use ⌘↑/⌘↓ ou Page Up/Page Down, ou digite o número (`9.1`, ou só `9`) e pressione Return. O app lembra o último canal.
- **Imagem:** 1080i, 1080p e 720p, com desentrelaçamento YADIF a 60 fps (outros modos nos Ajustes), além de serviços 1seg e de rádio.
- **Informações do sinal** (⌘I) mostra SNR, nível, o sincronismo e a modulação de cada camada, erros, os formatos de vídeo e áudio, os buffers e os contadores de recuperação.
- **Os problemas são explicados na tela:** sintonizador desconectado, em uso por outro programa, sem sinal, recepção fraca ou ruim. Depois de uma queda, a imagem fica desfocada enquanto o app ressintoniza sozinho, e a reprodução volta quando o sintonizador é conectado de novo.
- **Tela cheia** mostra só a imagem: clique duas vezes nela e pressione Esc para sair. **Picture in Picture** fica no menu Canal (⌃⌘P).
- **Gravar** (⌘R, ou Canal → Gravar por) salva o canal exatamente como transmitido, em MPEG-TS, em Filmes/ManzanaVision; VLC, IINA e mpv tocam o arquivo. **Arquivo → Exportar gravação para QuickTime** converte uma gravação em MP4 (HEVC, desentrelaçado a 60 fps, AAC) para o QuickTime, o Fotos ou um iPhone.
- O app está em inglês, espanhol e português do Brasil.

A numeração dos canais segue o plano ABNT/SBTVD usado no Brasil, no Chile e no resto da América Latina: o canal *n* é centrado em 473 + 6·(n−14) + 1/7 MHz.

## Ferramenta de linha de comando

O `manzanavision` faz o mesmo pelo terminal e compartilha a lista de canais com o app (`~/Library/Application Support/ManzanaVision/channels.tsv`; dá para trocar com `MANZANA_CHANNELS`).

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
./manzanavision probe                  # carrega o firmware e identifica os chips
./manzanavision scan                   # varre UHF 14–51 e salva a lista de canais
./manzanavision channels               # mostra os canais salvos
./manzanavision watch 9.1 | ffplay -   # assiste a um canal (também: watch 9, watch "MEGA HD")
./manzanavision scan --from 20 --to 40 --json
./manzanavision tune 27                # sintoniza um canal e lista os serviços
./manzanavision tune 27 --dump rf27.ts --seconds 30
./manzanavision signal 23 --beep       # medidor de sinal ao vivo para apontar a antena
```

- **`scan`** informa cada multiplex que sintoniza: intensidade de sinal e SNR, os parâmetros TMCC (modo, intervalo de guarda e, por camada, modulação, taxa de código e segmentos) e quais camadas estão decodificando, e os serviços com nomes e números de canal virtual lidos da PAT/SDT/NIT. Tudo entra na lista de canais; um multiplex que não sintoniza numa busca posterior mantém os canais salvos.
- **`signal`** atualiza SNR, nível, o sincronismo de cada camada e os pacotes não corrigíveis por segundo quatro vezes por segundo. Com `--beep`, toca um tom de busca como o dos receptores de satélite: o tom sobe com o SNR, é contínuo quando todas as camadas estão sincronizadas, intermitente quando só algumas estão e fica em silêncio sem sincronismo. Dá para apontar a antena de ouvido.
- **`watch`** entrega um único programa em MPEG-TS, com uma PAT que lista só esse serviço, então ffplay, mpv ou VLC (`| /Applications/VLC.app/Contents/MacOS/VLC -`) o abrem sem opções. Use `--output ARQUIVO` para gravar. Se o sinal cair por 2 segundos, ele ressintoniza e continua.
- `-v` liga o log de depuração dos drivers e `-vv` acrescenta um rastreamento de I²C. Eles vêm antes do comando, por exemplo `./manzanavision -v tune 27`.

Para assistir a uma captura no VLC, acrescente `--ts-standard=dvb`. Sem isso, o VLC supõe texto ARIB japonês e os nomes dos serviços latino-americanos aparecem em kanji.

## Compilação

O firmware (`firmware/dvb-usb-dib0700-1.20.fw`, do linux-firmware) está incluído; a DiBcom permite redistribuí-lo nos termos de [`firmware/LICENSE.dib0700`](firmware/LICENSE.dib0700). Defina `MANZANA_FIRMWARE` para usar outra cópia.

- **App:** abra `App/ManzanaVision/ManzanaVision.xcodeproj` no Xcode 27 e execute. Defina `MANZANA_RECORDINGS` com uma pasta de capturas `rfNN….ts` para usá-las no lugar do sintonizador.
- **Bibliotecas e ferramenta de desenvolvimento:** `swift build` e `swift test` (pacote Swift na raiz, com a libusb compilada a partir de `vendor/libusb`).
- **Ferramenta de linha de comando:** `make`, que precisa de `brew install libusb pkg-config`.
- **Publicação:** `scripts/release.sh` arquiva, assina, notariza e grampeia o app e o DMG.

## Como funciona

```
src/bridge/          ponte USB DiB0700 sobre a libusb: firmware, GPIO, clock, I²C, streaming de TS
src/frontends/       demodulador DiB8000 + sintonizador DiB0090, trazidos sem alterações do Linux
src/compat/          a pequena camada de compatibilidade com a API do kernel usada por esses drivers
src/board/           código da placa STK8096GP, copiado do dib0700_devices.c do Linux
src/ts/              análise de PAT/SDT/NIT e números de canal virtual ISDB-T
src/core/            a API em C (manzana.h): sintonizar, varrer, transmitir, filtro de programa, lista de canais
src/cli/             o comando manzanavision
Sources/ManzanaTuner     actor Swift em volta do núcleo em C, conexão a quente, firmware e lista de canais
Sources/ManzanaStream    demultiplexador TS e análise de H.264 e AAC (ADTS, LATM)
Sources/ManzanaPlayback  decodificação com VideoToolbox, desentrelaçamento com Metal, áudio, sincronia A/V
Sources/ManzanaTV        a sessão ao vivo: estado, recepção, ressintonia, busca
App/                     o app em SwiftUI
```

Os drivers do demodulador e do sintonizador somam cerca de 7.000 linhas de máquinas de estado sensíveis a tempo, por isso são compilados **sem modificações** a partir da árvore do Linux, em vez de reescritos. `src/frontends/PATCHES.md` registra qualquer alteração local (até agora nenhuma), para que os arquivos possam acompanhar o upstream.

Notas da colocação em funcionamento no hardware real:

- O firmware da ponte fica na RAM. O dispositivo liga "frio" e precisa do firmware carregado a cada reconexão; o app e a ferramenta fazem isso sozinhos.
- O Linux controla esta placa com as requisições I²C antigas da ponte (`0x02`/`0x03`). As mais novas (`0x12`/`0x13`) travam assim que o DiB8000 passa para o clock do PLL.
- Se um multiplex sintoniza mas mostra `B: … NO LOCK`, o sinal está fraco demais para a camada full-seg em 64QAM, enquanto a camada 1seg ainda decodifica. É um problema de antena, não do driver.
- As emissoras daqui transmitem 1080i como imagens de campo (PAFF) ou MBAFF, e HE-AAC em LATM ou AAC em ADTS (uma rotula ADTS como LATM). A reprodução junta os campos e faz o desentrelaçamento na GPU, porque o desentrelaçador do VideoToolbox só entrega 30 fps.

## Licença

GPL-2.0-only, a mesma dos drivers do Linux em que se baseia. Veja [LICENSE](LICENSE). A libusb é LGPL-2.1; o firmware tem licença própria (veja acima).
