# ManzanaVision

[English](README.md) · [Español](README.es.md) · [Português](README.pt-BR.md) · **日本語**

macOS 用の、USB チューナー **DiBcom STK8096GP** 向けユーザー空間 ISDB-T ドライバーとチャンネルスキャナーです。libusb を使っており、カーネル拡張、DriverKit、`sudo` はいずれも不要です。

macOS はこのデバイス（USB `10b8:1fa0`）を占有しないため、通常のプログラムから開いて、Linux の `dvb-usb-dib0700` ドライバーと同じ処理を行えます。ブリッジのファームウェア転送、復調器とチューナーの初期化、チャンネルへのロック、MPEG トランスポートストリームの受信です。

> **日本でのご利用について：** 現在の対象は、南米（ブラジル・チリなど）で使われている ISDB-T（SBTVD）です。
> - チャンネル番号は ABNT 方式です（`isdbt_channel_freq()` を参照）。日本の物理チャンネル *n* は ABNT の *n*+1 に当たるため、たとえば日本の 13ch は `tune 14` で受信できます。ただし `scan` の範囲は 14–51 なので、日本の 13ch はスキャンされません。
> - サービス名の文字列は ISO 8859-15 としてデコードしています。ARIB STD-B24（日本の 8 単位符号）の文字列は正しく表示されません。
> - 日本の放送は B-CAS/ACAS でスクランブルされています。ロックと PSI の取得はできますが、映像の視聴はできません。

## 機能

- UHF 14〜51ch をスキャンし、ロックできた多重ごとに次の情報を表示します。
  - 信号強度と SNR
  - TMCC パラメーター（モード、ガードインターバル、各階層の変調方式・符号化率・セグメント数）と、実際にデコードできている階層
  - PAT/SDT/NIT から読み取った、多重内のサービス名と仮想チャンネル番号（例：9.1、9.2、9.31）
- 1 チャンネルを選局し、TS をファイルに保存します。保存したファイルは VLC や ffplay で再生できます。

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

## 必要なもの

- macOS（Apple シリコンまたは Intel）
- Xcode コマンドラインツール（`xcode-select --install`）
- libusb と pkg-config：`brew install libusb pkg-config`
- DiBcom STK8096GP（`10b8:1fa0`）と UHF アンテナ

## ビルド

```sh
make
```

DiB0700 ブリッジのファームウェア（`firmware/dvb-usb-dib0700-1.20.fw`、linux-firmware 由来）を同梱しています。DiBcom は [`firmware/LICENSE.dib0700`](firmware/LICENSE.dib0700) の条件での再配布を認めています。別のファイルを使う場合は `MANZANA_FIRMWARE` で指定してください。

## 使い方

```sh
./manzanavision probe                  # ファームウェアを転送し、チップを識別
./manzanavision scan                   # UHF 14–51 をスキャンし、チャンネルリストを保存
./manzanavision channels               # 保存済みチャンネルを表示
./manzanavision watch 9.1 | ffplay -   # チャンネルを視聴（watch 9、watch "MEGA HD" も可）
./manzanavision scan --from 20 --to 40 --json
./manzanavision tune 27                # 1 チャンネルを選局し、サービスを一覧表示
./manzanavision tune 27 --dump rf27.ts --seconds 30
./manzanavision signal 23 --beep     # アンテナ調整用のリアルタイム信号メーター
```

`signal` は、SNR、信号レベル、各階層のロック状態、訂正不能パケット数（毎秒）を 1 秒に 4 回更新し、ロックが外れると自動で再選局します。`--beep` を付けると、衛星受信機のようなアンテナ調整音が鳴ります。音の高さは SNR に応じて上がり、全階層がロックしていれば連続音、一部だけなら断続音になり、ロックしていないときは鳴りません。耳だけでアンテナを調整できます。

`scan` は見つかったチャンネルを `~/Library/Application Support/ManzanaVision/channels.tsv`（`MANZANA_CHANNELS` で変更可）に統合します。タブ区切りのテキストなので、読んだり手で編集したりできます。後のスキャンでロックしなかった多重のチャンネルは、そのまま残ります。`watch` は保存済みチャンネルを選局し、その番組だけを MPEG-TS として出力します。PAT はそのサービスだけを載せたものに書き換え、PMT と各ストリームだけを通すので、ffplay、mpv、VLC（`| /Applications/VLC.app/Contents/MacOS/VLC -`）でオプションなしに再生できます。`--output ファイル` を付けると、再生の代わりに録画します。信号が 2 秒間途切れると自動で再選局して配信を再開するので、プレーヤー側では短い途切れが生じるだけです。プレーヤーを閉じるか Ctrl-C で停止します。

`-v` でドライバーのデバッグログを、`-vv` でさらに I²C のトレースを出力します。これらはコマンドの前に付けます（例：`./manzanavision -v tune 27`）。

南米の放送を録画したファイルを VLC で見るときは、`--ts-standard=dvb` を付けてください。付けないと、VLC がサービス名を ARIB の文字列として解釈し、漢字に化けてしまいます。

```sh
/Applications/VLC.app/Contents/MacOS/VLC --ts-standard=dvb rf27.ts
```

## 仕組み

```
src/bridge/     libusb 上の DiB0700 USB ブリッジ（ファームウェア、GPIO、クロック、I²C、TS 受信）
src/frontends/  DiB8000 復調器と DiB0090 チューナー（Linux から無変更で取り込み）
src/compat/     上記ドライバー用の、小さなカーネル API 互換レイヤー
src/board/      STK8096GP のボード固有コード（Linux の dib0700_devices.c から移植）
src/ts/         PAT/SDT/NIT の解析と ISDB-T 仮想チャンネル番号
src/scan.c      選局 → TMCC 読み出し → PSI 収集 → 表示
```

復調器とチューナーのドライバーは、タイミングに敏感なステートマシンで合計約 7,000 行あります。そのため書き直さず、Linux のソースを**無変更のまま**コンパイルしています。ローカルな変更は `src/frontends/PATCHES.md` に記録し（現時点ではなし）、上流と同期しやすくしています。

実機での立ち上げで分かったこと：

- ブリッジのファームウェアは RAM 上で動作します。デバイスはコールド状態で起動するため、USB を挿し直すたびにファームウェアの転送が必要です。`probe`・`scan`・`tune` は自動で転送します。
- Linux はこのボードを、ブリッジの旧 I²C リクエスト（`0x02`/`0x03`）で制御しています。新しいリクエスト（`0x12`/`0x13`）を使うと、DiB8000 が PLL クロックに切り替わった時点でストールします。
- ロックはしても `B: … NO LOCK` と表示される場合、ワンセグ階層はデコードできていますが、64QAM のフルセグ階層に対して信号が弱すぎます。これはドライバーではなくアンテナの問題です。

## 状況

MVP は動作しています。作者の環境では、実用的な信号がある多重はすべてロックしてサービスを一覧表示でき、TS のキャプチャーも欠落なしで取得できています（17.3 Mbit/s、連続性エラーなし）。`watch` の出力をプレーヤーに渡せば、ライブ視聴ができます。今後の候補は、EPG（番組表）、HDHomeRun 互換チューナーとしてのネットワーク配信、Mac アプリです。

## ライセンス

GPL-2.0-only（元にした Linux ドライバーと同じ）。[LICENSE](LICENSE) を参照してください。
