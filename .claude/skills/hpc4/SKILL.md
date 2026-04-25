---
name: hpc4
description: "HKUST HPC4 への SSH 接続・リモートコマンド実行・ファイル転送・経路整備を提供する。Claude が文脈から判断して .claude/skills/hpc4/scripts/ 配下の bash script を Bash ツールで直接呼ぶ。ユーザが /hpc4 で対話的に呼ぶことも可。"
user-invocable: true
---

# hpc4 — HKUST HPC4 接続スキル

HKUST HPC4 (`hpc4.ust.hk`) クラスタへの SSH 接続を、Claude 通信と同居させる前提で支援する。

## 背景

Claude (Anthropic API) は香港をサービス対象外としており、一方 HPC4 は HKUST のネットワーク（143.89/16 IP 帯 — オンキャンパスの eduroam / 有線、または HKUST SSL VPN 経由）からしか到達できない。**Claude を使うには香港外を経由する必要があり、HPC4 を使うには HKUST 圏内に居る必要がある**。同じ Mac 上で「Claude 用の経路（NordVPN 等で日本／第三国経由）」と「HPC4 用の経路（HKUST 直結 or Ivanti split-tunnel）」を同居させるのが運用の前提。

この同居は実は VPN 製品（NordVPN, Ivanti 等）が起動時に kernel routing table に書き込む結果として **OS が自然に成立させる**：default route は NordVPN、`143.89/16` connected route は Ivanti、longest-prefix-match で衝突なし。skill 自身は default route や Claude 経路に絶対手を出さず、**HPC4 (143.89.184.3) の host route 1 つだけを管理する**。

## 設計上の不変条件：Claude が落ちている時に user が単独で復旧できる

このスキルが Claude API 経由で動作する以上、**「Claude が unreachable な瞬間こそ user が一番困る」** という catch-22 がある。Claude が落ちている時、user は私に相談できず、terminal だけで状況を把握して action する必要がある。これを設計に直接織り込む：

- **scripts の出力は terminal で直読する前提の日本語**。「Claude が解釈する」前提の verdict 文字列を user に提示しない。
- **scripts は default route や Claude 経路に絶対に触らない**。skill が Claude 接続を巻き添えにする可能性を排除する。
- **L4 で塞がれている時は user の VPN クライアント GUI 操作（out-of-band action）を案内する**。skill 内で workaround を試みない。

## このスキルの位置付け

- **Claude が文脈から判断して `.claude/skills/hpc4/scripts/` 配下の bash script を Bash ツールで直接呼ぶ**のが基本。ユーザが `/hpc4` で対話的に呼ぶことも可だが、それは副経路

## Claude が呼べる scripts

下表の scripts はすべて `bash .claude/skills/hpc4/scripts/<name>.sh [args]` の形で Bash ツールから直接叩ける。**`ssh-run.sh` / `xfer.sh` は内部で host route を自動 pin するので、経路を意識せず目的の操作を直接呼んでよい**。

| script | 引数 | Claude がこれを呼ぶべき場面 |
|---|---|---|
| `status.sh` | なし | HPC4 関連作業の前にざっと健康状態を確認したい時、またはトラブル切り分け時 |
| `ssh-run.sh` | `'<command>'` | HPC4 上で任意コマンドを実行したい時（`squeue`、`sbatch`、`ls`、`cat` 等。経路は自動整備） |
| `xfer.sh` | `put <l> <r>` / `get <r> <l>` | 単一ファイルの往復（スクリプト、小さい結果ファイル等） |
| `xfer.sh` | `put-r <l> <r>` / `get-r <r> <l>` | ディレクトリ単位の rsync 転送（大量結果の引き上げ等） |
| `net-up.sh` | なし | HPC4 host route を pin したい時、または status で TCP 22 不通を発見した時 |
| `net-down.sh` | なし | HPC4 host route と ControlMaster をリセットしたい時（トラブル時のみ） |
| `write-user-conf.sh` | `<itso_username>` | `user.conf.local` を生成したい時（setup フロー A で使う） |

setup フロー（`user.conf.local` 生成 + passwordless SSH 確立）は単一の script ではなく **本ファイル後段の「setup フロー」節** に手順がある。Claude はそれを順に踏む。

### `/hpc4` で起動された時、または Claude が文脈から呼ぶ時の起点

**まず最初に `bash .claude/skills/hpc4/scripts/status.sh` を走らせ**、その出力を見て分岐:

