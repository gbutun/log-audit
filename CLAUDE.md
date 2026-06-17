# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

A log aggregation and audit pipeline for a small homelab network. Logs from remote Linux hosts are forwarded to this machine (voltron, 192.168.1.129) via rsyslog, then collected, classified with shell tools (grep/sed/awk), and served in a daily Flask dashboard.

## Hosts

| Role | Hostname | IP |
|---|---|---|
| Central server (this machine) | voltron | 192.168.1.129 |
| Remote host | tekaden | 192.168.1.108 |
| Remote host | zura | 192.168.1.120 |

## Running the pipeline

```bash
# Run the full daily collect + process pipeline (needs sudo to read /var/log)
sudo bin/run-daily.sh

# Run stages individually
sudo bin/collect.sh          # collects into data/raw/YYYY-MM-DD/
bin/process.sh               # classifies into data/processed/YYYY-MM-DD/

# Start the web portal (http://localhost:5055)
.venv/bin/python web/app.py
```

## One-time setup

```bash
# 1. Set up voltron as the rsyslog receiver
sudo bin/setup-receiver.sh

# 2. Push forwarder config to tekaden and zura via SSH
bin/setup-remote.sh           # all hosts
bin/setup-remote.sh tekaden   # single host

# 3. Install Python dependencies
python3 -m venv .venv
.venv/bin/pip install -r web/requirements.txt

# 4. Install the cron job
sudo cp cron/log-audit.cron /etc/cron.d/log-audit
```

## Architecture

```
rsyslog (tekaden, zura) ──TCP 514──▶ rsyslog (voltron)
                                          │
                                    /var/log/remote/<hostname>/
                                          │
                                    bin/collect.sh
                                          │ copies today's lines
                                    data/raw/YYYY-MM-DD/
                                          │
                                    bin/process.sh
                                          │ grep/sed/awk
                                    data/processed/YYYY-MM-DD/
                                    ├── errors.log
                                    ├── warnings.log
                                    ├── auth.log
                                    ├── web.log
                                    ├── app.log
                                    └── summary.log
                                          │
                                    web/app.py (Flask :5055)
```

**collect.sh** reads two sources:
1. Local paths listed in `config/sources.conf` (TYPE|PATH format)
2. Remote logs in `/var/log/remote/<hostname>/` for each host in `config/hosts.conf`

It filters to today's lines using date patterns (`Jun 17` / `2026-06-17`) before copying.

**process.sh** runs `classify()` against every file in `data/raw/YYYY-MM-DD/`, appending matches to category files. The summary at the end uses awk for auth event counts and HTTP status code breakdowns.

**web/app.py** serves a single route (`/`) parameterised by `?date=` and `?cat=`. It reads processed files directly from disk — no database.

## Configuration files

- `config/sources.conf` — local log paths to collect (add `APP|/path/to/app.log` lines here)
- `config/hosts.conf` — remote host inventory (IP, short hostname, FQDN)
- `config/rsyslog-receiver.conf` — deploy to `/etc/rsyslog.d/` on voltron
- `config/rsyslog-forwarder.conf` — deployed to remote hosts by `setup-remote.sh`

## Key constraints

- Scripts require `sudo` to read `/var/log/auth.log` and other root-owned logs.
- The `.venv/` is the Python environment — never use system `pip` (Debian blocks it).
- Remote logs land under `/var/log/remote/<hostname>/` keyed by the hostname rsyslog reports; if a host sends its FQDN, the directory will be the FQDN. Check `config/hosts.conf` for both short and FQDN entries.
- The cron job runs at 00:05 daily as root (see `cron/log-audit.cron`).
