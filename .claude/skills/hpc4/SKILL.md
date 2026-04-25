---
name: hpc4
description: "HKUST HPC4 への SSH 接続・リモートコマンド実行・ファイル転送を提供する。LLM が必要に応じて自律的に操作を呼び出す（ユーザが /hpc4 [subcommand] で明示的に呼び出すことも可）。subcommands: status, up, down, run, put, get, put-r, get-r, setup"
user-invocable: true
argument-hint: "[status | up | down | run <cmd> | put <l> <r> | get <r> <l> | setup]"
---

# hpc4 — HKUST HPC4 接続スキル

HKUST HPC4 (`hpc4.ust.hk`) クラスタへのアクセスを、ネットワーク経路（オンキャンパス直結 / HKUST SSL VPN / キルスイッチ型フル VPN）の面倒ごと込みで自動化する。VPN の種類・有無は自動判定するため事前設定は不要。

## このスキルの位置付け

- **本 skill は他のワークフロー（`/run`、`/write` 等）と独立**。それらの中で HPC4 リソースが必要になった時に呼び出されることはあるが、本 skill の動作規約は本ファイルが唯一の定義であり、外側のスキルの制約（例: AskUserQuestion 禁止）は本 skill の挙動に作用しない
- **基本は LLM が文脈から判断して自律的に操作を呼び出す**。ユーザが `/hpc4 [subcommand]` を直接叩く形でも呼べるが、それは副経路

## 提供する操作と LLM の選び方

LLM は文脈から以下のいずれかを選んで呼ぶ。**`run` / `put` / `get` 等は内部で経路（ルート + pf）を自動整備するので、経路を意識せず目的の操作を直接呼んでよい**。

| 操作 | 実体 | LLM がこれを呼ぶべき場面 |
|---|---|---|
| `status` | `scripts/status.sh` | HPC4 関連作業の前にざっと健康状態を確認したい時、またはトラブル切り分け時 |
| `run <cmd>` | `scripts/ssh-run.sh` | HPC4 上で任意コマンドを実行したい時（`squeue`、`sbatch`、`ls`、`cat` 等。経路は自動整備） |
| `put <l> <r>` / `get <r> <l>` | `scripts/xfer.sh put/get` | 単一ファイルの往復（スクリプト、小さい結果ファイル等） |
| `put-r <l> <r>` / `get-r <r> <l>` | `scripts/xfer.sh put-r/get-r` | ディレクトリ単位の rsync 転送（大量結果の引き上げ等） |
| `up` | `scripts/net-up.sh` | 経路だけ整えて接続テストしたい時、または status で経路欠落を発見した時 |
| `down` | `scripts/net-down.sh` | 経路や pf anchor を完全リセットしたい時（トラブル時のみ） |
| `setup` | 本ファイル「setup フロー」節 | `user.conf.local` が無い、または passwordless SSH が未成立で、最初に整える時 |

呼び出しは **直接 Bash でスクリプトを叩く** か、`/hpc4 <subcmd>` 経由のどちらでも構わない。後者の場合は `$ARGUMENTS` の最初の単語を subcommand、残りを引数として上表どおりに振り分ける。

### 引数なし（`/hpc4` 単体）の挙動

ユーザが subcommand なしで `/hpc4` を打った時は **対話的エントリポイント** として振る舞う。状況を見て次のいずれかに分岐:

1. `user.conf.local` が無い、または `HPC4_USER` が空 → **setup フローを起動**（ユーザに ITSO 名を聞き、`ssh-copy-id` を案内）
2. setup 済みだが passwordless SSH が未成立（`status.sh` で `passwordless: NO`）→ **setup ステップ C から再開**（`ssh-copy-id` を再案内）
3. 全部成立している → **何をしたいかをユーザに 1 文で聞く**。例: 「HPC4 のセットアップは済んでいます。何をしますか？（例: queue 確認 / ジョブ投入 / ファイル転送 / 状態確認）」。回答を受けて適切な操作（`run` / `put` / `get-r` / `status` 等）に振り分ける

LLM 自律呼び出しの場合は通常この経路は通らず、文脈から適切な subcommand を直接選ぶ。`/hpc4` 単体の対話は **ユーザがコマンドを覚えずに使えるための簡易入口**。

## 動作規約

