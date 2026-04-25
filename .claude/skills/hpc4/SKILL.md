---
name: hpc4
description: "HKUST HPC4 への SSH 接続・リモートコマンド実行・ファイル転送・経路整備を提供する。LLM が文脈から判断して .claude/skills/hpc4/scripts/ 配下の bash script を Bash ツールで直接呼ぶ。ユーザが /hpc4 で対話的に呼ぶことも可。"
user-invocable: true
---

# hpc4 — HKUST HPC4 接続スキル

HKUST HPC4 (`hpc4.ust.hk`) クラスタへのアクセスを、ネットワーク経路（オンキャンパス直結 / HKUST SSL VPN / キルスイッチ型フル VPN）の面倒ごと込みで自動化する。VPN の種類・有無は自動判定するため事前設定は不要。

## このスキルの位置付け

- **LLM が文脈から判断して `.claude/skills/hpc4/scripts/` 配下の bash script を Bash ツールで直接呼ぶ**のが基本。ユーザが `/hpc4` で対話的に呼ぶことも可だが、それは副経路
- **subcommand 機構は無い**。LLM は下表のスクリプトをフルパスで呼ぶ

## LLM が呼べる scripts

下表の scripts はすべて `bash .claude/skills/hpc4/scripts/<name>.sh [args]` の形で Bash ツールから直接叩ける。**`ssh-run.sh` / `xfer.sh` は内部で経路（ルート + pf）を自動整備するので、経路を意識せず目的の操作を直接呼んでよい**。

| script | 引数 | LLM がこれを呼ぶべき場面 |
|---|---|---|
| `status.sh` | なし | HPC4 関連作業の前にざっと健康状態を確認したい時、またはトラブル切り分け時 |
| `ssh-run.sh` | `'<command>'` | HPC4 上で任意コマンドを実行したい時（`squeue`、`sbatch`、`ls`、`cat` 等。経路は自動整備） |
| `xfer.sh` | `put <l> <r>` / `get <r> <l>` | 単一ファイルの往復（スクリプト、小さい結果ファイル等） |
| `xfer.sh` | `put-r <l> <r>` / `get-r <r> <l>` | ディレクトリ単位の rsync 転送（大量結果の引き上げ等） |
| `net-up.sh` | なし | 経路だけ整えて接続テストしたい時、または status で経路欠落を発見した時 |
| `net-down.sh` | なし | 経路や pf anchor を完全リセットしたい時（トラブル時のみ） |
| `write-user-conf.sh` | `<itso_username>` | `user.conf.local` を生成したい時（setup フロー A で使う） |

setup フロー（`user.conf.local` 生成 + passwordless SSH 確立）は単一の script ではなく **本ファイル後段の「setup フロー」節** に手順がある。LLM はそれを順に踏む。

### `/hpc4` で起動された時、または LLM が文脈から呼ぶ時の起点

**まず最初に `bash .claude/skills/hpc4/scripts/status.sh` を走らせ**、その出力を見て分岐:

1. `user.conf.local` が無い → ユーザに ITSO 名を聞いて `write-user-conf.sh` で書き出し、もう一度 status.sh から始める
2. ネットワーク verdict が `[ng] ...` → **status.sh の救済アクション文をそのまま提示**（例：「Ivanti Secure Access を起動するか eduroam/HKUST 有線に接続してください」）。修正後に再開するよう案内し、setup を **ここで止める**（ssh-copy-id まで進めない）
3. ネットワーク verdict が `[ok]` + passwordless SSH 未成立 → **setup ステップ C を実行**（`ssh-copy-id` を別ターミナルで打ってもらう案内。これが許容されるのはここだけ）
4. 全部成立している → ユーザが `/hpc4` を直接打った場合は **何をしたいかを 1 文で聞く**（例: 「HPC4 のセットアップは済んでいます。何をしますか？（例: queue 確認 / ジョブ投入 / ファイル転送 / 状態確認）」）。LLM 自律呼び出しの場合は文脈から目的の script を選んで進める

## 動作規約

