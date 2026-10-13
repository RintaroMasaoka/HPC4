---
name: hpc4
description: "Connect to HKUST HPC4 over SSH, run remote commands, transfer files, and diagnose networking. Claude can invoke Bash scripts under .claude/skills/hpc4/scripts/ from context; users can also invoke /hpc4 interactively."
user-invocable: true
---

# hpc4 — HKUST HPC4 connection skill

Support SSH access to the HKUST HPC4 (`hpc4.ust.hk`) cluster from Claude's local execution environment, alongside normal AI-service traffic.

## Background

The original deployment addresses Claude (Anthropic API) traffic routed outside Hong Kong alongside HPC4 access inside HKUST. HPC4 requires HKUST internal networking: wired / Ivanti `143.89/16`, or HKUST campus eduroam `10.79/16` NAT. The same Mac must support both the normal route for Claude traffic and the HPC4 route (campus eduroam / wired / Ivanti split tunnel).

The OS normally establishes this coexistence through routes installed by VPN / network clients: normal traffic uses the default route, while HKUST traffic uses a more specific route through longest-prefix matching. The skill never changes the default route or Claude traffic routes. **It manages only the HPC4 (143.89.184.3) host route**, with the pf exception described below.

See [policy.md](policy.md) for ITSO connection requirements, campus versus off-campus access, federated eduroam, authentication, and source references. This file focuses on operations.

## Design invariant: users can recover without Claude

When Claude is unreachable, users need to understand the situation and act using only Terminal.

- **Script output is English, readable directly in a terminal.** Explain the state and next action; do not require an AI to interpret verdict strings.
- **Never modify the default route or Claude traffic routes**, so HPC4 repair does not disrupt access to help.
- **Separate AI execution from interactive repair.** AI execution cannot handle sudo prompts. If an HKUST interface and correct L3 routing exist but TCP 22 is blocked, the user's Terminal helper treats the pf main-ruleset kill switch as the leading cause, runs `pfctl -F rules` once, and rechecks. Stop if flushing does not restore access; the old `com.apple/hpc4` anchor strategy has been removed.

## Invocation model

Claude normally selects and invokes Bash scripts under `.claude/skills/hpc4/scripts/` from task context. Users can also invoke `/hpc4` interactively.

## Scripts and Terminal helpers

Run scripts as `bash .claude/skills/hpc4/scripts/<name>.sh [args]`. `ssh-run.sh` and `xfer.sh` check TCP 22 before invoking `net-up.sh` if needed. When already reachable, call the intended operation directly. If `net-up.sh` exits 3 because sudo is needed, ask the user to run `net-up-local.sh` in their Terminal.

| Script | Arguments | When to use |
|---|---|---|
| `status.sh` | None | Quick health check before HPC4 work or during diagnosis |
| `ssh-run.sh` | `'<command>'` | Remote `squeue`, `sbatch`, `ls`, `cat`, or other commands |
| `xfer.sh` | `put <l> <r>` / `get <r> <l>` | Single-file upload / download |
| `xfer.sh` | `put-r <l> <r>` / `get-r <r> <l>` | Directory transfers using rsync |
| `net-up-local.sh` | None | User-terminal helper for route / pf changes and SSH key passphrases; selects a key and runs ssh-add |
| `net-down.sh` | None | Reset HPC4 host route and ControlMaster during troubleshooting; route deletion is delegated, socket closure is automatic |
| `net-down-local.sh` | None | User-terminal helper for sudo teardown |
| `write-user-conf.sh` | `<itso_username>` | Generate user.conf.local in setup Step A |
| `net-up.sh` | None | Diagnose / prepare routing, including unreachable TCP 22; no sudo from AI execution |

The complete configuration and passwordless SSH setup flow is in the **First-time setup flow** section below; it is not a single script.

### Entry point for `/hpc4` or context-driven use

**Start with `bash .claude/skills/hpc4/scripts/status.sh`**, then branch:

1. Missing `user.conf.local`: ask for the ITSO username, generate it with `write-user-conf.sh`, and restart status.
2. No HKUST-capable interface: forward the English recovery instructions (campus eduroam / wired, or Ivanti off campus), then stop setup until the network is fixed. Do not proceed to ssh-copy-id.
3. Stale host pin or egress outside HKUST: ask the user to run `net-up-local.sh` in a separate terminal, then recheck status.
4. TCP 22 blocked: run net-up.sh for detailed diagnosis; if L4 repair needs sudo, ask for net-up-local.sh, which flushes pf main rules once and rechecks.
5. Network OK, passwordless SSH not ready: follow Step C. Start with key selection and ssh-add in net-up-local.sh; if still incomplete, use its ssh-copy-id guidance for the selected key.
6. Everything ready: for a direct `/hpc4` invocation, ask in one sentence what the user wants to do (queue query / submission / transfer / status). For context-driven use, proceed with the requested task.

## Operating rules

1. **Idempotence:** repeated script calls must be safe. If already configured, return without changes.
2. **Minimal changes:** normally manage only the 143.89.184.3 host route. The exception is one pf main-ruleset flush in the user's Terminal helper when L3 is correct but TCP 22 is blocked. Never change the default route or Claude traffic routes.
3. **Do not identify VPN products:** inspect interfaces with `ifconfig` for HKUST internal IPv4 (`143.89/16` or campus eduroam `10.79/16`), rather than branching on product names.
4. **Handle L4 blocks according to execution context:** AI execution cannot handle sudo prompts and must direct the user to `net-up-local.sh`. In the user's Terminal helper, with an HKUST-capable interface and correct L3 routing, treat the pf main-ruleset kill switch as the most likely cause, run `pfctl -F rules` once, and recheck. If still blocked, stop and consider system-enforced NEPacketTunnelProvider tunneling, VPN settings, or HKUST tunnel reauthentication; these cannot be repaired from user space.
5. **Isolate personal information:** keep ITSO usernames and other personal settings in gitignored `user.conf.local`, outside shared repository files.

6. **Delegate sudo and SSH key passphrases to the user's Terminal helper:** AI-run scripts must not handle those prompts. The user runs `bash .claude/skills/hpc4/scripts/net-up-local.sh` in their own Terminal. The helper can repair routes, flush pf main rules, and add a key to the SSH agent.  AI execution can silently fail on sudo password / Touch ID or passphrase prompts, making success easy to misinterpret.
7. **Ask the user for shell operations only when their prerequisites hold:** collect settings in chat and write them directly; do not ask users to run `cp` or `chmod`. A separate-terminal request is allowed for privileged or interactive tasks such as ssh-copy-id or sudo route. Never request authentication operations before the network is `[ok]`. A helper requested for route/pf repair may continue to authentication once networking is restored. **Always provide absolute paths** for commands in a separate terminal, since a new shell usually starts in `~`. Scripts already resolve `${SKILL_DIR}` to an absolute path, so forwarding their command output is safe.
8. **Keep responses short:** report the result (ok / error / summary) with minimal progress narration.

## Target environment

- **Cluster:** `hpc4.ust.hk` (143.89.184.3); default Slurm account `watanabemc`, overridable in `user.conf.local`.
- **Client OS:** macOS; Linux and Windows are outside scope.
- **Authentication:** public-key authentication (passwordless SSH) with 12-hour ControlMaster persistence.
- **Network:** at least one interface with HKUST internal IPv4: wired / Ivanti `143.89/16`, or HKUST campus eduroam `10.79/16`. Supported connections are HKUST campus eduroam, HKUST wired networking, or Ivanti Secure Access (HKUST SSL VPN). **eduroam outside HKUST** (HKSTP facilities such as DT Hub, other universities, airports) does not assign HKUST internal IPs; see [policy.md](policy.md). Another VPN may own the default route as long as its kill switch, packet filter, or NEPacketTunnelProvider does not block HPC4.

## First-time setup flow

Goal: **create `user.conf.local` and establish passwordless SSH**. Ask for at most two actions: provide the ITSO username, and run an authentication command in a separate terminal with password + 2FA.

**Always start with `status.sh`** to classify interface state and HPC4 reachability.

### Step A. Collect and save personal settings

