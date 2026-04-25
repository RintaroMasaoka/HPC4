# hpc4 skill — 人間向けガイド

HKUST HPC4 クラスタへの SSH / コマンド実行 / ファイル転送を、ネットワーク経路の面倒ごと込みで自動化する Claude Code 用 skill。Mac (オンキャンパス / オフキャンパス + HKUST SSL VPN / NordVPN 等のフル VPN 併用) のどの状態でも同じ呼び方で繋がる。

## インストール

skill 本体は `hpc4/` フォルダひとつ。これを Claude Code が読む場所に置けばよい。スコープは 2 択:

- **ユーザ全体**: `~/.claude/skills/hpc4/` — どのプロジェクトでも `/hpc4` が使える
- **プロジェクト限定**: `<プロジェクト>/.claude/skills/hpc4/` — そのプロジェクト内だけ

### 1. ZIP を取得

リポジトリ右上の **Code** → **Download ZIP**、解凍（自動解凍ならスキップ）。

### 2. 配置（Finder / ターミナル のどちらか）

**Finder**: `Cmd+Shift+.` で隠しフォルダ表示。ZIP 内 `HPC4-main/.claude/skills/hpc4/` を、配置先（ホーム or プロジェクト直下）の `.claude/skills/` にドラッグ & ドロップ。

**ターミナル**: 以下を順に貼る。

```bash
cd ~
```
(ユーザ全体想定。プロジェクト限定なら cd <プロジェクトのパス>)

```bash
mkdir -p .claude/skills && mv ~/Downloads/HPC4-main/.claude/skills/hpc4 .claude/skills/
```

> ターミナルに Finder のフォルダをドラッグ & ドロップすると絶対パスが挿入される（`cd` 先や `mv` のソースを書き換える時に便利）。

---

## 使い方

**チャットに `/hpc4` と入れるだけ。** 未セットアップなら setup が起動して必要事項を聞いてくれる。セットアップ済みなら「何をしたいか」を聞いてくるので、自然な日本語/英語で答えればよい。

初回 setup でユーザが手を動かすのは最大 2 アクション:
1. ITSO ユーザ名を答える（チャットで）
2. 別ターミナルで `ssh-copy-id` を 1 回実行（password + 2FA を通す）

以降の SSH は ControlMaster で 12 時間 cache されるので password 不要。

セットアップ済みなら、`/hpc4` を介さずチャットで普通に頼むだけでも Claude が裏側で経路整備・コマンド実行・ファイル転送を進める。例:

- 「HPC4 で自分の queue を見て」
- 「このディレクトリを HPC4 の `/scratch/$USER/` 以下に上げて、`sbatch run.sh` で投入して」
- 「HPC4 のログを取ってきて中身を要約して」
- 「HPC4 に繋がらなくなった、調べて」

コマンドを覚える必要はない。

## 想定環境

- macOS（Linux/Windows は対応外）
- HKUST ITSO アカウント
- HPC4 の利用権限（既定では渡辺グループ `watanabemc`。他 group の場合は setup で account を変更）
- オフキャンパスから使うなら Ivanti Secure Access（HKUST SSL VPN クライアント、別途インストール）

---

# HKUST HPC4 公式情報リファレンス

skill の動作とは独立に、HPC4 を使う上で覚えておきたい運用情報。一次情報は HKUST HPC4 公式ドキュメントが優先される（ここは便宜のための要約）。

### アカウント・リソース概要

| 項目 | 値 |
|---|---|
| Login host | `hpc4.ust.hk` |
| Slurm account | `watanabemc`（渡辺 group。他 group は所属に応じて変更） |
| Partitions | `amd`, `intel` |
| Home quota | 200 GB / user (`/home/<username>`) |
| Project quota | 10 TB / group (`/project/watanabemc`、NFS) |
| Scratch quota | 500 GB / user (`/scratch/<username>`、SSD NFS、60 日 inactive で削除) |

### デフォルト Slurm 資源比率

`--cpus-per-task` または `--gpus-per-node` だけ指定すれば、Slurm が以下の比で RAM 等を自動配分する。手動で `--mem` を盛らないのが推奨:

| Node / Resource | 既定割当比 |
|---|---|
| AMD nodes | 1 CPU : 2.8 GB RAM |
| Intel nodes | 1 CPU : 3.8 GB RAM |
| A30 / L20 GPU | 1 GPU : 16 threads (HT off) : 7.5 GB RAM/thread |
| RTX4090D / RTX5880ADA | 1 GPU : 10 threads (HT off) : 7.5 GB RAM/thread |

### Interactive ジョブの起動例

```bash
# CPU
srun --account=watanabemc --partition=<partition_name> \
     --ntasks-per-node=1 --cpus-per-task=16 --nodes=1 \
     --time=01:00:00 --pty bash

# GPU
srun --account=watanabemc --partition=<partition_name> \
     --gpus-per-node=1 --nodes=1 --time=01:00:00 --pty bash
```