1. **冪等性**: `up` を含むあらゆる操作は何度呼んでも壊れない。既に整っていれば no-op で抜ける
2. **必要最小限の介入**: ping/TCP22 で既に届くなら route も pf anchor も触らない（`net-up.sh` 段階 1）
3. **個人情報の隔離**: ITSO ユーザ名等は `user.conf.local`（gitignored）に閉じる。リポジトリ本体には書かない
4. **シェル操作をユーザに依頼しない**: 設定値は LLM がチャットで質問し `Write` で書き出す。`cp` や `chmod` をユーザに打たせない
5. **応答は短く**: 結果（ok / err / 要約）だけを返す。冗長な進捗説明は控える

## 対象環境

- **クラスタ**: `hpc4.ust.hk` (143.89.184.3)、Slurm account 既定値 `watanabemc`（user.conf.local で override 可能）
- **クライアント OS**: macOS。Linux/Windows は対応外
- **認証**: 公開鍵認証 (passwordless SSH) + ControlMaster 12h 永続化
- **ネットワーク**: オンキャンパス（eduroam / HKUST 有線）、オフキャンパス（Ivanti Secure Access = HKUST SSL VPN）、キルスイッチ型フル VPN（NordVPN / SurfShark / ExpressVPN / Proton / Mullvad 等）と共存可能

## setup フロー（初回 1 回だけ）

ゴール：**`user.conf.local` を作成し、passwordless SSH が通る状態にする**。ユーザには最大でも「ITSO ユーザ名を答える」「別ターミナルで 1 コマンド打って password+2FA を通す」の 2 アクションのみを依頼する。

### ステップ A. 個人情報の収集と保存

1. まず既存の状態をチェックする：
   - `.claude/skills/hpc4/user.conf.local` が既に存在し、`HPC4_USER` が空でないなら、**ユーザ確認のステップ A を丸ごとスキップ**してステップ B に進む
   - `~/.ssh/config` や `~/.ssh/known_hosts` から `hpc4.ust.hk` 宛の user 名を推定できれば、候補として保持（Grep や Read で収集。実行しなくてよい情報取得は自動で行う）
2. ユーザに `AskUserQuestion` でユーザ名を確認する。推定候補があればそれを `option` として提示、無ければ `Other` 欄に自由入力させる：
   - Question: 「HPC4 の ITSO アカウント名を教えてください（例: `login4` に `ssh` するときの username）」
3. 得られたユーザ名を引数にして `bash .claude/skills/hpc4/scripts/write-user-conf.sh <username>` を実行し、`user.conf.local` を生成。
4. `.gitignore` に `.claude/skills/hpc4/user.conf.local` が含まれているか確認し、未登録なら追記。

### ステップ B. ネットワーク層の確認

`bash .claude/skills/hpc4/scripts/net-up.sh` を実行。エラーで返った場合は status.sh の出力を見てユーザに指示：

- en0 gateway も Ivanti もない → 「eduroam / HKUST 有線に接続するか、Ivanti Secure Access で HKUST VPN を起動してください」
- en0 だけある → そのまま進む（スクリプトが自動でルート+pf を入れる）
- Ivanti だけある → スクリプトが utun 経由のルートを入れる

### ステップ C. passwordless SSH の確認

1. `bash .claude/skills/hpc4/scripts/status.sh` で passwordless SSH の成否を判定。
2. **既に成立している場合** は何もしない（ユーザへの依頼なし）。成立メッセージだけ返す。
3. **未成立の場合** は以下を 1 回だけ提示：
   - 秘密鍵がなければ `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519` を自動実行してよい（BatchMode 可）
   - `ssh-copy-id -i ~/.ssh/id_ed25519.pub <HPC4_USER>@hpc4.ust.hk` を「別ターミナルで 1 回だけ実行してください（password + 2FA の入力が必要）」と案内
   - 完了したらチャットで知らせてもらい、再度 status.sh で成立確認
4. 成立したら setup 完了メッセージを出す。

### ステップ D. 動作確認

`/hpc4 run 'hostname && whoami'` 相当を走らせて、`login{N}` と自分の username が返ってくることを確認。

## 典型的な呼び出しパターン

LLM が自律判断で呼ぶ際のテンプレート。`/hpc4 ...` 形式で書くがユーザがその通り叩く前提ではなく、LLM が直接 Bash でスクリプトを叩いてもよい（同等）。

