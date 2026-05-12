# hpc4 skill

**English** | [日本語](README.ja.md)

A Claude Code / Codex Desktop skill that automates SSH / command execution / file transfer to the HKUST HPC4 cluster, including all the network-routing fiddly bits. You invoke it the same way regardless of where the Mac is — on-campus, off-campus with the HKUST SSL VPN, or with another full VPN running alongside it.

## Background

Claude (the Anthropic API) treats Hong Kong as an unsupported region, while HPC4 (`hpc4.ust.hk`) is only reachable from HKUST's network (the 143.89/16 range — on-campus eduroam / wired, or via the HKUST SSL VPN). **To use Claude you have to leave Hong Kong; to use HPC4 you have to be inside HKUST.** The same split-network problem also appears in Codex Desktop when its sandboxed execution sees false negatives. The reason this skill exists is to resolve that dilemma by **letting AI-agent traffic and HPC4 traffic coexist on the same Mac**. The exact combination differs per environment, and the skill figures out the routing automatically.

## Install

The repo contains both Claude Code and Codex Desktop skill layouts:

- Claude Code: `.claude/skills/hpc4/`
- Codex Desktop: `.codex/skills/hpc4/`

For Claude Code, drop `hpc4/` where Claude looks for skills. Two scopes to choose from:

- **User-wide**: `~/.claude/skills/hpc4/` — `/hpc4` works in every project
- **Project-only**: `<project>/.claude/skills/hpc4/` — limited to that project

For Codex Desktop, keep the project-local `.codex/skills/hpc4/` folder in the repo. Codex discovers it as a project skill.

### 1. Get the ZIP

Click **Code** → **Download ZIP** at the top right of the repo, then unzip (skip if your OS auto-unzips).

### 2. Place it (Finder or terminal)

**Finder**: `Cmd+Shift+.` to show hidden folders. For Claude Code, drag `HPC4-main/.claude/skills/hpc4/` from inside the unzipped archive into `.claude/skills/` under your home directory or your project root. For Codex Desktop, use a clone of this repo so `.codex/skills/hpc4/` stays project-local.

**Terminal**: paste these in order.

```bash
cd ~
```
> Assumes user-wide. For project-only, `cd <path-to-project>`.
> Dragging a folder from Finder into the terminal inserts its absolute path.

```bash
mkdir -p .claude/skills && mv ~/Downloads/HPC4-main/.claude/skills/hpc4 .claude/skills/
```

> Assumes the download landed in `~/Downloads`.

---

## Usage

**Just type `/hpc4` in chat.** If not yet set up, the setup flow runs and asks for what it needs. If already set up, it asks what you want to do — answer in plain English (or Japanese).

First-time setup needs at most two manual actions from you:
1. Tell Claude your ITSO username (in chat).
2. Run `ssh-copy-id` once in a separate terminal (clears password + 2FA).

After that, ControlMaster caches the SSH session for 12 hours, so no more passwords.

Once set up, you don't even need `/hpc4` — just ask in chat normally and Claude/Codex handles routing, command execution, and file transfer behind the scenes. Examples:

- "Show me my queue on HPC4."
- "Upload this directory to `/scratch/$USER/` on HPC4 and submit it with `sbatch run.sh`."
- "Pull the logs from HPC4 and summarize them."
- "I can't reach HPC4 anymore — diagnose it."

You don't need to remember any commands.

### About sudo

Claude/Codex do not accept your macOS password in chat, and they should not wait on an interactive `sudo` prompt. If local route or pf changes are needed, the AI-run script stops and asks you to run the local helper in your own Terminal:

```bash
bash .claude/skills/hpc4/scripts/net-up-local.sh   # Claude layout
bash .codex/skills/hpc4/scripts/net-up-local.sh    # Codex layout
```

After the helper succeeds, return to chat and the agent can re-check status and continue.

## Target environment