1. **冪等性**: `net-up.sh` を含むあらゆる script は何度呼んでも壊れない。既に整っていれば no-op で抜ける
2. **原因ベース判定を先に**: ネットワーク状態は **interface 状態（en0 IP / Ivanti utun / default route）から HPC4 への到達性を分類**してから動く。`classify_network`（common.sh）が 0 秒で verdict を出すので、NG が確定する状態では権限操作も probe も走らせず即誘導する
3. **必要最小限の介入**: verdict が ok の時のみ実介入（`net-up.sh` の route 追加 / pf anchor）に進む
4. **個人情報の隔離**: ITSO ユーザ名等は `user.conf.local`（gitignored）に閉じる。リポジトリ本体には書かない
5. **シェル操作をユーザに依頼しない（precondition を満たした時だけ依頼）**: 設定値は LLM がチャットで質問し `Write` で書き出す。`cp` や `chmod` をユーザに打たせない。`ssh-copy-id` のように password+2FA が必要なものは別ターミナル依頼が許容されるが、**ネットワーク verdict が ok でない限り依頼しない**
6. **応答は短く**: 結果（ok / err / 要約）だけを返す。冗長な進捗説明は控える

## 対象環境

- **クラスタ**: `hpc4.ust.hk` (143.89.184.3)、Slurm account 既定値 `watanabemc`（user.conf.local で override 可能）
- **クライアント OS**: macOS。Linux/Windows は対応外
- **認証**: 公開鍵認証 (passwordless SSH) + ControlMaster 12h 永続化
- **ネットワーク**: オンキャンパス（eduroam / HKUST 有線）、オフキャンパス（Ivanti Secure Access = HKUST SSL VPN）、キルスイッチ型フル VPN（NordVPN / SurfShark / ExpressVPN / Proton / Mullvad 等）と共存可能

## setup フロー（初回 1 回だけ）

ゴール：**`user.conf.local` を作成し、passwordless SSH が通る状態にする**。ユーザには最大でも「ITSO ユーザ名を答える」「別ターミナルで 1 コマンド打って password+2FA を通す」の 2 アクションのみを依頼する。

**起点は常に `status.sh`**：interface 状態のみで HPC4 への到達性を 0 秒分類してから動く。

### ステップ A. 個人情報の収集と保存

1. `.claude/skills/hpc4/user.conf.local` が既に存在し、`HPC4_USER` が空でないなら、**ステップ A を丸ごとスキップ**してステップ B に進む。
2. 無ければ、ユーザにチャットで直接聞く：「HPC4 の ITSO アカウント名を教えてください（例: `login4` に `ssh` するときの username）」。**候補を ssh config / known_hosts / メールアドレス等から推定しようとしない**。候補は無限にあり、聞いたほうが速く正確。
3. 得られたユーザ名を引数にして `bash .claude/skills/hpc4/scripts/write-user-conf.sh <username>` を実行し、`user.conf.local` を生成。
4. `.gitignore` に `.claude/skills/hpc4/user.conf.local` が含まれているか確認し、未登録なら追記。

### ステップ B. HPC4 への到達性判定（status.sh が起点）

`bash .claude/skills/hpc4/scripts/status.sh` を実行し、`HPC4 到達性:` 行の verdict で分岐：

- `[ok] HPC4 到達性: 同 LAN 直結` または `[ok] HPC4 到達性: split-tunnel VPN 経由` → そのままステップ C へ。route 追加が要るケース（HPC4 ルート未設定）は `bash .claude/skills/hpc4/scripts/net-up.sh` を呼ぶ
- `[ng] HPC4 到達性: 不通 ...` → status.sh が出した救済文をそのままユーザに伝える（「Ivanti Secure Access を起動するか eduroam/HKUST 有線に接続してください」）。修正後 `/hpc4` で再開させ、**ssh-copy-id まで進めない**
- `[ng] HPC4 到達性: 経路候補なし` → 「eduroam / HKUST 有線 / Ivanti のいずれかに接続してください」と伝え、再開待ち
- `[ng] HPC4 到達性: default route が他 VPN に奪取` → `bash .claude/skills/hpc4/scripts/net-up.sh` を実行して pf anchor を注入