1. `user.conf.local` が無い → ユーザに ITSO 名を聞いて `write-user-conf.sh` で書き出し、もう一度 status.sh から始める
2. `[ng] HPC4 経路：...` → status.sh が出した日本語の指示（「Ivanti Secure Access を起動してください」等）をそのまま提示。修正後に再開するよう案内し、setup を **ここで止める**（ssh-copy-id まで進めない）
3. `[ng] TCP 22 不通` → `bash .claude/skills/hpc4/scripts/net-up.sh` を呼んで host route を pin する。それでも不通なら net-up.sh が出した VPN クライアント設定の指示をそのまま提示
4. ネットワーク `[ok]` + passwordless SSH 未成立 → **setup ステップ C を実行**（`ssh-copy-id` を別ターミナルで打ってもらう案内。これが許容されるのはここだけ）
5. 全部成立している → ユーザが `/hpc4` を直接打った場合は **何をしたいかを 1 文で聞く**（例: 「HPC4 のセットアップは済んでいます。何をしますか？（例: queue 確認 / ジョブ投入 / ファイル転送 / 状態確認）」）。Claude 自律呼び出しの場合は文脈から目的の script を選んで進める

## 動作規約

1. **冪等性**: `net-up.sh` を含むあらゆる script は何度呼んでも壊れない。既に整っていれば no-op で抜ける
2. **触る対象は HPC4 host route ただ 1 つ**: `net-up.sh` も `net-down.sh` も 143.89.184.3 の host route だけを操作する。default route や Claude 経路には絶対に手を出さない
3. **VPN 製品の判別はしない**: kernel に「HPC4 をどの IF に出すか」と聞き、その IF が 143.89/16 IP を持っているかだけで判定する。NordVPN だの Ivanti だの製品名で分岐しない
4. **L4 で塞がれている時は out-of-band action を案内する**: skill 内で workaround を試みず、user の VPN クライアント GUI で 143.89.184.3 を例外設定する手順を terminal 直読の日本語で出す
5. **個人情報の隔離**: ITSO ユーザ名等は `user.conf.local`（gitignored）に閉じる。リポジトリ本体には書かない
6. **シェル操作をユーザに依頼しない（precondition を満たした時だけ依頼）**: 設定値は Claude がチャットで質問し `Write` で書き出す。`cp` や `chmod` をユーザに打たせない。`ssh-copy-id` のように password+2FA が必要なものは別ターミナル依頼が許容されるが、**ネットワーク verdict が ok でない限り依頼しない**
7. **応答は短く**: 結果（ok / err / 要約）だけを返す。冗長な進捗説明は控える

## 対象環境

- **クラスタ**: `hpc4.ust.hk` (143.89.184.3)、Slurm account 既定値 `watanabemc`（user.conf.local で override 可能）
- **クライアント OS**: macOS。Linux/Windows は対応外
- **認証**: 公開鍵認証 (passwordless SSH) + ControlMaster 12h 永続化
- **ネットワーク**: HPC4 (143.89/16) に届く IF が 1 つでもあれば動く。具体的には：オンキャンパス（eduroam / HKUST 有線）、オフキャンパス（Ivanti Secure Access = HKUST SSL VPN）。default route を別 VPN（NordVPN 等）が握っていても、その VPN の kill-switch / packet filter / NEPacketTunnelProvider が 143.89.184.3 行きを遮断していなければ host route で抜けられる

## setup フロー（初回 1 回だけ）

ゴール：**`user.conf.local` を作成し、passwordless SSH が通る状態にする**。ユーザには最大でも「ITSO ユーザ名を答える」「別ターミナルで 1 コマンド打って password+2FA を通す」の 2 アクションのみを依頼する。

**起点は常に `status.sh`**：interface 状態のみで HPC4 への到達性を 0 秒分類してから動く。

### ステップ A. 個人情報の収集と保存

1. `.claude/skills/hpc4/user.conf.local` が既に存在し、`HPC4_USER` が空でないなら、**ステップ A を丸ごとスキップ**してステップ B に進む。
2. 無ければ、ユーザにチャットで直接聞く：「HPC4 の ITSO アカウント名を教えてください（例: `login4` に `ssh` するときの username）」。**候補を ssh config / known_hosts / メールアドレス等から推定しようとしない**。候補は無限にあり、聞いたほうが速く正確。
3. 得られたユーザ名を引数にして `bash .claude/skills/hpc4/scripts/write-user-conf.sh <username>` を実行し、`user.conf.local` を生成。
4. `.gitignore` に `.claude/skills/hpc4/user.conf.local` が含まれているか確認し、未登録なら追記。

### ステップ B. HPC4 への到達性判定（status.sh が起点）

`bash .claude/skills/hpc4/scripts/status.sh` を実行し、出力の各 stage を見て分岐：

