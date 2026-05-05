---
name: hpc4
description: "HKUST HPC4 への SSH 接続・リモートコマンド実行・ファイル転送・経路整備を提供する。Claude が文脈から判断して .codex/skills/hpc4/scripts/ 配下の bash script を Bash ツールで直接呼ぶ。ユーザが /hpc4 で対話的に呼ぶことも可。"
user-invocable: true
---

# hpc4 — HKUST HPC4 接続スキル

HKUST HPC4 (`hpc4.ust.hk`) クラスタへの SSH 接続を、Claude 通信と同居させる前提で支援する。

## 背景

Claude (Anthropic API) は香港をサービス対象外としており、一方 HPC4 は HKUST 内部 network（有線 / Ivanti の `143.89/16`、または HKUST キャンパス eduroam の `10.79/16` NAT）からしか到達できない。**Claude を使うには香港外を経由する必要があり、HPC4 を使うには HKUST 圏内に居る必要がある**。同じ Mac 上で「Claude 用の経路（NordVPN 等で日本／第三国経由）」と「HPC4 用の経路（HKUST eduroam 直結 / 有線 / Ivanti split-tunnel）」を同居させるのが運用の前提。

この同居は実は VPN 製品（NordVPN, Ivanti 等）が起動時に kernel routing table に書き込む結果として **OS が自然に成立させる**：default route は NordVPN、`143.89/16` connected route は Ivanti、longest-prefix-match で衝突なし。skill 自身は default route や Claude 経路に絶対手を出さず、**HPC4 (143.89.184.3) の host route 1 つだけを管理する**。

ITSO 公式の HPC4 接続規約（オンキャンパス eduroam/有線 vs オフキャンパス Ivanti SSL VPN、eduroam の federated 性質、認証方法等）の正確な文言と出典は [policy.md](policy.md) を参照。SKILL.md は運用最小限のみを書く。

## 設計上の不変条件：Claude が落ちている時に user が単独で復旧できる

このスキルが Claude API 経由で動作する以上、**「Claude が unreachable な瞬間こそ user が一番困る」** という catch-22 がある。Claude が落ちている時、user は私に相談できず、terminal だけで状況を把握して action する必要がある。これを設計に直接織り込む：

- **scripts の出力は terminal で直読する前提の日本語**。「Claude が解釈する」前提の verdict 文字列を user に提示しない。
- **scripts は default route や Claude 経路に絶対に触らない**。skill が Claude 接続を巻き添えにする可能性を排除する。
- **L4 で塞がれている時は skill 内で workaround を試みず、terminal 直読の手順だけを出す**。NordVPN 系 helper が pf main ruleset に書く `block drop all` は anchor 経由 pass quick では貫通できないことが判明したため、skill 側からの自動回復は諦め、user に `sudo pfctl -F rules` を提示する（過去の `com.apple/hpc4` anchor 戦略は撤去済み）。

## このスキルの位置付け

- **Claude が文脈から判断して `.codex/skills/hpc4/scripts/` 配下の bash script を Bash ツールで直接呼ぶ**のが基本。ユーザが `/hpc4` で対話的に呼ぶことも可だが、それは副経路

## Claude が呼べる scripts

下表の scripts はすべて `bash .codex/skills/hpc4/scripts/<name>.sh [args]` の形で Bash ツールから直接叩ける。**`ssh-run.sh` / `xfer.sh` は ping が通れば直接 ssh、通らなければ `net-up.sh` を呼んで経路を診断する**ので、経路 OK のときは経路を意識せず目的の操作を直接呼んでよい。`net-up.sh` が user による sudo を要求した場合は exit 3 で抜けるので、その場合のみ `net-up-local.sh` を user の Terminal で実行してもらう。

