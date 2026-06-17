# Log Audit — Centralised Log Collection, Classification & Portal

A self-hosted log aggregation pipeline for a Linux homelab. Logs are collected from multiple hosts via rsyslog, classified using standard Unix tools (`grep`, `sed`, `awk`), and published daily through a Flask web portal deployed on Kubernetes.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Infrastructure & Environment](#2-infrastructure--environment)
3. [Project Structure](#3-project-structure)
4. [Phase 1 — rsyslog: Central Receiver Setup](#4-phase-1--rsyslog-central-receiver-setup)
5. [Phase 2 — rsyslog: Remote Host Forwarding](#5-phase-2--rsyslog-remote-host-forwarding)
6. [Phase 3 — Log Collection (collect.sh)](#6-phase-3--log-collection-collectsh)
7. [Phase 4 — Log Classification (process.sh)](#7-phase-4--log-classification-processsh)
8. [Phase 5 — Daily Pipeline & Cron](#8-phase-5--daily-pipeline--cron)
9. [Phase 6 — Web Portal (Flask)](#9-phase-6--web-portal-flask)
10. [Phase 7 — Containerisation (Docker)](#10-phase-7--containerisation-docker)
11. [Phase 8 — Kubernetes Deployment (microk8s + ArgoCD)](#11-phase-8--kubernetes-deployment-microk8s--argocd)
12. [Configuration Reference](#12-configuration-reference)
13. [Operational Runbook](#13-operational-runbook)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Remote Hosts                                                   │
│  tekaden (192.168.1.108)  ──┐                                   │
│  zura    (192.168.1.120)  ──┤── rsyslog TCP :514 ──▶ voltron   │
└─────────────────────────────┘                                   │
                                                                   │
┌─────────────────────────────────────────────────────────────────┤
│  voltron (192.168.1.129) — Central Log Server                   │
│                                                                  │
│  /var/log/remote/tekaden/   ◀── rsyslog receiver               │
│  /var/log/remote/zura/                                          │
│  /var/log/syslog, auth.log, kern.log, nginx/...                 │
│            │                                                     │
│     bin/collect.sh  (daily 00:05 via cron / K8s CronJob)       │
│            │  copies today's lines                              │
│     data/raw/YYYY-MM-DD/                                        │
│            │                                                     │
│     bin/process.sh  (grep / sed / awk)                          │
│            │  classifies into categories                        │
│     data/processed/YYYY-MM-DD/                                  │
│     ├── errors.log                                              │
│     ├── warnings.log                                            │
│     ├── auth.log                                                │
│     ├── web.log                                                 │
│     ├── app.log                                                 │
│     └── summary.log                                            │
│            │                                                     │
│     web/app.py  (Flask :5055)                                   │
│            │                                                     │
│     https://log-audit.kenshin.local  (nginx-ingress + TLS)     │
└─────────────────────────────────────────────────────────────────┘
```

**Design principles:**
- No external dependencies beyond rsyslog, bash, and Python/Flask
- Standard Unix tools only for classification — no log agents, no databases
- All data stored as plain text files — portable and inspectable
- GitOps deployment via ArgoCD — infrastructure as code

---

## 2. Infrastructure & Environment

| Component | Details |
|---|---|
| Central server | voltron — Ubuntu 24.04, 192.168.1.129 |
| Remote host | tekaden — 192.168.1.108 |
| Remote host | zura — 192.168.1.120 |
| Kubernetes | microk8s (single node, v1.34) on voltron |
| Ingress | nginx-ingress, class `public` |
| Storage | microk8s-hostpath provisioner |
| TLS | cert-manager with `kenshin-ca` ClusterIssuer, wildcard `*.kenshin.local` |
| GitOps | ArgoCD |
| Container registry | ghcr.io/gbutun/log-audit |
| GitHub repo | https://github.com/gbutun/log-audit |

---

## 3. Project Structure

```
log-audit/
├── bin/
│   ├── collect.sh          # Stage 1: copies log files into data/raw/
│   ├── process.sh          # Stage 2: classifies logs with grep/sed/awk
│   ├── run-daily.sh        # Master pipeline: collect → process
│   ├── setup-receiver.sh   # One-time: configures voltron as rsyslog receiver
│   └── setup-remote.sh     # One-time: pushes forwarder config to remote hosts
├── config/
│   ├── sources.conf        # Local log paths to collect (TYPE|PATH format)
│   ├── hosts.conf          # Remote host inventory (IP HOSTNAME FQDN)
│   ├── rsyslog-receiver.conf  # Deploy to /etc/rsyslog.d/ on voltron
│   └── rsyslog-forwarder.conf # Deployed to remote hosts by setup-remote.sh
├── cron/
│   └── log-audit.cron      # Cron entry for daily pipeline
├── web/
│   ├── app.py              # Flask application (port 5055)
│   ├── requirements.txt    # Python dependencies
│   └── templates/
│       └── index.html      # Dark-themed dashboard
├── k8s/
│   ├── namespace.yaml
│   ├── pvc.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── cronjob.yaml
│   └── argocd-application.yaml
├── Dockerfile
├── .dockerignore
├── .gitignore
└── CLAUDE.md
```

---

## 4. Phase 1 — rsyslog: Central Receiver Setup

**Goal:** Configure voltron to receive syslog messages from remote hosts over TCP port 514.

### How rsyslog receiving works

rsyslog ships with input modules that open network listeners. When a remote host sends a syslog message, rsyslog on the receiver matches it against rules and writes it to a file. The `%HOSTNAME%` variable in a dynamic filename template lets each host's logs land in its own directory automatically.

### Configuration (`config/rsyslog-receiver.conf`)

```
module(load="imudp")           # UDP listener
module(load="imtcp")           # TCP listener (preferred — reliable)

input(type="imudp" port="514")
input(type="imtcp" port="514")

$template RemoteHostLog,"/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log"
$template RemoteHostAll,"/var/log/remote/%HOSTNAME%/all.log"

# Route all non-local messages to per-host directories
if $fromhost-ip != "127.0.0.1" then {
    action(type="omfile" DynaFile="RemoteHostLog" ...)
    action(type="omfile" DynaFile="RemoteHostAll"  ...)
    stop
}
```

**Key concepts:**
- `imtcp` / `imudp` — input modules that open port 514
- `DynaFile` — rsyslog creates the directory path automatically per host
- `stop` — prevents remote logs from also being written to local log files
- `%PROGRAMNAME%` — the process that generated the log (sshd, sudo, systemd, etc.)

### Installation

```bash
sudo bin/setup-receiver.sh
```

This script:
1. Copies `config/rsyslog-receiver.conf` → `/etc/rsyslog.d/10-remote-receiver.conf`
2. Creates `/var/log/remote/` with correct permissions (`syslog:adm`)
3. Opens UFW firewall ports 514/tcp and 514/udp
4. Validates the rsyslog config with `rsyslogd -N1`
5. Restarts rsyslog

### Verify

```bash
# After configuring remote hosts, check logs are arriving:
ls /var/log/remote/
# tekaden/  zura/

tail -f /var/log/remote/tekaden/all.log
```

---

## 5. Phase 2 — rsyslog: Remote Host Forwarding

**Goal:** Configure tekaden and zura to forward all their logs to voltron.

### Configuration (`config/rsyslog-forwarder.conf`)

```
*.* action(
    type="omfwd"
    target="192.168.1.129"   # voltron
    port="514"
    protocol="tcp"
    action.resumeRetryCount="10"
    queue.type="linkedList"
    queue.size="10000"
    queue.filename="fwd_to_voltron"
    queue.saveOnShutdown="on"
)
```

**Key concepts:**
- `*.*` — forward every facility and severity
- `omfwd` — output module for forwarding (TCP/UDP)
- `queue.type="linkedList"` — in-memory queue buffers messages if voltron is unreachable
- `queue.saveOnShutdown="on"` — persists buffered messages to disk on shutdown so they are not lost
- `resumeRetryCount="10"` — retries 10 times before dropping

### Installation (from voltron, via SSH)

```bash
# Configure all remote hosts at once
bin/setup-remote.sh

# Or target a single host
bin/setup-remote.sh tekaden
bin/setup-remote.sh zura
```

The script:
1. `scp`s the forwarder config to `/tmp/` on each host
2. SSHes in and runs: move to `/etc/rsyslog.d/`, validate, restart rsyslog

### Why TCP over UDP?

UDP is fire-and-forget. If voltron is temporarily unreachable or overloaded, log messages are silently dropped. TCP with a queue means messages buffer locally and are retransmitted — important for audit logs.

---

## 6. Phase 3 — Log Collection (`collect.sh`)

**Goal:** Copy today's relevant log lines from all sources into a per-day staging directory.

### How it works

```bash
bin/collect.sh [YYYY-MM-DD]     # defaults to today
```

Output: `data/raw/YYYY-MM-DD/<type>_<sanitised-path>.log`

**Two collection modes:**

**1. Local sources** — defined in `config/sources.conf` (TYPE|PATH format):
```
SYSLOG|/var/log/syslog
AUTH|/var/log/auth.log
KERNEL|/var/log/kern.log
WEBSERVER|/var/log/nginx/access.log
APP|/var/log/myapp/app.log
```

**2. Remote sources** — reads from `/var/log/remote/<hostname>/` for each host in `config/hosts.conf`. rsyslog has already written these files; collect.sh just stages them.

### Date filtering

For each file, the script first tests whether any lines match today's date in two formats:
- Short form: `Jun 17` (traditional syslog)
- ISO form: `2026-06-17` (structured/systemd logs)

If matches exist, only those lines are copied — keeping the staging files small. If no date pattern matches (e.g. `dmesg`, `boot.log`), the full file is copied as-is.

```bash
today_pattern="$(date '+%b %_d')"   # "Jun 17"
iso_pattern="$(date '+%Y-%m-%d')"   # "2026-06-17"

if grep -qE "($today_pattern|$iso_pattern)" "$path" 2>/dev/null; then
    grep -E "($today_pattern|$iso_pattern)" "$path" > "$dest"
else
    cp "$path" "$dest"
fi
```

### Why stage at all?

Processing large log files repeatedly is slow. Staging today's lines once means `process.sh` works on small, date-scoped files instead of 246k-line rotated logs.

---

## 7. Phase 4 — Log Classification (`process.sh`)

**Goal:** Read every file in `data/raw/YYYY-MM-DD/` and classify lines into five categories using `grep`, `sed`, and `awk`.

### Categories and patterns

| Category | Pattern (case-insensitive) | Purpose |
|---|---|---|
| **errors** | `error\|fail(ed\|ure)?\|crit(ical)?\|emerg\|panic\|segfault\|oom` | Critical failures |
| **warnings** | `warn(ing)?\|deprecated\|timeout\|retry\|refused\|denied\|throttl` | Non-fatal issues |
| **auth** | `sshd\|sudo\|pam_\|accepted password\|failed password\|invalid user\|useradd` | Security events |
| **web** | `GET\|POST\|HTTP/\|[45][0-9]{2}\|upstream` | Web server traffic |
| **app** | `\[(INFO\|ERROR\|WARN\|FATAL)\]\|level=\|msg=\|exception\|traceback` | Application logs |

Each category file contains source-labelled sections:

```
### SOURCE: auth_var_log_auth.log.log ###
Jun 17 08:12:03 voltron sshd[1234]: Accepted password for ronin from 192.168.1.5
Jun 17 08:15:44 voltron sudo[5678]: ronin : TTY=pts/0 ; COMMAND=/usr/bin/apt
```

### Summary report (awk)

After classification, `process.sh` generates `summary.log` using `awk` for aggregations:

```bash
# Auth event counting with awk
awk '{
    if (/Accepted password/)  acc++
    if (/Failed password/)    fail++
    if (/sudo/)               sudo_c++
    ...
} END { printf "Accepted logins : %d\n", acc+0 }' auth.log

# HTTP status breakdown via grep + sort + uniq + awk pipeline
grep -oE '" [0-9]{3} ' web.log \
    | tr -d '" ' \
    | sort | uniq -c | sort -rn \
    | awk '{printf "  HTTP %s : %d requests\n", $2, $1}'
```

### Important: pipefail safety

With `set -euo pipefail`, a `grep` that finds no matches exits with code 1, which kills the script. All grep pipelines in the summary block are guarded with `|| true`:

```bash
grep -iEo "error..." errors.log | sort | uniq -c | ... || true
```

---

## 8. Phase 5 — Daily Pipeline & Cron

### Pipeline script (`bin/run-daily.sh`)

```bash
sudo bin/run-daily.sh
```

Runs collect → process in sequence. Logs to `data/pipeline-YYYY-MM-DD.log`.

```
[2026-06-17 14:09:27] ====== Daily pipeline start ======
[2026-06-17 14:09:27] Step 1/2: collect
[2026-06-17 14:09:29] collect: OK
[2026-06-17 14:09:29] Step 2/2: process
[2026-06-17 14:10:02] process: OK
[2026-06-17 14:10:02] ====== Pipeline complete. Reports at data/processed/2026-06-17/ ======
```

### Cron job (`cron/log-audit.cron`)

```
5 0 * * * root /home/ronin/projects/log-audit/bin/run-daily.sh >> .../data/cron.log 2>&1
```

Install:
```bash
sudo cp cron/log-audit.cron /etc/cron.d/log-audit
```

Runs at **00:05 daily** as root (needed to read `/var/log/auth.log` and other protected files). The 5-minute offset gives time for midnight log rotation to complete.

---

## 9. Phase 6 — Web Portal (Flask)

### How it works

`web/app.py` is a minimal Flask app with a single route (`/`). It reads processed log files directly from disk — no database.

**URL parameters:**
- `?date=YYYY-MM-DD` — select which day's report to view
- `?cat=errors|warnings|auth|web|app|summary` — select category

```python
def available_dates():
    # Lists all dated directories in data/processed/
    return sorted([d.name for d in PROCESSED_DIR.iterdir()
                   if re.match(r'\d{4}-\d{2}-\d{2}', d.name)], reverse=True)

def read_category(day, category):
    path = PROCESSED_DIR / day / f"{category}.log"
    return path.read_text(errors="replace")
```

### Dashboard features

- Date selector dropdown (most recent first)
- Category sidebar with line counts
- Stat cards on the summary view (errors / warnings / auth / web / app counts)
- Log viewer with syntax highlighting via JavaScript:
  - Red: `error`, `fail`, `critical`
  - Yellow: `warn`, `deprecated`, `timeout`
  - Green: `OK`, `Accepted`, `success`
  - Blue: section headers (`### SOURCE: ...`)

### Running locally

```bash
python3 -m venv .venv
.venv/bin/pip install -r web/requirements.txt
.venv/bin/python web/app.py
# → http://localhost:5055
```

> **Note:** Debian/Ubuntu block system-wide `pip install`. Always use a virtual environment.

---

## 10. Phase 7 — Containerisation (Docker)

### Dockerfile

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils grep gawk sed \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY web/requirements.txt ./web/requirements.txt
RUN pip install --no-cache-dir -r web/requirements.txt
COPY . .

EXPOSE 5055
CMD ["python", "web/app.py"]
```

**Single image** serves both roles:
- **Portal**: default CMD runs Flask
- **Pipeline CronJob**: overrides CMD with `bash bin/run-daily.sh`

The `data/` directory is excluded via `.dockerignore` — it contains root-owned files from the cron pipeline and must not be baked into the image.

### Build and push

```bash
# Build
sudo docker build -t ghcr.io/gbutun/log-audit:latest .

# Authenticate to GitHub Container Registry
gh auth token | sudo docker login ghcr.io -u gbutun --password-stdin

# Push (requires a PAT with write:packages scope)
sudo docker push ghcr.io/gbutun/log-audit:latest
```

---

## 11. Phase 8 — Kubernetes Deployment (microk8s + ArgoCD)

### Cluster overview

| Component | Detail |
|---|---|
| Distribution | microk8s single-node on voltron |
| Ingress | nginx-ingress (class: `public`) |
| Storage | microk8s-hostpath (default StorageClass) |
| TLS | cert-manager, ClusterIssuer `kenshin-ca`, secret `kenshin-wildcard-tls` |
| GitOps | ArgoCD — watches `github.com/gbutun/log-audit`, path `k8s/` |

### Manifest breakdown

**`k8s/namespace.yaml`**
Creates the `log-audit` namespace.

**`k8s/pvc.yaml`**
10Gi PersistentVolumeClaim on `microk8s-hostpath`. Shared between the portal Deployment and the pipeline CronJob. On a single-node cluster, `ReadWriteOnce` is sufficient because both pods are always scheduled on the same node.

**`k8s/deployment.yaml`**
Runs the Flask portal. Mounts the PVC at `/app/data` so it can read processed reports.

```yaml
containers:
  - name: portal
    image: ghcr.io/gbutun/log-audit:latest
    command: ["python", "web/app.py"]
    volumeMounts:
      - name: data
        mountPath: /app/data
```

**`k8s/service.yaml`**
ClusterIP service on port 5055 — exposes the portal to the ingress controller.

**`k8s/ingress.yaml`**
Routes `log-audit.kenshin.local` to the portal service with TLS termination via the existing wildcard certificate.

**`k8s/cronjob.yaml`**
The daily pipeline runs as a K8s CronJob. It needs three volumes:
1. **PVC** — to write processed reports (shared with portal)
2. **hostPath `/var/log`** — read-only access to local system logs
3. **hostPath `/var/log/remote`** — read-only access to rsyslog remote logs

```yaml
spec:
  schedule: "5 0 * * *"
  concurrencyPolicy: Forbid        # prevent overlapping runs
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - command: ["bash", "bin/run-daily.sh"]
              volumeMounts:
                - mountPath: /app/data       # PVC
                - mountPath: /var/log        # host logs (ro)
                - mountPath: /var/log/remote # rsyslog remote logs (ro)
```

**`k8s/argocd-application.yaml`**
Follows the same pattern as all other apps on the cluster:

```yaml
spec:
  source:
    repoURL: https://github.com/gbutun/log-audit.git
    targetRevision: master
    path: k8s
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Deployment steps

```bash
# 1. Build and push the container image
sudo docker build -t ghcr.io/gbutun/log-audit:latest .
sudo docker push ghcr.io/gbutun/log-audit:latest

# 2. Copy the wildcard TLS secret into the new namespace
microk8s kubectl get secret kenshin-wildcard-tls -n art-app -o yaml \
  | sed 's/namespace: art-app/namespace: log-audit/' \
  | microk8s kubectl apply -f -

# 3. Register the ArgoCD application (ArgoCD syncs the rest)
microk8s kubectl apply -f k8s/argocd-application.yaml
```

### Verify deployment

```bash
# Watch pods come up
microk8s kubectl get pods -n log-audit -w

# Trigger the pipeline manually without waiting for cron
microk8s kubectl create job --from=cronjob/log-audit-pipeline manual-test -n log-audit

# Watch the job
microk8s kubectl logs -n log-audit -l job-name=manual-test -f
```

Then browse to `https://log-audit.kenshin.local`.

---

## 12. Configuration Reference

### `config/sources.conf`

```
# TYPE|/path/to/log
SYSLOG|/var/log/syslog
AUTH|/var/log/auth.log
KERNEL|/var/log/kern.log
WEBSERVER|/var/log/nginx/access.log
APP|/var/log/myapp/app.log       # ← add custom app logs here
```

Types are informational labels — they affect the output filename but not the classification logic.

### `config/hosts.conf`

```
# IP  HOSTNAME  FQDN
192.168.1.108  tekaden  tekaden.kenshin.local
192.168.1.120  zura     zura.kenshin.local
```

Add a line here for each host forwarding logs to voltron. The HOSTNAME must match what rsyslog uses when naming the directory under `/var/log/remote/`.

---

## 13. Operational Runbook

### Add a new remote host

1. Add the host to `config/hosts.conf`
2. Run `bin/setup-remote.sh <hostname>` (SSH access required)
3. Verify logs appear: `ls /var/log/remote/<hostname>/`

### Add a new local log source

1. Add a line to `config/sources.conf`: `APP|/path/to/app.log`
2. Next pipeline run picks it up automatically

### Run the pipeline for a past date

```bash
sudo bin/collect.sh 2026-06-15
sudo bin/process.sh 2026-06-15
```

### Rebuild and redeploy the container

```bash
sudo docker build -t ghcr.io/gbutun/log-audit:latest .
sudo docker push ghcr.io/gbutun/log-audit:latest
microk8s kubectl rollout restart deployment/log-audit-portal -n log-audit
```

ArgoCD will detect the new image on the next sync if `imagePullPolicy: Always` is set.

---

## 14. Troubleshooting

### Pipeline fails with "process: FAILED"

Check the process log:
```bash
cat data/process-$(date +%Y-%m-%d).log
```

Common cause: a `grep` pipeline in the summary section found no matches and exited 1. Fixed by adding `|| true` after grep pipelines. See [Phase 4](#7-phase-4--log-classification-processsh).

### No logs from a remote host

```bash
# Is rsyslog forwarding from the remote host?
ssh tekaden "systemctl status rsyslog"

# Is port 514 open on voltron?
sudo ufw status | grep 514

# Is the receiver running?
sudo ss -tlnp | grep 514

# Test manually from tekaden:
logger -n 192.168.1.129 -P 514 --tcp "test message from tekaden"
tail /var/log/remote/tekaden/all.log
```

### Permission denied reading log files

The pipeline runs as root (`sudo bin/run-daily.sh`) because `/var/log/auth.log` is owned by root. The K8s CronJob uses `hostPath` volumes which also require the container to run as root or with appropriate capabilities.

### Portal shows no reports

The portal reads from `data/processed/`. In K8s, this directory lives on the PVC. If the CronJob has not yet run, trigger it manually:
```bash
microk8s kubectl create job --from=cronjob/log-audit-pipeline seed -n log-audit
```

### pip install blocked on Debian/Ubuntu

```bash
# Always use a venv on Debian systems
python3 -m venv .venv
.venv/bin/pip install -r web/requirements.txt
.venv/bin/python web/app.py
```