- `[ok] HPC4 経路：<iface> 経由で HKUST 圏内` + `[ok] TCP 22 到達 OK` → そのままステップ C へ
- `[ok] HPC4 経路：...` + `[ng] TCP 22 不通` → `bash .claude/skills/hpc4/scripts/net-up.sh` を実行（host route を pin して再判定）
- `[ng] HPC4 経路：<iface> ...は HKUST 圏外（143.89/16 IP を持っていない）` → status.sh が出した日本語の救済文をそのままユーザに伝える（オンキャンパスなら eduroam/HKUST 有線、オフキャンパスなら Ivanti Secure Access）。修正後 `/hpc4` で再開させ、**ssh-copy-id まで進めない**
- `[ng] HPC4 経路：kernel が一切経路を返しません` → 「eduroam / HKUST 有線 / Ivanti のいずれかに接続してください」と伝え、再開待ち

要点：`net-up.sh` は HKUST 圏外の場合は **route add せずに即 exit する**（user に sudo password を求めない）。L4 で塞がれている場合は VPN クライアント GUI 設定の手順を出す。

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

Claude が Bash ツールから叩く際のテンプレート（パスは working directory 起点）：

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

**判定の本質：HPC4 (143.89.184.3) に届く IF が 1 つでもあるか**。製品名（NordVPN / Ivanti / eduroam ...）で分岐しない。kernel に直接聞く。

### アルゴリズム（`net-up.sh` / `status.sh` の core）

1. **既存の HPC4 host pin を一度削除**（stale な pin が判定を歪めないように）
2. **`route get 143.89.184.3` で kernel が選ぶ egress IF を取得**（`hpc4_route_resolve`）
3. **その IF が 143.89/16 の IPv4 を持っているか確認**（`iface_has_hkust_ip`）。これが「HKUST 圏に届く」唯一の証拠
   - 持っていれば → host route で pin（後で他 VPN が default を変えても longest-prefix-match で勝つ）
   - 持っていなければ → kernel は default fallback で別経路に流しているだけで HPC4 には届かない。pin しても無駄なので即終了し、user に「HKUST 圏に入れ」と案内
4. **TCP 22 で疎通テスト**。通れば終わり
5. **L3 OK だが L4 で塞がれている**（VPN クライアントの kill-switch / NEPacketTunnelProvider 等）→ user の VPN GUI で 143.89.184.3 を例外設定する手順を出す

### なぜこれで足りるか

- HKUST の end-user ネット（eduroam / 有線 / Ivanti）は **143.89/16 を直接配布する**ので、IF が 143.89/16 IP を持っているか否かで「HKUST 圏に居るか」を一意に判定できる
- host route は longest-prefix で勝つので、default route が他 VPN に握られていても HPC4 だけは抜ける（製品判別不要）
- L4 遮断の解消は user space からは不可能なので、out-of-band action（VPN GUI 操作）を案内する以外の選択肢はない

SSH 側は ControlMaster で 12h persist、password+2FA は実質 1 日 1 回で済む。

## sudo が必要な操作について

`net-up.sh` と `net-down.sh` は `route` を触るため sudo が要る。Touch ID を有効にしておくと Claude Code の Bash ツールからでも指紋で通る。そうでなければ password 入力ダイアログが 1 回だけ出る。

## トラブル時の当たり方

1. `bash .claude/skills/hpc4/scripts/status.sh` で現状を取り、どの層で落ちているか特定（ネットワーク / 認証 / ControlMaster）
2. `bash .claude/skills/hpc4/scripts/net-up.sh` で経路を再整備（VPN や eduroam を再接続した直後はこれで直ることが多い）
3. `bash .claude/skills/hpc4/scripts/net-down.sh` の後 `net-up.sh` で完全リセット
4. それでも繋がらないなら `ssh -F .claude/skills/hpc4/ssh_config -l <user> -vvv hpc4` を直接叩いて詳細ログを取る

## 新しいメンバーへの引継ぎ

リポジトリを clone した人は `/hpc4` を 1 回走らせれば（または Claude に「HPC4 のセットアップして」と頼めば）setup フローが起動して使える状態になる。事前作業は不要。

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
2. **VPN クライアントの kill-switch が L4 で 143.89.184.3 行きを遮断する**: NEPacketTunnelProvider (`includeAllNetworks=true`) や VPN クライアント独自の packet filter で塞がれる。kernel routing は正しいので skill 側からは復旧不能 → `net-up.sh` が user に「VPN クライアント GUI で 143.89.184.3 を例外設定する」手順を terminal 直読の日本語で出す
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