- macOS (Linux/Windows are out of scope)
- An HKUST ITSO account
- HPC4 access privileges (default Slurm account is `watanabemc` for the Watanabe group; change `account` in setup if you're in a different group)
- For off-campus use: Ivanti Secure Access (the HKUST SSL VPN client; install separately)

---

# HKUST HPC4 official-info reference

Operational notes for using HPC4 itself, independent of how the skill behaves. The HKUST HPC4 official documentation is the source of truth (this is just a convenience summary).

### Account / resource overview

| Item | Value |
|---|---|
| Login host | `hpc4.ust.hk` |
| Slurm account | `watanabemc` (Watanabe group; change per your group) |
| Partitions | `amd`, `intel` |
| Home quota | 200 GB / user (`/home/<username>`) |
| Project quota | 10 TB / group (`/project/watanabemc`, NFS) |
| Scratch quota | 500 GB / user (`/scratch/<username>`, SSD NFS, deleted after 60 days inactive) |

### Default Slurm resource ratios

Specify only `--cpus-per-task` or `--gpus-per-node` — Slurm will allocate RAM etc. proportionally. Manually inflating `--mem` is not recommended:

| Node / Resource | Default ratio |
|---|---|
| AMD nodes | 1 CPU : 2.8 GB RAM |
| Intel nodes | 1 CPU : 3.8 GB RAM |
| A30 / L20 GPU | 1 GPU : 16 threads (HT off) : 7.5 GB RAM/thread |
| RTX4090D / RTX5880ADA | 1 GPU : 10 threads (HT off) : 7.5 GB RAM/thread |

### Interactive job examples

```bash
# CPU
srun --account=watanabemc --partition=<partition_name> \
     --ntasks-per-node=1 --cpus-per-task=16 --nodes=1 \
     --time=01:00:00 --pty bash

# GPU
srun --account=watanabemc --partition=<partition_name> \
     --gpus-per-node=1 --nodes=1 --time=01:00:00 --pty bash
```

### Batch job template

```bash
#!/bin/bash
#SBATCH --account=watanabemc
#SBATCH --partition=<partition_name>
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1   # remove if you don't need a GPU
#SBATCH --time=01:00:00

# module load cuda  etc., as needed
# source activate my_env

python your_script.py
```

Submit with `sbatch job.sh`; check status with `squeue -u $USER`.

### Monitoring / operations commands

| Command | What it does |
|---|---|
| `savail` | GPU/CPU/memory availability per partition. Check before large submits. |
| `squota -A watanabemc` | Cumulative storage / GPU / CPU usage for the group. |
| `squota` | Personal usage summary. |
| `squeue -u $USER` | Your active / queued jobs. |
| `sacctmgr show qos <qos_name> format=Name,MaxSubmitPU,MaxJobsPU,MaxWall` | QOS limits. |

### Billing / usage policy

- Billed monthly; itemized statements go to the PI.
- `/project` quota overages are billed separately.
- Use is limited to **HKUST research or coursework only**.
- Verify quotas before large submits; clean up temp files when done.
- Stay within your time limits.

### Containers / software builds

- Singularity / Apptainer are supported (see official docs).
- Spack lets you build your own software stack ([Spack documentation](https://spack.io)).

### Support contact

- Technical issues (account / jobs / quota): `hpc4support@ust.hk`
- For service interruptions, attach the job ID (output of `squeue -u $USER`) and the error log.
- Official: HKUST HPC4 Official Website / HKUST HPC Knowledge Base.

### Deeper operational knowledge

The operational know-how for running sbatch on HPC4 (throttle dispatcher for submitting beyond QOS limits, surviving disconnects with tmux, choosing walltimes, picking the right filesystem, the connection-layer traps) lives in the "Operational knowledge for Slurm job submission" section toward the end of the Claude/Codex skill instructions.

---

# For the curious

Internals, safety, sharing notes. Skip this if you just want to use the skill.

<details>
<summary><b>What this skill does to your macOS</b> (transparency / safety)</summary>

### Touched

| Item | Change |
|---|---|
| route table | One host route added (`143.89.184.3` only) |
| pf ruleset | Narrow `com.apple/hpc4` or skill-local anchor rules for HPC4 only when a full-VPN kill switch requires it |
| `/tmp/hpc4-cm-*` | SSH ControlMaster sockets |

### Not touched

- Default route or Claude's path (VPN configs under `/Library`, other host routes, etc.)
- `/etc/hosts`, `/etc/resolv.conf`, `~/.ssh/config` (uses the in-project `ssh_config` only)
- launchd, kernel extensions, System Settings GUI
- Any existing VPN client's settings or connections

### Persistence

**All in-memory. A reboot wipes everything automatically:**

- macOS host routes have no persistence mechanism.
- ControlMaster sockets live under `/tmp`.

To tear down explicitly, ask Claude to "tear down the route". It idempotently deletes the host route and closes the ControlMaster.

### Privileged operations

`route` and `pfctl` modify local networking state, so they need sudo. AI-run scripts do not prompt for sudo; the user-terminal helper does. The privileged operations are limited to:

- deleting a stale host route for `143.89.184.3`
- adding a host route for `143.89.184.3`
- applying or flushing a narrow pf anchor for `143.89.184.3`

No external input is interpolated into the sudo commands, so there's no shell-injection surface. With Touch ID enabled, the fingerprint suffices.

</details>

<details>
<summary><b>Sharing notes</b> (policy / conflicts / personal info)</summary>

### Policy

- **Personal Mac**: just one user-level host route — fine.
- **Corporate-issued Mac**: if your IT department audits routing-table changes via MDM, check with them first.
- **Relationship to commercial VPNs**: this is functionally identical to adding 143.89.184.3 to the VPN client's split-tunnel list, just done via a host route. How the provider's TOS interprets that is on you.

### Conflicts

- **VPN client kill-switch / NEPacketTunnelProvider blocking 143.89.184.3 at L4**: kernel routing is correct but TCP 22 doesn't go through. `net-up.sh` detects this and prints terminal-readable instructions for whitelisting 143.89.184.3 in the VPN client GUI before exiting.
- **Little Snitch / LuLu**: as long as the relevant app is allowed, the host route punches through. If they're blocking, allow them separately.
- **Other VPN clients running concurrently**: the skill does not identify VPN products. If any interface holds a 143.89/16 IP, the skill pins HPC4 traffic to that interface; otherwise it tells the user to start Ivanti or get on the campus network.

### Personal info

- Your ITSO username goes into `user.conf.local`, which is gitignored (not in the repo).
- Your SSH private key stays in `~/.ssh/`; the skill never copies it.
- **Before redistributing**: delete your own `user.conf.local` first (`git archive` and clean clones already exclude it).

</details>

<details>
<summary><b>Network-route auto-detection</b></summary>

The skill does not identify VPN products. It asks the kernel "which interface egresses HPC4 (143.89.184.3)?" and decides solely based on whether that interface holds a 143.89/16 IP:

- At least one interface reaches HKUST (en0 directly on 143.89/16, or Ivanti utun with a 143.89.\* IP) → pin a host route for HPC4 to that interface. Even if another VPN later changes the default, longest-prefix-match keeps HPC4 routed correctly.
- No interface reaches HKUST (another VPN owning the default, or fully off-campus) → pinning would be useless; bail and tell the user to start Ivanti / switch to a campus network.
- Routing OK but TCP 22 fails (VPN client kill-switch / NEPacketTunnelProvider blocking at L4) → print terminal-readable steps for whitelisting 143.89.184.3 in the VPN client GUI.

For per-layer behavior and the gotchas, see the "How the network layer works" and "macOS-side connection traps" sections of [SKILL.md](.claude/skills/hpc4/SKILL.md).

</details>

<details>
<summary><b>File layout</b></summary>

```
.claude/skills/hpc4/
├── SKILL.md              Claude-facing instructions (defines this skill's behavior)
├── README.md             this file (human-facing guide)
├── ssh_config            HPC4-only SSH config (HostName pinned to a literal IP)
├── user.conf.local       personal config (gitignored; produced by setup)
└── scripts/
    ├── common.sh         shared constants and helpers
    ├── status.sh         connection-status diagnostic
    ├── net-up.sh         diagnose/prepare the HPC4 route without AI-side sudo
    ├── net-up-local.sh   user-terminal helper for sudo route/pf changes
    ├── net-down.sh       remove the HPC4 host route
    ├── net-down-local.sh user-terminal helper for sudo teardown
    ├── ssh-run.sh        run a command on HPC4
    ├── xfer.sh           file transfer (scp/rsync)
    └── write-user-conf.sh  generate user.conf.local
```

Codex uses the analogous project-local layout:

```
.codex/skills/hpc4/
├── SKILL.md
├── ssh_config
├── user.conf.local       personal config (gitignored; produced by setup)
└── scripts/
```

</details>

<details>
<summary><b>Maintenance (when HPC4's IP changes)</b></summary>

If HKUST notifies you that `hpc4.ust.hk` has a new IP, update both of these:

- `HPC4_IP` in [scripts/common.sh](scripts/common.sh)
- `HostName` in [ssh_config](ssh_config)

Keep them in sync (drift causes "ping works but ssh doesn't" type inconsistencies). Expect this maybe once every few years.

</details>

<details>
<summary><b>Manual debug commands</b></summary>

Normally you can ask Claude to "check HPC4 status" or "reset the route" and it'll fix it. When that doesn't work:

```
ssh -F .claude/skills/hpc4/ssh_config -l <user> -vvv hpc4   # verbose SSH log
```

Per-layer details are in the "How the network layer works" and "macOS-side connection traps" sections of [SKILL.md](.claude/skills/hpc4/SKILL.md).

</details>

<details>
<summary><b>Scripts cheat sheet</b> (for direct invocation)</summary>

Normally you'd just ask Claude. When you want to call them directly:

| script | what it does |
|---|---|
| `bash .claude/skills/hpc4/scripts/status.sh` | Show current connection status (no sudo). |
| `bash .claude/skills/hpc4/scripts/write-user-conf.sh <itso_username>` | Generate `user.conf.local` (first-time setup). |
| `bash .claude/skills/hpc4/scripts/net-up.sh` | Pin the HPC4 host route (idempotent). |
| `bash .claude/skills/hpc4/scripts/net-down.sh` | Remove the HPC4 host route and ControlMaster. |
| `bash .claude/skills/hpc4/scripts/ssh-run.sh '<command>'` | Run an arbitrary command on HPC4. |
| `bash .claude/skills/hpc4/scripts/xfer.sh put <local> <remote>` | Upload a file to HPC4. |
| `bash .claude/skills/hpc4/scripts/xfer.sh get <remote> <local>` | Download a file from HPC4. |
| `bash .claude/skills/hpc4/scripts/xfer.sh put-r <local> <remote>` | Send a directory via rsync. |
| `bash .claude/skills/hpc4/scripts/xfer.sh get-r <remote> <local>` | Pull a directory via rsync. |

`ssh-run.sh` / `xfer.sh` internally call the equivalent of `net-up.sh` automatically, so you can call them directly without thinking about routing.

</details>