要点：`net-up.sh` も先頭で同じ `classify_network` を呼び、不通/no-route の場合は **即 exit する**。user に sudo password を求めない。

### ステップ C. passwordless SSH の確認

**前提：ステップ B のネットワーク verdict が `[ok]` であること**。NG のまま進めない。

1. status.sh の `passwordless SSH` 行を見る。
2. **既に成立している場合** は何もしない（ユーザへの依頼なし）。成立メッセージだけ返す。
3. **未成立の場合** は以下を 1 回だけ提示：
   - 秘密鍵がなければ `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519` を自動実行してよい（BatchMode 可）
   - `ssh-copy-id -i ~/.ssh/id_ed25519.pub <HPC4_USER>@hpc4.ust.hk` を「別ターミナルで 1 回だけ実行してください（password + 2FA の入力が必要）」と案内
   - 完了したらチャットで知らせてもらい、再度 status.sh で成立確認
4. 成立したら setup 完了メッセージを出す。

### ステップ D. 動作確認

`bash .claude/skills/hpc4/scripts/ssh-run.sh 'hostname && whoami'` を走らせて、`login{N}` と自分の username が返ってくることを確認。

## 典型的な呼び出しパターン

LLM が Bash ツールから叩く際のテンプレート（パスは working directory 起点）：

```bash
# 状態確認
bash .claude/skills/hpc4/scripts/status.sh

# クラスタ状態の問い合わせ
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squeue -u $USER'      # 自分のキュー状況
bash .claude/skills/hpc4/scripts/ssh-run.sh 'savail'               # パーティション空き
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squota -A {account}'  # group quota

# ジョブ投入の往復
bash .claude/skills/hpc4/scripts/xfer.sh put job.sh /scratch/$USER/job.sh
bash .claude/skills/hpc4/scripts/ssh-run.sh 'cd /scratch/$USER && sbatch job.sh'
bash .claude/skills/hpc4/scripts/xfer.sh get-r /scratch/$USER/results results/
```

## ネットワーク層の仕組み（要点のみ）

**判定の本質：HPC4 (143.89.184.3) に届くか**。HKUST 所属かどうかではない。
HPC4 は 143.89/16 にいるので、自分が同 /16 にいる、もしくは tunnel で 143.89/16 に出られるなら届く。それ以外は届かない。これは **interface 状態だけで 0 秒で確定**できる。

### `classify_network`（common.sh）の判定順

**判定は 2 段階**：まず「HPC4 へ届く下回り経路があるか」を見る（en0 が 143.89/16 / Ivanti utun に 143.89.* IP）。下回りが無ければ pf anchor では救えないので no-reach 確定。下回りがある時に限り、フル VPN によるキルスイッチで pf 遮断されているかを見る。

| # | 条件 | verdict | 取るべき行動 |
|---|---|---|---|
| 1a | en0 IP が **143.89/16**（HPC4 と同 /16）+ フル VPN なし | `ok:lan-reach` | そのまま使う / 必要なら `route add -host` |
| 1b | en0 IP が **143.89/16** + フル VPN が default を奪取 | `ng:fullvpn-hijack` | `bash .claude/skills/hpc4/scripts/net-up.sh` で pf anchor `main/hpc4` 注入 |
| 2a | Ivanti utun に **143.89.\*** IP + フル VPN なし | `ok:vpn-tunnel` | split-tunnel 経由 / 必要なら `route add -host -interface` |
| 2b | Ivanti utun に **143.89.\*** IP + フル VPN が default を奪取 | `ng:fullvpn-hijack` | `bash .claude/skills/hpc4/scripts/net-up.sh` で pf anchor `main/hpc4` 注入 |
| 3 | en0 ゲートウェイも Ivanti も無い | `ng:no-route` | eduroam / 有線 / Ivanti のいずれかに接続するよう案内 |
| 4 | en0 はあるが HKUST 圏外 + Ivanti 無し（フル VPN の有無は無関係） | `ng:no-reach` | Ivanti 起動 or 学内ネット切替を案内（pf anchor では救えない） |