```text
# 状態確認・初期化
status                    # HPC4 関連作業に入る前の健康診断
setup                     # user.conf.local が無い、または passwordless SSH 未成立の時

# クラスタ状態の問い合わせ
run 'squeue -u $USER'     # 自分のキュー状況
run 'savail'              # パーティション空き状況
run 'squota -A {account}' # group quota

# ジョブ投入の往復
put job.sh /scratch/$USER/job.sh
run 'cd /scratch/$USER && sbatch job.sh'
get-r /scratch/$USER/results results/
```

## ネットワーク層の仕組み（要点のみ）

段階的に、必要な分だけ介入する：

1. **まずそのままで届くか試す**（ping / TCP22）。届くなら何もしない（VPN 未使用や社内 LAN 直結のケース）
2. 届かないなら **`143.89.184.3` だけをローカル経路に流す** policy routing を入れる
   - en0 にデフォルトゲートウェイがある → en0 経由で `route add -host`
   - Ivanti (HKUST SSL VPN) の utun に `143.89.*` の IP が付いている → utun 経由で `route add -host -interface`
3. それでも届かず、かつ **フル VPN が default route を奪っている**（utun/ppp/tap/wg に default route が向いていて、その IP が 143.89/16 でない）場合だけ、pf anchor `main/hpc4` に HPC4 宛の例外許可を入れる
   - 対象は NordVPN / SurfShark / ExpressVPN / Proton / Mullvad などのキルスイッチ型フル VPN
   - Ivanti (HKUST SSL VPN) は split-tunnel で `143.89/16` しか utun に持って行かないので、この分岐には入らない

SSH 側は ControlMaster で 12h persist、password+2FA は実質 1 日 1 回で済む。

## sudo が必要な操作について

`net-up.sh` と `net-down.sh` は `route` と `pfctl` を触るため sudo が要る。Touch ID を有効にしておくと Claude Code の Bash ツールからでも指紋で通る。そうでなければ password 入力ダイアログが 1 回だけ出る。

## トラブル時の当たり方

1. `status` で現状を取り、どの層で落ちているか特定（ネットワーク / 認証 / ControlMaster）
2. `up` で経路を再整備（VPN や eduroam を再接続した直後はこれで直ることが多い）
3. `down` の後 `up` で完全リセット
4. それでも繋がらないなら `ssh -F .claude/skills/hpc4/ssh_config -l <user> -vvv hpc4` を直接叩いて詳細ログを取る

## 新しいメンバーへの引継ぎ

リポジトリを clone した人は `setup` を 1 回走らせれば使える状態になる。事前作業は不要。

---

## Slurm ジョブ投入の運用知識

接続が通った後、HPC4 上で sbatch を回す側で踏みやすい罠を集約する。プロジェクト固有の事項は含まない。

### ジョブモデル

- **1 sbatch = 1 job**。`--array=0-N` を付けると 1 job が N+1 個の **array task** に展開される。各 task は独立に schedule・課金される
- **account**: 計算時間が引かれる先。`user.conf.local` の `HPC4_ACCOUNT` が既定値（未設定なら `watanabemc`）
- **partition**: ノード群（`amd`, `intel`, ...）。**binary を compile した CPU と一致させる**。ISA 不整合（avx2/avx512 命令を出した binary を持たない CPU で実行）は illegal instruction で即落ちする
- **QOS**: partition 単位の同時投入上限。投入前に必ず確認: `sacctmgr show qos {qos_name} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall`
- **何が QOS counter に乗るか**: array task は **1 task ごと** に counter が進む。`--array=0-149` を 1 回 sbatch すると 150 進む。MaxSubmit より大きい array は受理されない

### Throttle dispatcher（QOS 上限を超える投入）

QOS の MaxSubmit を超える array job を続けて投げると `QOSMaxSubmitJobPerUserLimit` で reject される。**現在の queue 数を見て、上限まで余裕がある分だけ投入する dispatcher** を回すのが定石:

```bash
QUEUE_LIMIT=$((MaxSubmitPU - margin))   # 手動投入の余地を残す
ARRAY_SIZE=...                           # この sbatch で発行する task 数

while :; do
    n_q=$(squeue -u "$USER" -h -t PD,R 2>/dev/null | wc -l)
    if (( n_q + ARRAY_SIZE <= QUEUE_LIMIT )); then
        break
    fi
    sleep 60
done
sbatch --parsable my_array.sh
```

`-t PD,R` は **必須**: CG/CD/F も含めると終了済 job まで数えてしまう。

### 長時間 dispatcher は tmux に入れる