| script | 引数 | Claude がこれを呼ぶべき場面 |
|---|---|---|
| `status.sh` | なし | HPC4 関連作業の前にざっと健康状態を確認したい時、またはトラブル切り分け時 |
| `ssh-run.sh` | `'<command>'` | HPC4 上で任意コマンドを実行したい時（`squeue`、`sbatch`、`ls`、`cat` 等。経路は自動整備） |
| `xfer.sh` | `put <l> <r>` / `get <r> <l>` | 単一ファイルの往復（スクリプト、小さい結果ファイル等） |
| `xfer.sh` | `put-r <l> <r>` / `get-r <r> <l>` | ディレクトリ単位の rsync 転送（大量結果の引き上げ等） |
| `net-up.sh` | なし | 経路を診断したい時、status で TCP 22 不通を発見した時。AI 実行では sudo しない |
| `net-up-local.sh` | なし | route / pf 操作に sudo が必要な時に、user が自分の Terminal で実行する helper |
| `net-down.sh` | なし | HPC4 host route と ControlMaster をリセットしたい時（トラブル時のみ）。route 削除は user 委任、ControlMaster close は自動実行 |
| `write-user-conf.sh` | `<itso_username>` | `user.conf.local` を生成したい時（setup フロー A で使う） |

setup フロー（`user.conf.local` 生成 + passwordless SSH 確立）は単一の script ではなく **本ファイル後段の「setup フロー」節** に手順がある。Claude はそれを順に踏む。

### `/hpc4` で起動された時、または Claude が文脈から呼ぶ時の起点

**まず最初に `bash .codex/skills/hpc4/scripts/status.sh` を走らせ**、その出力を見て分岐:

1. `user.conf.local` が無い → ユーザに ITSO 名を聞いて `write-user-conf.sh` で書き出し、もう一度 status.sh から始める
2. `[ng] HKUST 圏内 IF なし` → status.sh が出した日本語の指示（「HKUST キャンパス内 eduroam か HKUST 有線、またはオフキャンパスなら Ivanti Secure Access を起動してください」）をそのまま提示。修正後に再開するよう案内し、setup を **ここで止める**（ssh-copy-id まで進めない）
3. `[ng] HPC4 host route：... stale pin` または `[ng] HPC4 egress：... HKUST 圏外` → user に `bash .codex/skills/hpc4/scripts/net-up-local.sh` を別ターミナルで実行してもらう。完了したら status.sh から再開
4. `[ng] TCP 22 不通` → `bash .codex/skills/hpc4/scripts/net-up.sh` を呼んで詳細診断する。最有力は NordVPN 系の pf `block drop all` で、`sudo pfctl -F rules` を user に依頼する案内が出る
5. ネットワーク `[ok]` + passwordless SSH 未成立 → **setup ステップ C を実行**（`ssh-copy-id` を別ターミナルで打ってもらう案内）
6. 全部成立している → ユーザが `/hpc4` を直接打った場合は **何をしたいかを 1 文で聞く**（例: 「HPC4 のセットアップは済んでいます。何をしますか？（例: queue 確認 / ジョブ投入 / ファイル転送 / 状態確認）」）。Claude 自律呼び出しの場合は文脈から目的の script を選んで進める

## 動作規約

1. **冪等性**: あらゆる script は何度呼んでも壊れない。既に整っていれば no-op で抜ける
2. **触る対象は HPC4 宛トラフィックだけ**: 操作対象は (a) 143.89.184.3 の host route と (b) HPC4 宛だけ pass する pf anchor `main/hpc4` の 2 つに限定。どちらも実行は user 委任。default route や Claude 経路には絶対に手を出さない
3. **VPN 製品の判別はしない**: ifconfig で「HKUST 内部 IPv4（`143.89/16` または HKUST eduroam の `10.79/16`）を持つ IF があるか」だけで判定する。NordVPN だの Ivanti だの製品名で分岐しない
4. **L4 で塞がれている時の対応は kill-switch 系 VPN 検出に応じて分岐**:
   - default route が POINTOPOINT な非HKUST IF（NordVPN / SurfShark / Proton 等の症状）に握られている → pf anchor `main/hpc4` で `pass out quick on <egress> ... to 143.89.184.3` を入れて貫通させるため、user に `net-up-local.sh` を Terminal で実行してもらう
   - pf anchor 適用後も TCP 22 が通らない、または kill-switch 系の徴候がないのに L4 で塞がれている → skill 内で workaround を試みず、user space から復旧不能として止める
