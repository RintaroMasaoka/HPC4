---
name: hpc4
description: "Provides SSH access, remote command execution, file transfer, and network-route setup for HKUST HPC4. Codex calls the bash scripts under .codex/skills/hpc4/scripts/ directly via the exec_command shell tool when the context calls for it."
user-invocable: true
---

# hpc4 - HKUST HPC4 connection skill

This skill provides access to the HKUST HPC4 cluster (`hpc4.ust.hk`, `143.89.184.3`) from Codex Desktop on macOS. It handles SSH, remote command execution, file transfer, and the local host route needed when HKUST access must coexist with another VPN.

The skill is an operational helper, not a chat command router. When HPC4 is needed, Codex should choose the right script from context and call it directly through `exec_command`.

## Critical Sandbox Rule

HPC4 reachability checks and SSH-like operations can be false negatives inside the normal Codex sandbox. A normal sandbox run may report TCP/22 or SSH failure even when the Mac can reach HPC4.

Therefore, Codex must run the following with `sandbox_permissions="require_escalated"`:

- `scripts/status.sh`
- `scripts/net-up.sh` and `scripts/net-down.sh`
- `scripts/ssh-run.sh`
- `scripts/xfer.sh`
- direct fallback uses of `ssh`, `scp`, `rsync`, `nc`, or `ping` for HPC4

If a normal sandbox run already failed, do not treat that as evidence that HPC4, VPN, pf, or this skill is broken. Re-run the same check outside the sandbox first. If the escalated run succeeds, diagnose it as a sandbox false negative and continue.

This escalation is not `sudo`; it only asks Codex to run outside the workspace/network sandbox. `sudo` prompts from `route` or `pfctl` are handled separately by the scripts.

## Sudo Prompt Rule

Do not try to solve `sudo` by running an interactive/TTY Codex command. In Codex Desktop, the user does not have a reliable way to type into the command's password prompt, so a `Password:` prompt will just hang or fail.

If `route` or `pfctl` needs local admin approval, stop and ask the user to run the printed helper command in their own Terminal. Then re-check with `status.sh` outside the sandbox.

## Scripts Codex Can Call

Every script below is invoked as `bash .codex/skills/hpc4/scripts/<name>.sh [args]` from the repo root.

| script | args | Use when |
|---|---|---|
| `status.sh` | none | Check config, route, TCP/22, passwordless SSH, and ControlMaster state |
| `ssh-run.sh` | `'<command>'` | Run a command on HPC4, such as `squeue`, `sbatch`, `ls`, `cat`, or `tail` |
| `xfer.sh` | `put <local> <remote>` / `get <remote> <local>` | Transfer one file |
| `xfer.sh` | `put-r <local-dir> <remote-dir>` / `get-r <remote-dir> <local-dir>` | Transfer a directory with rsync |
| `net-up.sh` | none | Prepare or repair the HPC4 route/pf exception |
| `net-up-local.sh` | none | User-terminal helper for the same repair when local `sudo` password/Touch ID is required |
| `net-down.sh` | none | Remove the HPC4 host route, pf anchor rules, and ControlMaster socket during troubleshooting |
| `net-down-local.sh` | none | User-terminal helper for teardown when local `sudo` password/Touch ID is required |
| `write-user-conf.sh` | `<itso_username>` | Create local personal config during setup |

`ssh-run.sh` and `xfer.sh` call `net-up.sh` automatically when TCP/22 is not reachable, so Codex can call the goal operation directly.

## Operating Rules

1. Keep changes local and narrow. Route setup only targets the single host `143.89.184.3`; never modify the default route or Codex's internet path.
2. Prefer service checks over VPN-product guesses. TCP/22 to `143.89.184.3` is the relevant verdict.
3. Treat interface IPs as route-selection hints, not proof of reachability.
4. Keep ITSO username and per-user settings in `.codex/skills/hpc4/user.conf.local`; this file must stay gitignored.
5. Do not ask the user to run shell setup commands except for actions that genuinely need password, Duo, Touch ID, or local admin approval.
6. When sudo is needed, stop cleanly and tell the user to run `bash .codex/skills/hpc4/scripts/net-up-local.sh` in their own Terminal. Never try `sudo` from Codex, never start an interactive sudo prompt from Codex, and never ask for passwords in chat.
7. Keep user-facing responses short: result, failure layer, and next action.

## Target Environment

- Client OS: macOS only
- Cluster: `hpc4.ust.hk` (`143.89.184.3`)
- Default Slurm account: `watanabemc`, overridable in `user.conf.local`
- Default partition: `amd`, overridable in `user.conf.local`
- Auth: SSH public key plus ControlMaster with 12h persistence
- Network paths: HKUST campus network, HKUST Ivanti Secure Access, or those paths coexisting with a full-tunnel VPN

