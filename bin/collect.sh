#!/usr/bin/env bash
# Collects logs from all configured sources into data/raw/YYYY-MM-DD/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONF="$PROJECT_DIR/config/sources.conf"
DATE="${1:-$(date +%Y-%m-%d)}"
RAW_DIR="$PROJECT_DIR/data/raw/$DATE"
LOG_FILE="$PROJECT_DIR/data/collect-$DATE.log"

mkdir -p "$RAW_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "Starting collection for $DATE"
log "Source config: $CONF"

collected=0
skipped=0

while IFS='|' read -r type path; do
    # Skip blank lines and comments
    [[ -z "$type" || "$type" == \#* ]] && continue

    if [[ ! -f "$path" ]]; then
        log "SKIP [$type] $path (not found)"
        ((skipped++)) || true
        continue
    fi

    # Sanitise path to a safe filename: replace / with _
    safe_name="${type,,}_$(echo "$path" | sed 's|/|_|g; s|^_||').log"
    dest="$RAW_DIR/$safe_name"

    # Copy only lines from today (grep on date prefix) to keep files manageable.
    # Falls back to full copy if no dated lines found (e.g. kern.log, dmesg).
    today_pattern="$(date '+%b %_d')"   # e.g. "Jun 17"
    iso_pattern="$(date '+%Y-%m-%d')"   # e.g. "2026-06-17"

    if grep -qE "($today_pattern|$iso_pattern)" "$path" 2>/dev/null; then
        grep -E "($today_pattern|$iso_pattern)" "$path" > "$dest"
        lines=$(wc -l < "$dest")
        log "OK   [$type] $path -> $safe_name ($lines lines)"
    else
        cp "$path" "$dest"
        lines=$(wc -l < "$dest")
        log "FULL [$type] $path -> $safe_name ($lines lines, no date filter matched)"
    fi

    ((collected++)) || true

done < "$CONF"

# ── Remote hosts: pull from /var/log/remote/<hostname>/ ──────────────────────
REMOTE_LOG_BASE="/var/log/remote"
HOSTS_CONF="$PROJECT_DIR/config/hosts.conf"

if [[ -f "$HOSTS_CONF" && -d "$REMOTE_LOG_BASE" ]]; then
    while IFS=' ' read -r ip hostname fqdn; do
        [[ -z "$ip" || "$ip" == \#* ]] && continue

        host_dir="$REMOTE_LOG_BASE/$hostname"
        # rsyslog may store under FQDN or short hostname — check both
        [[ ! -d "$host_dir" ]] && host_dir="$REMOTE_LOG_BASE/$fqdn"
        if [[ ! -d "$host_dir" ]]; then
            log "SKIP [REMOTE] $hostname — no directory in $REMOTE_LOG_BASE yet"
            ((skipped++)) || true
            continue
        fi

        for f in "$host_dir"/*.log; do
            [[ -f "$f" ]] || continue
            prog=$(basename "$f")
            safe_name="remote_${hostname}_${prog}"
            dest="$RAW_DIR/$safe_name"

            if grep -qE "($today_pattern|$iso_pattern)" "$f" 2>/dev/null; then
                grep -E "($today_pattern|$iso_pattern)" "$f" > "$dest"
            else
                cp "$f" "$dest"
            fi
            lines=$(wc -l < "$dest")
            log "OK   [REMOTE:$hostname] $prog ($lines lines)"
            ((collected++)) || true
        done

    done < "$HOSTS_CONF"
else
    log "INFO: No remote log directory ($REMOTE_LOG_BASE) or hosts.conf — skipping remote collection"
fi

log "Done. Collected: $collected, Skipped: $skipped"
log "Output: $RAW_DIR"