1. If `.claude/skills/hpc4/user.conf.local` exists and `HPC4_USER` is nonempty, skip all of Step A and proceed to Step B.
2. Otherwise ask directly in chat: "What is your HPC4 ITSO account name (the username you use to SSH into, for example, `login4`)?" **Do not infer candidates from SSH configuration, known_hosts, or email addresses.** Asking is faster and more accurate.
3. Run `bash .claude/skills/hpc4/scripts/write-user-conf.sh <username>` to generate `user.conf.local`.
4. Verify that `.gitignore` includes `.claude/skills/hpc4/user.conf.local`; add it if missing.

### Step B. Determine HPC4 reachability

Run `bash .claude/skills/hpc4/scripts/status.sh`  and branch by stage:

- `[ok] HKUST-capable interface` + `[ok] HPC4 route` + `[ok] TCP 22 reachable` → continue to Step C.

- `[ng] No HKUST reachability` → forward the script's English recovery instructions: connect to HKUST campus eduroam / wired networking, or use Ivanti Secure Access off campus. Resume with `/hpc4` after fixing the network. **Do not proceed to ssh-copy-id.**
- Stale host pin or egress outside HKUST: ask for net-up-local.sh in a separate terminal, then resume.
- TCP 22 blocked: diagnose with net-up.sh. If sudo is needed, direct the user to net-up-local.sh. With correct L3 and blocked TCP 22, that helper flushes pf main rules once; stop if still unreachable.

AI-run scripts do not handle sudo prompts. Delegate route / pf changes to the user's Terminal helper and complete them there.

### Step C. Verify passwordless SSH

**Prerequisite: Step B's network result must be `[ok]`.** Do not proceed with a failed network result.

1. Inspect the `Passwordless SSH` line in status output.
2. If already ready, take no further action and report success.
3. If not ready, first ask the user to run net-up-local.sh in their Terminal. Use `HPC4_IDENTITY_FILE` if set; otherwise let the user select a candidate from `~/.ssh/`. If an encrypted key is simply absent from the agent, the helper runs `ssh-add`, accepts the passphrase in Terminal, and rechecks.
4. If still not ready after `net-up-local.sh`, provide the following guidance once:
   - If no private key exists, `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519` may be run automatically (noninteractive).
   - If the public key is not registered, forward the helper's `ssh-copy-id -i <selected-key>.pub <HPC4_USER>@hpc4.ust.hk` command for one separate-terminal run requiring password + 2FA.
   - Ask the user to return to chat when done, then verify again with status.sh.
5. Report setup completion once passwordless SSH works.

### Step D. Verify operation

Run `bash .claude/skills/hpc4/scripts/ssh-run.sh 'hostname && whoami'`  and confirm that it returns `login{N}` and the user's username.

## Typical invocation patterns

Paths below are relative to the working directory. Invoke these through the Bash tool.

```bash
# Connection status
bash .claude/skills/hpc4/scripts/status.sh

# Cluster queries
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squeue -u $USER'      # Your queue
bash .claude/skills/hpc4/scripts/ssh-run.sh 'savail'               # Partition availability
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squota -A {account}'  # Group quota

# Upload, submit, and retrieve results
bash .claude/skills/hpc4/scripts/xfer.sh put job.sh /scratch/$USER/job.sh
bash .claude/skills/hpc4/scripts/ssh-run.sh 'cd /scratch/$USER && sbatch job.sh'
bash .claude/skills/hpc4/scripts/xfer.sh get-r /scratch/$USER/results results/
```

## How the network layer works

The core question is whether any interface on this Mac has HKUST internal IPv4 (`143.89/16` or HKUST eduroam `10.79/16`). Read `ifconfig` directly; do not identify VPN products.

### Algorithm shared by `net-up.sh` and `status.sh`

1. **`find_hkust_iface`:** scan interfaces for HKUST internal IPv4 independently of routing. A stale host pin may distort `route get`, but does not fool this check. If none exists, tell the user to connect to HKUST campus eduroam / wired networking / Ivanti and exit; pinning cannot help.
2. **Detect stale pins:** `current_hpc4_iface` finds an existing host pin. If it points outside HKUST, ask the user to run `net-up-local.sh` to remove it. Report stale-pin problems separately from absence of HKUST capability.
3. **Inspect the kernel's natural egress with `route get 143.89.184.3`:** if it selects a non-HKUST interface, ask the user to run `net-up-local.sh` to add a host route.
4. **Test TCP 22:** if reachable, finish.
5. **L3 OK but L4 blocked:** in the user's Terminal helper, flush pf main rules once and recheck. If still unreachable, stop; the remaining block cannot be repaired from user space.