5. **個人情報の隔離**: ITSO ユーザ名等は `user.conf.local`（gitignored）に閉じる。リポジトリ本体には書かない
6. **sudo は user Terminal helper に委任**: AI が直接呼ぶ scripts は sudo prompt を扱わない。route / pf 操作が必要な時は user に `bash .codex/skills/hpc4/scripts/net-up-local.sh` を自分の Terminal で実行してもらう。Claude Code 配下では sudo password / Touch ID prompt が silent fail し、呼び出し側が「成功した」と誤認する事故が起きるため
7. **シェル操作をユーザに依頼しない（precondition を満たした時だけ依頼）**: 設定値は Claude がチャットで質問し `Write` で書き出す。`cp` や `chmod` をユーザに打たせない。`ssh-copy-id` や `sudo route` のように特権/対話が必要なものは別ターミナル依頼が許容されるが、**ネットワーク verdict が ok でない限り認証系の依頼はしない**。また、別ターミナル依頼で渡す bash コマンドは必ず**絶対パス**で書く（user の新しいシェルは `~` で始まるためプロジェクト相対パスでは No such file になる）。各 script は出力時点で `${SKILL_DIR}` を絶対化済みなので、status.sh / net-up.sh の出力をそのまま転送するのが安全
8. **応答は短く**: 結果（ok / err / 要約）だけを返す。冗長な進捗説明は控える

## 対象環境

- **クラスタ**: `hpc4.ust.hk` (143.89.184.3)、Slurm account 既定値 `watanabemc`（user.conf.local で override 可能）
- **クライアント OS**: macOS。Linux/Windows は対応外
- **認証**: 公開鍵認証 (passwordless SSH) + ControlMaster 12h 永続化
- **ネットワーク**: HKUST 内部 IPv4（有線 / Ivanti の `143.89/16`、または HKUST キャンパス eduroam の `10.79/16`）を持つ IF が 1 つでもあれば動く。具体的には：HKUST キャンパス内 eduroam、HKUST 有線、Ivanti Secure Access (HKUST SSL VPN)。**HKUST 以外の eduroam（DT Hub 等の HKSTP 施設、他大学、空港）は対象外** — 同じ SSID で繋がるが HKUST 内部 IP は降ってこない（[policy.md](policy.md) 参照）。default route を別 VPN（NordVPN 等）が握っていても、その VPN の kill-switch / packet filter / NEPacketTunnelProvider が 143.89.184.3 行きを遮断していなければ HPC4 だけは抜けられる

## setup フロー（初回 1 回だけ）

ゴール：**`user.conf.local` を作成し、passwordless SSH が通る状態にする**。ユーザには最大でも「ITSO ユーザ名を答える」「別ターミナルで 1 コマンド打って password+2FA を通す」の 2 アクションのみを依頼する。

**起点は常に `status.sh`**：interface 状態のみで HPC4 への到達性を 0 秒分類してから動く。

### ステップ A. 個人情報の収集と保存

1. `.codex/skills/hpc4/user.conf.local` が既に存在し、`HPC4_USER` が空でないなら、**ステップ A を丸ごとスキップ**してステップ B に進む。
2. 無ければ、ユーザにチャットで直接聞く：「HPC4 の ITSO アカウント名を教えてください（例: `login4` に `ssh` するときの username）」。**候補を ssh config / known_hosts / メールアドレス等から推定しようとしない**。候補は無限にあり、聞いたほうが速く正確。
3. 得られたユーザ名を引数にして `bash .codex/skills/hpc4/scripts/write-user-conf.sh <username>` を実行し、`user.conf.local` を生成。
4. `.gitignore` に `.codex/skills/hpc4/user.conf.local` が含まれているか確認し、未登録なら追記。

### ステップ B. HPC4 への到達性判定（status.sh が起点）

`bash .codex/skills/hpc4/scripts/status.sh` を実行し、出力の各 stage を見て分岐：

