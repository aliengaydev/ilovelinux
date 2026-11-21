# PLAN — Linux Infrastructure Challenge (student.lab)

Living checklist: each step is ticked when verified, then committed and pushed (`step N: …`).

## Context
The task is `~/infra/task.txt`: 11 sections plus a 4-part defense covering architecture, demo, Linux knowledge and troubleshooting. It's for Oleksandr Cherniavskyi, group KH-24. I re-read the task and mapped each requirement to a deliverable (table below). This plan also adds two process rules you asked for:
- The plan lives in the repo as `~/infra/PLAN.md`, a checklist I tick off as I go.
- I **commit and push to GitHub after every major step.**

## Current state (2026-11-21)
**Server:**
- Hostname `pop-os`, enp0s8 on 192.168.56.101 (DHCP), passwordless sudo ✅.
- Docker and Compose are installed; nginx, sshd and dnsmasq aren't yet.
- Concern: the host was overloaded once. All vCPUs locked up for 27s when the client booted.

**Client:**
- Pop!_OS at 192.168.56.102, user `scarpetka`, sshd running.
- My key isn't there yet. You need to run `! ssh-copy-id scarpetka@192.168.56.102`.
- Passwordless sudo is unverified.

**Repo:**
- `~/infra` is a git repo on `main`, with `origin = git@github.com:aliengaydev/ilovelinux.git` (SSH auth works) and **0 commits**.
- Written but not run: `server/lab.env` and `lib.sh` (shared settings and helpers), and the scripts `00-bootstrap` … `07-firewall`.
- Written config: the nginx vhosts, the page with SSI hostname, dnsmasq, `ssh/10-lab.conf`, `app/docker-compose.yml`, and `systemd/lab-app.service`.
- Not written yet: `08-backup`, `09-monitoring`, `client/setup-client.sh`, `tests/verify.sh`, and the README.

## Requirement → deliverable map
| Task section | Deliverable | How it's verified |
|---|---|---|
| 1 Infrastructure | Server .10/lab-server and client .20/lab-client, static via NetworkManager on a host-only /24; NAT keeps internet access | `ip -br a`, ping both ways, survives a reboot |
| 2 Administration | `sysadmin` (sudo), ed25519 keys, `sshd_config.d/10-lab.conf` (key-only, no root, `AllowGroups sshusers`), root password locked | key login OK; password/root login refused (`sshd -T`, attempts from the client) |
| 3 Users & access | `dev1`, `dev2` in `devteam`; `guest` outside; `/srv/projects/devteam` 2770 + default ACL; homes 0700 | dev1 creates a file → group devteam, dev2 can edit; guest is denied; homes are private |
| 4 Web service | nginx (enabled), own vhost + logs, page with name/group/**dynamic hostname** (SSI) | `curl http://www.student.lab` from the client; log lines appear; still works after reboot |
| 5 Application | Gitea 1.22.6 + Postgres 16.6 in compose, named volumes, healthchecks, `lab-app.service` | create a repo → `down`/`up` → repo still there |
| 6 Integration | `app.student.lab` → nginx → 127.0.0.1:3000; DNS through dnsmasq | the client opens the app by name; `:3000` from the client is refused |
| 7 Network security | ufw: only 22 (rate-limited) / 53 / 80 on enp0s8 from 192.168.56.0/24; 3000 bound to loopback; 5432 not published (DB network `internal`) | `nmap` from the client; `ss -tlnp` on the server; port/access table in README |
| 8 Backup & recovery | `lab-backup` (pg_dump, gitea volume, projects with ACLs, configs) + `lab-restore`; systemd timer at 02:30; 7 daily + 4 weekly kept | live demo: delete a project file and a Gitea repo → restore → check |
| 9 Monitoring | `healthcheck` (resources, disk/inodes, services, containers, DNS, HTTP, backup age, exposed ports) → OK/WARN/CRIT and exit code; 5-minute timer; MOTD | normal state is all OK; stopping a container gives CRIT |
| 10 Failure recovery | README runbook for all 10 scenarios (symptom → localize → root cause → fix → verify) | I break 6 things on purpose and fix them following the runbook |
| 11 Reboot | everything is enabled; `lab-app.service` brings the stack up after Docker | reboot → `healthcheck` all OK + `tests/verify.sh` from the client |
| Defense | README (UA): architecture diagram, decisions, port table, user matrix, demo checklist | — |

## Execution steps (each ends with a commit and push)
Every commit message starts with `step N:`. **I ask before:** IP/hostname changes, ufw changes (I show the existing rules first), and reboots. Removing the temporary sudoers file comes at the very end, also with confirmation. Secrets never go in git: `.env`, `/root/lab-initial-passwords` and private keys stay out, while `server/keys/*.pub` are fine to commit.

- [x] **0. Repo bootstrap.** Write `PLAN.md` (this plan as a checklist) and a README skeleton. First commit with the files written so far → `git push -u origin main`.
- [x] **1. Network (sec. 1).** `00-bootstrap.sh` (packages), then `01-network.sh` on the server. After you run `ssh-copy-id`, I run `client/setup-client.sh` on the client. It sets .20, `lab-client`, DNS `~student.lab` and installs nmap/dig/curl, and it runs under `nohup` because the SSH session drops when the IP changes. Then I reconnect on .20. *Verify:* ping both ways. → commit/push
- [x] **2. Admin + SSH (sec. 2).** Generate ed25519 keys on the client (for sysadmin, dev1, dev2) → copy the `.pub` files into `server/keys/`, then run `02-admin-ssh.sh`. *Verify* from the client. → commit/push
- [x] **3. Users & projects (sec. 3).** `03-users.sh`. *Verify:* the ACL/setgid tests listed above. → commit/push
- [x] **4. Web + DNS + app + proxy (sec. 4–6).** `04-web.sh`, `05-dns.sh`, `06-app.sh`. *Verify* from the client and with a persistence test. → commit/push
- [x] **5. Firewall (sec. 7).** Show the current `ufw status`, then run `07-firewall.sh`. *Verify:* nmap and ss. → commit/push
- [x] **6. Backup (sec. 8).** Write `server/backup/{lab-backup,lab-restore}`, the systemd service/timer and `08-backup.sh`. *Verify* by restoring a deleted project file and a deleted Gitea repo. → commit/push
- [x] **7. Monitoring (sec. 9).** Write `server/monitoring/healthcheck`, the timer, the MOTD hook and `09-monitoring.sh`. *Verify:* all OK, then simulate a fault. → commit/push
- [ ] **8. Failure drills + runbook (sec. 10).** Inject and fix: nginx stopped, DB container stopped, broken dnsmasq config, `ufw deny 80`, wrong permissions on the project dir, disk filled with `fallocate`. Then write the runbook in the README. → commit/push
- [ ] **9. Reboot test (sec. 11).** Write `tests/verify.sh`. After you confirm, reboot → healthcheck plus verify from the client. → commit/push
- [ ] **10. Finish.** Final Ukrainian README: architecture, decisions, port/access table, user matrix, backup and monitoring guide, runbook, defense demo checklist. Tick off PLAN.md, final commit/push, and remove `99-claude-temp` from both VMs (asking first).

## Risks / notes
- **Host overload:** before step 4 (image pulls plus the app), consider 2 vCPUs for the server and 1–2 for the client, with 3D acceleration off.
- **Docker bypasses ufw:** mitigated with loopback-only publishing and an internal network. The README explains why.
- **Public or private repo:** the repo contains no secrets either way. You decide the visibility on GitHub.