ポイント：
- HKUST の end-user ネット（eduroam / 有線 / Ivanti）は **143.89/16 を直接配布する**。よって en0 が 143.89/16 でない && Ivanti utun も無い → HKUST 外ネット → HPC4 不通、と確定できる
- 全ケース probe 不要で **0 秒判定**
- **fullvpn-hijack 判定は下回りがある時のみ出す**。en0 がホットスポット等の HKUST 圏外の時は、フル VPN を止めても en0 自身が HPC4 へ届く経路を持たないので no-reach に倒す。逆に下回り（en0 on HKUST or Ivanti）がある時は kernel が longest-prefix で 143.89/16 を connected route に流すが、フル VPN の pf が en0/utun の出力を塞ぐので anchor 例外が要る
- フル VPN（ケース 1b/2b）の対象は NordVPN / SurfShark / ExpressVPN / Proton / Mullvad などキルスイッチ型。Ivanti は split-tunnel なので `fullvpn_default_route` の対象外

SSH 側は ControlMaster で 12h persist、password+2FA は実質 1 日 1 回で済む。

## sudo が必要な操作について

`net-up.sh` と `net-down.sh` は `route` と `pfctl` を触るため sudo が要る。Touch ID を有効にしておくと Claude Code の Bash ツールからでも指紋で通る。そうでなければ password 入力ダイアログが 1 回だけ出る。

## トラブル時の当たり方

1. `bash .claude/skills/hpc4/scripts/status.sh` で現状を取り、どの層で落ちているか特定（ネットワーク / 認証 / ControlMaster）
2. `bash .claude/skills/hpc4/scripts/net-up.sh` で経路を再整備（VPN や eduroam を再接続した直後はこれで直ることが多い）
3. `bash .claude/skills/hpc4/scripts/net-down.sh` の後 `net-up.sh` で完全リセット
4. それでも繋がらないなら `ssh -F .claude/skills/hpc4/ssh_config -l <user> -vvv hpc4` を直接叩いて詳細ログを取る

## 新しいメンバーへの引継ぎ

リポジトリを clone した人は `/hpc4` を 1 回走らせれば（または LLM に「HPC4 のセットアップして」と頼めば）setup フローが起動して使える状態になる。事前作業は不要。

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
bash .claude/skills/hpc4/scripts/ssh-run.sh 'tmux new-session -d -s {name} "bash dispatcher.sh > log 2>&1"'
# 復帰時
bash .claude/skills/hpc4/scripts/ssh-run.sh 'tmux list-sessions; tail -20 log'
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
3. **ルートが再起動・スリープで消える**: macOS の host route は永続化されない。スリープ復帰時は `bash .claude/skills/hpc4/scripts/net-up.sh` を再実行（冪等）
4. **`scp -l` は username ではなく bandwidth limit**: ssh の `-l user` と違い、scp の `-l` は kbps 制限。username は `-o User=...` か `user@host:path` で渡す（本 skill の `xfer.sh` は ssh_config 経由で正しく渡している）

### よく使う運用 1-liner

すべて `bash .claude/skills/hpc4/scripts/ssh-run.sh '<HPC4 上で実行する 1 行>'` の形：

```bash
# 自分の queue 内訳（job 名で集計）
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squeue -u $USER -h -o "%j %T" | sort | uniq -c | sort -rn'

# QOS 上限と使用状況
bash .claude/skills/hpc4/scripts/ssh-run.sh 'sacctmgr -n -p show qos {qos_name} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall'

# group の残り quota
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squota -A {account}'

# partition の空き
bash .claude/skills/hpc4/scripts/ssh-run.sh 'savail'

# tmux + dispatcher log 末尾
bash .claude/skills/hpc4/scripts/ssh-run.sh 'tmux list-sessions; tail -20 ~/path/to/log'
```