### Why this is sufficient

- HKUST networks assign internal IPv4: `143.89/16` for wired / Ivanti, and the internal NAT pool `10.79/16` for campus eduroam. Checking those addresses distinguishes HKUST connectivity from federated eduroam elsewhere, which assigns the visited institution's IP pool.
- Ivanti normally installs a `143.89/16 -> utun` subnet route automatically, so a host pin is usually unnecessary unless something interferes with natural routing.
- With correct L3 but unreachable TCP 22, prioritize layer diagnosis over detecting a particular rule string. The user-terminal helper flushes pf main rules once. Do not propose additional skill-side workarounds if that does not restore access.

SSH uses 12-hour ControlMaster persistence, reducing repeated password + 2FA prompts to roughly once per day.

## Operations requiring sudo

AI-run scripts cannot handle sudo or SSH key passphrase prompts. For host-route add/delete, pf main-ruleset flush, or `ssh-add` for an encrypted key, direct the user to `bash .claude/skills/hpc4/scripts/net-up-local.sh` in their own Terminal. The helper permits interactive sudo and automatically runs `pfctl -F rules` once if L3 is correct but TCP 22 is blocked. Once routing is ready, it uses the configured or selected key, runs `ssh-add`, accepts the passphrase in Terminal, and rechecks.



Prompts from AI shell execution may be invisible or impossible to answer. Delegating these operations to a Terminal helper also allows users to recover when the AI service is unavailable.

## Troubleshooting

1. Run `bash .claude/skills/hpc4/scripts/status.sh`  to identify the failing layer: network, authentication, or ControlMaster.
2. Diagnose routing with net-up.sh; if sudo is needed, ask for net-up-local.sh in the user's Terminal.
3. For a full reset, run net-down.sh followed by net-up.sh.
4. If still unable to connect, run `ssh -F .claude/skills/hpc4/ssh_config -l <user> -vvv hpc4`  for detailed logs.

## Handoff to new members

After cloning the repository, invoke `/hpc4` once or ask Claude to "set up HPC4". This starts the setup flow; no preparatory shell work is required.

---

## Operational knowledge for Slurm job submission

These notes cover common pitfalls when running `sbatch` on HPC4 after connecting. They contain no project-specific settings.

### Job model

- **One sbatch submission = one job.** `--array=0-N` expands it into N+1 array tasks, each scheduled and billed independently.
- **Account:** the allocation charged for compute time. The default is `HPC4_ACCOUNT` in `user.conf.local`, or `watanabemc` if unset.
- **Partition:** a node group (`amd`, `intel`, etc.). **Match the execution CPU to the CPU used for compilation.** An ISA mismatch, such as AVX2/AVX512 instructions on an unsupported CPU, fails with an illegal instruction.
- **QOS:** limits on concurrent submissions per partition. Check before submitting: `sacctmgr show qos {qos_name} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall`.
- **QOS counters count each array task.** One `--array=0-149` submission counts as 150 tasks. Arrays larger than MaxSubmit are rejected.

### Throttle dispatcher for submissions beyond QOS limits

Repeated array submissions exceeding QOS MaxSubmit fail with `QOSMaxSubmitJobPerUserLimit`. Run a dispatcher that checks the current queue and submits only when enough capacity remains:

```bash
QUEUE_LIMIT=$((MaxSubmitPU - margin))   # Leave room for manual submissions
ARRAY_SIZE=...                        # Number of tasks in this submission

while :; do
    n_q=$(squeue -u "$USER" -h -t PD,R 2>/dev/null | wc -l)
    if (( n_q + ARRAY_SIZE <= QUEUE_LIMIT )); then
        break
    fi
    sleep 60
done
sbatch --parsable my_array.sh
```

**`-t PD,R` is required:** including CG/CD/F would also count finishing or completed jobs.

### Run long dispatchers inside tmux

Whether `nohup ... & disown` survives depends on the OS, login shell, and SSH client; SIGHUP can still terminate it. Use a **detached tmux/screen session for dispatchers running for hours**.