- `[ok] HKUST 圏内 IF：...` + `[ok] HPC4 経路：...` + `[ok] TCP 22 到達 OK` → そのままステップ C へ
- `[ng] HKUST 圏内 IF なし` → status.sh が出した日本語の救済文をそのままユーザに伝える（HKUST キャンパス内 eduroam / 有線、またはオフキャンパスなら Ivanti Secure Access）。修正後 `/hpc4` で再開させ、**ssh-copy-id まで進めない**
- `[ng] HPC4 host route：... stale pin` → user に `bash .codex/skills/hpc4/scripts/net-up-local.sh` を別ターミナルで実行してもらう。完了したら再開
- `[ng] HPC4 egress：... HKUST 圏外` → user に `bash .codex/skills/hpc4/scripts/net-up-local.sh` を別ターミナルで実行してもらう。完了したら再開
- `[ng] TCP 22 不通` → `bash .codex/skills/hpc4/scripts/net-up.sh` で詳細診断。pf anchor で復旧できない L4 遮断の場合は user space から復旧不能として止める

要点：AI が直接呼ぶ scripts は sudo prompt を扱わない。route / pf 変更が必要な時は user Terminal 専用 helper に委任する。

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

`bash .codex/skills/hpc4/scripts/ssh-run.sh 'hostname && whoami'` を走らせて、`login{N}` と自分の username が返ってくることを確認。

## 典型的な呼び出しパターン

Claude が Bash ツールから叩く際のテンプレート（パスは working directory 起点）：

```bash
# 状態確認
bash .codex/skills/hpc4/scripts/status.sh

# クラスタ状態の問い合わせ
bash .codex/skills/hpc4/scripts/ssh-run.sh 'squeue -u $USER'      # 自分のキュー状況
bash .codex/skills/hpc4/scripts/ssh-run.sh 'savail'               # パーティション空き
bash .codex/skills/hpc4/scripts/ssh-run.sh 'squota -A {account}'  # group quota

# ジョブ投入の往復
bash .codex/skills/hpc4/scripts/xfer.sh put job.sh /scratch/$USER/job.sh
bash .codex/skills/hpc4/scripts/ssh-run.sh 'cd /scratch/$USER && sbatch job.sh'
bash .codex/skills/hpc4/scripts/xfer.sh get-r /scratch/$USER/results results/
```

## ネットワーク層の仕組み（要点のみ）

**判定の本質：HKUST 内部 IPv4（`143.89/16` または HKUST eduroam の `10.79/16`）を持つ IF がこの Mac に 1 つでもあるか**。製品名（NordVPN / Ivanti / eduroam ...）で分岐しない。ifconfig を直接読む。

### アルゴリズム（`net-up.sh` / `status.sh` 共通の core）

1. **`find_hkust_iface`：ifconfig を全 IF 走査して HKUST 内部 IPv4（`143.89/16` または HKUST eduroam の `10.79/16`）を持つ IF を探す** — routing と独立した「HKUST 圏内能力」の判定。stale な host pin が `route get` を歪めても、ここは騙されない
   - 無ければ → 「HKUST 圏に入れ」（HKUST キャンパス eduroam / 有線 / Ivanti）。pin 操作は無駄なので即終了
2. **stale pin 検出**：`current_hpc4_iface` で既存の host pin を見て、HKUST 圏外 IF を指していたら → user に `net-up-local.sh` を実行してもらい削除。stale pin 起因の誤診断と「圏外」を別 path で報告するのが key
3. **`route get 143.89.184.3` で kernel の自然な egress を見る** — HKUST 圏外 IF を選んでいる稀ケースなら user に `net-up-local.sh` を実行してもらい host route を追加
4. **TCP 22 で疎通テスト**。通れば終わり
5. **L3 OK だが L4 で塞がれている**（VPN クライアントの kill-switch / NEPacketTunnelProvider 等）→ pf anchor で復旧できなければ user space から復旧不能として止める

### なぜこれで足りるか