`nohup ... & disown` の生存性は OS / login shell / SSH client の組み合わせに依存し、SIGHUP が漏れて落ちるケースが実測される。安全側に倒すため、**数時間以上回す dispatcher は tmux/screen の detached session** に入れる:

```bash
/hpc4 run 'tmux new-session -d -s {name} "bash dispatcher.sh > log 2>&1"'
# 復帰時
/hpc4 run 'tmux list-sessions; tail -20 log'
```

dispatcher の生死は **まず `tmux list-sessions` または `ps -ef | grep dispatcher` で確認**する。log は補助情報に過ぎない: NFS の間欠 I/O で log に NULL byte が混入し `grep` が "binary file matches" を出したり tail が乱れたりすることがあるが、process が生存していれば dispatch 自体は正常に進行している。

### walltime の決め方

- task が CPU を占有できる最大時間。早く終われば release される（課金は実時間ベース）
- 大きいほど安全だが、scheduler は walltime が大きい job を後回しにしやすく queue 待ちが伸びる
- 超過すると問答無用で kill。worst case の 1.5–2 倍を目安に。同 partition 内でもパラメータごとに見積もりが変わるなら **task ごと（あるいは sbatch ごと）に分ける**

### ファイルシステムの使い分け

| Path | 容量 | 永続性 |
|---|---|---|
| `/home/$USER` | 200 GB | 永続。コード・設定・軽量結果 |
| `/project/{group}` | TB 単位（group 共用） | 永続。大データセット |
| `/scratch/$USER` | 500 GB | **60 日 inactive で削除**。計算中間ファイル |

→ 残したい結果は home か project へ。scratch は揮発と意識する。

### Login node のマナー

login node は共用なので CPU/I/O を握るスクリプトを直接走らせない:

- OK: sbatch 投入、`squeue` / `ls` / `tail` などの軽量問い合わせ、軽量 dispatcher、tmux、modules + 単発 `make`
- NG: 数値計算（fit など）、数 GB の rsync、並列 build

重い処理は `srun --account={account} --partition={partition} --pty bash` で interactive job に入る。

### 投入前 preflight checklist

1. `sacctmgr show qos {qos} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall` で QOS 上限を記録
2. `squota -A {account}` で残り CPU-hour 確認
3. ターゲット partition で binary を compile（ISA を partition と一致させる）
4. dispatcher を **dry-run**（sbatch を echo に差し替えて発行回数と中身を確認）
5. 本番起動は **tmux detached session** で

### 接続層の踏みやすい罠（macOS 側）

これらは本 skill が既に対策を組み込んでいるが、症状を知っておくと debug が早い:

1. **macOS の SSH が DNS を解けない**: macOS の `getaddrinfo` は `/etc/resolv.conf` のみを参照する。Ivanti 等の split-tunnel VPN は `scutil` 側にしか DNS を push しないため、`host hpc4.ust.hk` は通るのに `ssh hpc4` だけ "Could not resolve" になる → 本 skill の `ssh_config` は HostName を IP 直指定（`HostKeyAlias` で known_hosts 整合は維持）
2. **キルスイッチ型 VPN が split-tunnel utun の出力を pf で塞ぐ**: NordVPN 等は en0 と utun の両方を pf で塞ぐ。Ivanti モードでも HPC4 宛 utun 経由を許可する pf anchor が要る → `net-up.sh` は en0/Ivanti 両モードで自動的に anchor を入れる
3. **ルートが再起動・スリープで消える**: macOS の host route は永続化されない。スリープ復帰時は `/hpc4 up` を再実行（冪等）
4. **`scp -l` は username ではなく bandwidth limit**: ssh の `-l user` と違い、scp の `-l` は kbps 制限。username は `-o User=...` か `user@host:path` で渡す（本 skill の `xfer.sh` は ssh_config 経由で正しく渡している）

### よく使う運用 1-liner

```bash
# 自分の queue 内訳（job 名で集計）
/hpc4 run 'squeue -u $USER -h -o "%j %T" | sort | uniq -c | sort -rn'

# QOS 上限と使用状況
/hpc4 run 'sacctmgr -n -p show qos {qos_name} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall'

# group の残り quota
/hpc4 run 'squota -A {account}'

# partition の空き
/hpc4 run 'savail'

# tmux + dispatcher log 末尾
/hpc4 run 'tmux list-sessions; tail -20 ~/path/to/log'
```