## Setup Flow

Setup is only needed when `user.conf.local` is missing or passwordless SSH is not established.

1. Run `bash .codex/skills/hpc4/scripts/status.sh` outside the sandbox.
2. If `user.conf.local` is missing, ask the user for their HPC4/ITSO username in chat, then run:

   ```bash
   bash .codex/skills/hpc4/scripts/write-user-conf.sh <itso_username>
   ```

3. Ensure `.gitignore` contains `.codex/skills/hpc4/user.conf.local`.
4. Run `bash .codex/skills/hpc4/scripts/net-up.sh` outside the sandbox. If it reports that sudo is required, ask the user to run `bash .codex/skills/hpc4/scripts/net-up-local.sh` in their own Terminal, then continue from step 5.
5. Re-run `status.sh`. If TCP/22 is reachable but passwordless SSH is not established:
   - If no private key exists, Codex may create one with `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519`.
   - Ask the user to run this once in their own Terminal, because password and Duo may be required:

     ```bash
     ssh-copy-id -i ~/.ssh/id_ed25519.pub <HPC4_USER>@hpc4.ust.hk
     ```

   - After the user reports completion, re-run `status.sh`.
6. Smoke test:

   ```bash
   bash .codex/skills/hpc4/scripts/ssh-run.sh 'hostname && whoami'
   ```

## Network Layer

`net-up.sh` uses a staged approach:

1. Test TCP/22 first. If SSH is already reachable, do nothing.
2. If not reachable, detect a route candidate:
   - `en0` default gateway for campus/wired/Wi-Fi paths
   - an Ivanti `utun` interface carrying a `143.89.*` address
3. Add a host route for only `143.89.184.3`.
4. Re-test TCP/22.
5. If TCP/22 is still blocked and a full-tunnel VPN appears to own the default route, load a macOS pf anchor under `com.apple/hpc4` that permits only HPC4 traffic on the selected interface.
6. Re-test and return a clear terminal-readable failure if still blocked.

The host route and pf anchor are in-memory local state. They disappear after reboot and can be removed with `net-down.sh`.

## SSH Details

The project-local `ssh_config` pins `HostName` to the literal IP `143.89.184.3`. This avoids macOS DNS failures when split-tunnel VPNs push DNS only into `scutil` while `ssh` consults `/etc/resolv.conf`.

ControlMaster is configured with:

- `ControlPath /tmp/hpc4-cm-%r@%h-%p`
- `ControlPersist 12h`

After the first successful authentication, repeated commands are fast and usually do not need password or Duo until the master expires.

## Common Commands

```bash
# Status
bash .codex/skills/hpc4/scripts/status.sh

# Queue and availability
bash .codex/skills/hpc4/scripts/ssh-run.sh 'squeue -u $USER'
bash .codex/skills/hpc4/scripts/ssh-run.sh 'savail'
bash .codex/skills/hpc4/scripts/ssh-run.sh 'squota -A watanabemc'

# Submit a job
bash .codex/skills/hpc4/scripts/xfer.sh put job.sh /scratch/$USER/job.sh
bash .codex/skills/hpc4/scripts/ssh-run.sh 'cd /scratch/$USER && sbatch job.sh'

# Retrieve results
bash .codex/skills/hpc4/scripts/xfer.sh get-r /scratch/$USER/results results/
```

## Slurm Operating Notes

- `1 sbatch = 1 job`; `--array=0-N` expands to `N+1` separately scheduled array tasks.
- Array tasks count individually against QOS submit limits.
- Check QOS before large submissions:

  ```bash
  sacctmgr show qos <qos_name> format=Name,MaxSubmitPU,MaxJobsPU,MaxWall
  ```

- Use a throttle dispatcher when submitting more array tasks than QOS allows. Count only pending/running jobs:

  ```bash
  squeue -u "$USER" -h -t PD,R
  ```

- Put long-running dispatchers in detached `tmux` or `screen`, not a fragile foreground SSH session.
- Match partition to compiled binary ISA. Running an AVX2/AVX512 binary on the wrong CPU partition can fail immediately with illegal instruction.
- Keep heavy computation off login nodes. Use `sbatch` or `srun --pty` for compute work.

## Storage Notes

| path | Use |
|---|---|
| `/home/$USER` | Persistent code, config, and small results |
| `/project/<group>` | Persistent group data |
| `/scratch/$USER` | Temporary compute data; inactive files may be deleted |

Move results that must survive out of scratch.