- HKUST の end-user ネットは HKUST 内部 IPv4 を直接配布する（有線 / Ivanti は `143.89/16`、HKUST キャンパス eduroam は内部 NAT pool の `10.79/16`）。IF がそのいずれかの IPv4 を持っているか否かで「HKUST 圏に居るか」を一意に判定できる。federated eduroam（DT Hub 等）はここで自動的に弾かれる（その施設の NAT が降ってくるだけで、HKUST 内部 IP は降ってこない）
- Ivanti 起動時に kernel が自動で `143.89/16 → utun` の subnet route を入れるので、典型的には host pin 無しでも HPC4 に届く。pin が必要になるのは何かが natural route を阻害している場合のみ
- pf anchor で復旧できない L4 遮断の解消は user space からは不可能なので、skill 側では追加の回避策を提示しない

SSH 側は ControlMaster で 12h persist、password+2FA は実質 1 日 1 回で済む。

## sudo が必要な操作について

AI が直接呼ぶ scripts は sudo prompt を扱わない。route / pf 操作（add / delete / anchor 適用）が必要な時は、scripts が `bash .codex/skills/hpc4/scripts/net-up-local.sh` を案内するので、user が自分の Terminal でそれを実行する。

なぜ AI 実行中の sudo を避けるか：Claude Code / Codex の Bash 実行では sudo password / Touch ID prompt が user に届かない、または入力できない。route / pf 操作は user Terminal helper に委任することで、AI が落ちている時でも user が terminal だけで完結できる設計になる。

## トラブル時の当たり方

1. `bash .codex/skills/hpc4/scripts/status.sh` で現状を取り、どの層で落ちているか特定（ネットワーク / 認証 / ControlMaster）
2. `bash .codex/skills/hpc4/scripts/net-up.sh` で経路を診断。sudo が必要なら user に `bash .codex/skills/hpc4/scripts/net-up-local.sh` を実行してもらう
3. `bash .codex/skills/hpc4/scripts/net-down.sh` の後 `net-up.sh` で完全リセット
4. それでも繋がらないなら `ssh -F .codex/skills/hpc4/ssh_config -l <user> -vvv hpc4` を直接叩いて詳細ログを取る

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
bash .codex/skills/hpc4/scripts/ssh-run.sh 'tmux new-session -d -s {name} "bash dispatcher.sh > log 2>&1"'
# 復帰時
bash .codex/skills/hpc4/scripts/ssh-run.sh 'tmux list-sessions; tail -20 log'
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
2. **VPN クライアントの kill-switch が L4 で 143.89.184.3 行きを遮断する**: NEPacketTunnelProvider (`includeAllNetworks=true`) や VPN クライアント独自の packet filter で塞がれる。kernel routing は正しいので、pf anchor でも復旧できない場合は skill 側からは復旧不能
3. **ルートが再起動・スリープで消える**: macOS の host route は永続化されない。スリープ復帰時は `bash .codex/skills/hpc4/scripts/net-up.sh` を再実行（冪等）
4. **`scp -l` は username ではなく bandwidth limit**: ssh の `-l user` と違い、scp の `-l` は kbps 制限。username は `-o User=...` か `user@host:path` で渡す（本 skill の `xfer.sh` は ssh_config 経由で正しく渡している）

### よく使う運用 1-liner

すべて `bash .codex/skills/hpc4/scripts/ssh-run.sh '<HPC4 上で実行する 1 行>'` の形：

```bash
# 自分の queue 内訳（job 名で集計）
bash .codex/skills/hpc4/scripts/ssh-run.sh 'squeue -u $USER -h -o "%j %T" | sort | uniq -c | sort -rn'

# QOS 上限と使用状況
bash .codex/skills/hpc4/scripts/ssh-run.sh 'sacctmgr -n -p show qos {qos_name} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall'

# group の残り quota
bash .codex/skills/hpc4/scripts/ssh-run.sh 'squota -A {account}'

# partition の空き
bash .codex/skills/hpc4/scripts/ssh-run.sh 'savail'

# tmux + dispatcher log 末尾
bash .codex/skills/hpc4/scripts/ssh-run.sh 'tmux list-sessions; tail -20 ~/path/to/log'
```