### Batch ジョブのテンプレ

```bash
#!/bin/bash
#SBATCH --account=watanabemc
#SBATCH --partition=<partition_name>
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1   # GPU 不要なら削除
#SBATCH --time=01:00:00

# module load cuda  など必要に応じて
# source activate my_env

python your_script.py
```

投入: `sbatch job.sh`、状態確認: `squeue -u $USER`。

### モニタリング・運用コマンド

| コマンド | 内容 |
|---|---|
| `savail` | 各 partition の空き GPU/CPU/メモリ概観。大規模投入前に確認 |
| `squota -A watanabemc` | group の storage / GPU / CPU 累積使用量 |
| `squota` | 個人使用量サマリ |
| `squeue -u $USER` | 自分の active / queued ジョブ |
| `sacctmgr show qos <qos_name> format=Name,MaxSubmitPU,MaxJobsPU,MaxWall` | QOS 上限確認 |

### 課金・利用ポリシー

- 利用料金は月次。明細は PI に送付される
- `/project` の quota 超過分は別途課金対象
- 利用は **HKUST 研究または coursework 限定**
- 大規模投入前に quota 確認、終了後は temp ファイル除去
- ジョブは時間制限内に収める

### コンテナ・ソフトウェアビルド

- Singularity / Apptainer サポートあり（公式ドキュメント参照）
- Spack による独自ソフトウェアスタック構築可能（[Spack Documentation](https://spack.io)）

### サポート連絡先

- 技術的問題（アカウント / ジョブ / quota）: `hpc4support@ust.hk`
- 緊急時（service interruption）はメールに job ID（`squeue -u $USER` の出力）と error log を添付
- 公式: HKUST HPC4 Official Website / HKUST HPC Knowledge Base

### より深い運用知識

HPC4 上で sbatch を回す側の運用知識（QOS 上限を超える投入の throttle dispatcher / tmux で disconnect に耐える / walltime の決め方 / ファイルシステムの使い分け / 接続層の踏みやすい罠）は [SKILL.md](SKILL.md) 後半の「Slurm ジョブ投入の運用知識」節を参照。

---

# 詳細を知りたい方へ

skill の内部実装、安全性、共有時の留意点。通常使う分には開かなくてよい。

<details>
<summary><b>このスクリプトが macOS に対して何をするか</b>（透明性 / 安全性）</summary>

### 触る範囲

| 項目 | 変更内容 |
|---|---|
| route table | host route を 1 行追加（`143.89.184.3` のみ） |
| pf ruleset | anchor `main/hpc4` の中身を上書き（HPC4 宛のみ pass する rule） |
| `/tmp/hpc4-cm-*` | SSH ControlMaster ソケット |

### 触らない範囲

- `/etc/hosts`、`/etc/resolv.conf`、`~/.ssh/config`（プロジェクト内 `ssh_config` のみ使用）
- システム全体の pf ルール、他の anchor（VPN client / Apple / Little Snitch / LuLu 等）
- launchd、kernel extension、システム設定 GUI
- 既存の VPN client の設定や接続

### 永続性

**全部 in-memory。Mac を再起動すれば自動で全消去される**:

- macOS の host route は永続化機構なし
- pf anchor のルールはメモリ常駐のみ
- ControlMaster ソケットは `/tmp` 配下

意図的に teardown したい場合は Claude に「経路を取り外して」と頼む。冪等に anchor のルールを空にし、route を削除し、ControlMaster を close する。

### 特権操作

`route` と `pfctl` がカーネルを触るため sudo が要る。`net-up.sh` 中の sudo 呼び出しは:

- `sudo route add -host 143.89.184.3 ...` 1 回
- `sudo pfctl -a "main/hpc4" -f -` 1 回（anchor 名は [common.sh](scripts/common.sh) で固定文字列）

外部入力を sudo コマンドに混ぜていないので shell injection の余地はない。Touch ID 設定があれば指紋で通る。

</details>

<details>
<summary><b>共有時の注意点</b>（規約・競合・個人情報）</summary>

### 規約・ポリシー

- **個人所有 Mac**: pf ルールはユーザの権限内なので問題なし
- **企業支給 Mac**: corporate MDM で pf 監査がある場合は事前に IT に確認
- **商用 VPN との関係**: 機能的には provider 公認の split tunneling と同等だが、provider の規約解釈は保証外。気になるなら **VPN client 側で `143.89.184.3` を split tunnel に追加** すれば pf anchor は呼ばれない

### 競合

- **Little Snitch / LuLu** 等を併用している場合、本 skill の anchor では迂回できない（別途許可が要る）。`net-up.sh` はこのケースを末尾で警告して exit する
- **他のキルスイッチ型 VPN client** は、下回りに HKUST ネット（en0 が 143.89/16 直結 or Ivanti 接続中）がある前提で共存する（NordVPN / SurfShark / ExpressVPN / Proton / Mullvad で動作確認済）。下回りが HKUST 圏外なら anchor では救えないので Ivanti を起動する

### 個人情報

- ITSO ユーザ名は `user.conf.local` に保存され、`.gitignore` 済（リポジトリには入らない）
- SSH 秘密鍵は `~/.ssh/` 配下のまま。skill 側に複製しない
- **頒布前**: 自分の `user.conf.local` を削除してから配布する（`git archive` や clean clone なら自動で除外される）

</details>

<details>
<summary><b>ネットワーク経路の自動判定</b></summary>

skill は環境を見て、必要最小限の介入だけ行う:

- オンキャンパス（eduroam / HKUST 有線）→ そのまま
- オフキャンパス + Ivanti Secure Access → utun 経由でルート追加
- 上記 + NordVPN 等のキルスイッチ型フル VPN → pf anchor で HPC4 宛だけ例外許可
- 商用 VPN 不使用の海外 wifi + Ivanti のみ → そのまま split-tunnel
- HKUST 圏外ネット + Ivanti 未起動（テザリング、ホテル wifi 等）→ HPC4 へ届く下回り経路がそもそも無いので、Ivanti 起動 / 学内ネット切替を案内（pf anchor では救えない）

各層の動作と踏みやすい罠は [SKILL.md](SKILL.md) の「ネットワーク層の仕組み」「接続層の踏みやすい罠」節を参照。

</details>

<details>
<summary><b>ファイル構成</b></summary>

```
.claude/skills/hpc4/
├── SKILL.md              LLM 向け instruction（本 skill の振る舞い定義）
├── README.md             本ファイル（人間向けガイド）
├── ssh_config            HPC4 専用 SSH 設定（HostName を IP 直指定）
├── user.conf.local       個人設定（gitignored、setup で生成される）
└── scripts/
    ├── common.sh         共通定数とヘルパー関数
    ├── status.sh         接続状態の診断
    ├── net-up.sh         経路を整える（route + pf anchor）
    ├── net-down.sh       経路を取り外す
    ├── ssh-run.sh        HPC4 でコマンド実行
    ├── xfer.sh           ファイル転送 (scp/rsync)
    └── write-user-conf.sh  user.conf.local 生成
```

</details>

<details>
<summary><b>メンテナンス（HPC4 の IP 変更時）</b></summary>

HKUST から `hpc4.ust.hk` の IP 変更通知を受けた場合、以下 2 箇所を更新する:

- [scripts/common.sh](scripts/common.sh) の `HPC4_IP`
- [ssh_config](ssh_config) の `HostName`

両方を同じ IP に揃える（片方だけだと「ping は通るが ssh が繋がらない」等の不整合になる）。頻度は数年に 1 回程度の想定。

</details>

<details>
<summary><b>トラブル時に人間が直接叩く debug 手段</b></summary>

通常は Claude に「HPC4 の状態を確認して」「経路をリセットして」と頼めば手当する。それでも解決しない時:

```
ssh -F .claude/skills/hpc4/ssh_config -l <user> -vvv hpc4   # SSH 詳細ログ
```

各層の詳細な動作は [SKILL.md](SKILL.md) の「ネットワーク層の仕組み」「接続層の踏みやすい罠」節。

</details>

<details>
<summary><b>scripts 一覧</b>（直接叩く時の参照）</summary>

通常は Claude に自然言語で頼めばよい。Claude を介さず手で叩きたい時、または LLM が文脈から呼ぶ時の参照:

| script | 内容 |
|---|---|
| `bash .claude/skills/hpc4/scripts/status.sh` | 現在の接続状態を表示（sudo 不要） |
| `bash .claude/skills/hpc4/scripts/write-user-conf.sh <itso_username>` | `user.conf.local` を生成（初回 setup） |
| `bash .claude/skills/hpc4/scripts/net-up.sh` | HPC4 に届く経路を整える（route + pf anchor、必要分だけ） |
| `bash .claude/skills/hpc4/scripts/net-down.sh` | 経路と pf anchor を取り外す |
| `bash .claude/skills/hpc4/scripts/ssh-run.sh '<command>'` | HPC4 上で任意コマンドを実行 |
| `bash .claude/skills/hpc4/scripts/xfer.sh put <local> <remote>` | ファイルを HPC4 にアップロード |
| `bash .claude/skills/hpc4/scripts/xfer.sh get <remote> <local>` | ファイルを HPC4 からダウンロード |
| `bash .claude/skills/hpc4/scripts/xfer.sh put-r <local> <remote>` | ディレクトリを rsync で送る |
| `bash .claude/skills/hpc4/scripts/xfer.sh get-r <remote> <local>` | ディレクトリを rsync で取得 |

`ssh-run.sh` / `xfer.sh` は内部で `net-up.sh` 相当の経路整備を自動で行うので、経路を意識せず目的の操作を直接呼んでよい。

</details>