```bash
bash .claude/skills/hpc4/scripts/ssh-run.sh 'tmux new-session -d -s {name} "bash dispatcher.sh > log 2>&1"'
# When returning
bash .claude/skills/hpc4/scripts/ssh-run.sh 'tmux list-sessions; tail -20 log'
```

**Check `tmux list-sessions` or `ps -ef | grep dispatcher` first** to confirm that the dispatcher is alive. Logs are supporting evidence: intermittent NFS I/O can insert NULL bytes, make `grep` report "binary file matches", or disrupt `tail` output while dispatch continues normally.

### Choosing walltime

- Walltime is the maximum time a task can occupy its CPUs. Resources are released on early completion; billing uses actual runtime.
- Longer limits give more headroom, but the scheduler may defer those jobs, increasing queue time.
- Exceeding the limit kills the job. Aim for 1.5–2 times the worst-case estimate. If estimates vary across parameters, **split by task or sbatch submission**, even within the same partition.

### Choosing a filesystem

| Path | Capacity | Persistence / use |
|---|---|---|
| `/home/$USER` | 200 GB | Persistent: code, configuration, small results |
| `/project/{group}` | TB scale, shared by group | Persistent: large datasets |
| `/scratch/$USER` | 500 GB | **Deleted after 60 days inactive:** intermediate files |

Save results you need to retain in home or project storage. Treat scratch as temporary.

### Login-node etiquette

Login nodes are shared. Avoid CPU- or I/O-heavy work there.

- Suitable: sbatch submissions, lightweight `squeue` / `ls` / `tail` queries, lightweight dispatchers, tmux, modules, and a single lightweight `make`.
- Unsuitable: numerical computation such as fitting, multi-GB rsync transfers, and parallel builds.

Use `srun --account={account} --partition={partition} --pty bash` for heavy interactive work.

### Before submitting

1. Record QOS limits with `sacctmgr show qos {qos} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall`.
2. Check remaining CPU hours with `squota -A {account}`.
3. Compile the binary on the target partition so the ISA matches.
4. **Dry-run** the dispatcher by replacing sbatch with echo; check submission count and content.
5. Start the production dispatcher in a **detached tmux session**.

### macOS-side connection traps

The skill includes measures for these symptoms; knowing them helps debugging:

1. **SSH hostname resolution can fail with split-tunnel VPNs.** DNS tools and SSH may see different resolver settings, so `host hpc4.ust.hk` can succeed while SSH reports "Could not resolve". The skill pins `HostName` to an IP and uses `HostKeyAlias` to preserve known_hosts consistency.
2. **A VPN kill switch can block 143.89.184.3 at L4.** Even with correct kernel routing, packet filters or NEPacketTunnelProvider (`includeAllNetworks=true`) can block TCP. The user-terminal helper flushes pf main rules once and rechecks. If that does not restore access, the skill cannot override system-enforced tunneling from user space.
3. **Routes disappear after reboot or sleep.** macOS host routes are not persistent. After waking, rerun `bash .claude/skills/hpc4/scripts/net-up.sh` (idempotent).
4. **`scp -l` is a bandwidth limit, not a username.** Unlike `ssh -l user`, scp uses `-l` for kbps. Pass the username with `-o User=...` or `user@host:path`; `xfer.sh` passes it correctly through the SSH configuration.

### Common operational one-liners

Use `bash .claude/skills/hpc4/scripts/ssh-run.sh '<command to run on HPC4>'`.

```bash
# Queue breakdown by job name
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squeue -u $USER -h -o "%j %T" | sort | uniq -c | sort -rn'

# QOS limits and usage
bash .claude/skills/hpc4/scripts/ssh-run.sh 'sacctmgr -n -p show qos {qos_name} format=Name,MaxSubmitPU,MaxJobsPU,MaxWall'

# Remaining group quota
bash .claude/skills/hpc4/scripts/ssh-run.sh 'squota -A {account}'

# Partition availability
bash .claude/skills/hpc4/scripts/ssh-run.sh 'savail'

# tmux sessions and the end of the dispatcher log
bash .claude/skills/hpc4/scripts/ssh-run.sh 'tmux list-sessions; tail -20 ~/path/to/log'
```
