#!/usr/bin/env bash
# Classifies raw collected logs into categories using grep/sed/awk.
# Outputs:
#   data/processed/YYYY-MM-DD/{errors,warnings,auth,web,app,summary}.log  (combined)
#   data/processed/YYYY-MM-DD/hosts/<hostname>/{errors,warnings,auth,web,app}.log (per-host)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATE="${1:-$(date +%Y-%m-%d)}"
RAW_DIR="$PROJECT_DIR/data/raw/$DATE"
OUT_DIR="$PROJECT_DIR/data/processed/$DATE"
LOG_FILE="$PROJECT_DIR/data/process-$DATE.log"

mkdir -p "$OUT_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [[ ! -d "$RAW_DIR" ]]; then
    log "ERROR: Raw directory not found: $RAW_DIR — run collect.sh first"
    exit 1
fi

log "Processing raw logs from $RAW_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Derive hostname from a raw filename:
#   remote_tekaden_sshd-session.log  → tekaden
#   remote_zura_all.log              → zura
#   auth_var_log_auth.log.log        → voltron  (local files)
#   syslog_var_log_syslog.log        → voltron
hostname_from_file() {
    local fname
    fname=$(basename "$1")
    if [[ "$fname" == remote_* ]]; then
        echo "$fname" | cut -d_ -f2
    else
        echo "voltron"
    fi
}

# Append SOURCE header + matching lines to both the combined and per-host file
classify() {
    local category="$1"
    local source_file="$2"
    local pattern="$3"
    local host
    host=$(hostname_from_file "$source_file")
    local source_label
    source_label=$(basename "$source_file")

    local matches
    matches=$(grep -iE "$pattern" "$source_file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        # Combined output
        printf '\n### SOURCE: %s [host: %s] ###\n' "$source_label" "$host" \
            >> "$OUT_DIR/${category}.log"
        echo "$matches" >> "$OUT_DIR/${category}.log"

        # Per-host output
        local host_dir="$OUT_DIR/hosts/$host"
        mkdir -p "$host_dir"
        printf '\n### SOURCE: %s ###\n' "$source_label" >> "$host_dir/${category}.log"
        echo "$matches" >> "$host_dir/${category}.log"
    fi
}

# ── Clear combined output files ───────────────────────────────────────────────
for cat in errors warnings auth web app; do
    > "$OUT_DIR/${cat}.log"
done

# ── Process each collected file ───────────────────────────────────────────────
for f in "$RAW_DIR"/*.log; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f")
    host=$(hostname_from_file "$f")
    log "Processing: $fname [host: $host]"

    classify "errors" "$f" \
        "error|fail(ed|ure)?|crit(ical)?|emerg(ency)?|alert|panic|segfault|oom|out of memory|killed process"

    classify "warnings" "$f" \
        "warn(ing)?|deprecated|timeout|retry|slow|refused|denied|throttl"

    classify "auth" "$f" \
        "sshd|sudo|pam_|su\[|accepted password|failed password|invalid user|session opened|session closed|authentication failure|new user|new group|useradd|userdel|passwd"

    classify "web" "$f" \
        '"(GET|POST|PUT|DELETE|PATCH|HEAD) |HTTP/[0-9]| [45][0-9]{2} |upstream|proxy_pass|upstream timed out'

    classify "app" "$f" \
        '\[(INFO|DEBUG|WARN|ERROR|FATAL|TRACE)\]|level=(info|debug|warn|error)|msg=|message=|exception|traceback|stack trace'

done

# ── Per-host summary stub files (so portal can discover hosts) ────────────────
for host_dir in "$OUT_DIR/hosts"/*/; do
    [[ -d "$host_dir" ]] || continue
    host=$(basename "$host_dir")
    for cat in errors warnings auth web app; do
        # Ensure all category files exist even if empty
        touch "$host_dir/${cat}.log"
    done
    # Per-host line counts
    {
        printf '=== HOST: %s — %s ===\n\n' "$host" "$DATE"
        for cat in errors warnings auth web app; do
            count=$(grep -c '^' "$host_dir/${cat}.log" 2>/dev/null || true)
            printf '%-12s  %5d lines\n' "$(echo "$cat" | tr a-z A-Z):" "$count"
        done
        printf '\n'
    } > "$host_dir/summary.log"
    log "Per-host output: hosts/$host/ ($(ls "$host_dir"/*.log | wc -l) files)"
done

# ── Combined summary report (awk) ─────────────────────────────────────────────
SUMMARY="$OUT_DIR/summary.log"
{
    printf '==================================================\n'
    printf '  LOG AUDIT SUMMARY — %s\n' "$DATE"
    printf '==================================================\n\n'

    # Hosts seen
    hosts_seen=()
    for h in "$OUT_DIR/hosts"/*/; do
        [[ -d "$h" ]] && hosts_seen+=("$(basename "$h")")
    done
    printf 'Hosts:        %s\n\n' "${hosts_seen[*]:-none}"

    for cat in errors warnings auth web app; do
        file="$OUT_DIR/${cat}.log"
        if [[ -f "$file" && -s "$file" ]]; then
            count=$(grep -c '^' "$file" || true)
            sources=$(grep -c '^### SOURCE:' "$file" || true)
            printf '%-12s  %5d lines  from %d source(s)\n' \
                "$(echo "$cat" | tr '[:lower:]' '[:upper:]'):" "$count" "$sources"
        else
            printf '%-12s  %5d lines\n' "$(echo "$cat" | tr '[:lower:]' '[:upper:]'):" 0
        fi
    done

    printf '\n--------------------------------------------------\n'
    printf 'Top error patterns (errors.log):\n'
    if [[ -s "$OUT_DIR/errors.log" ]]; then
        grep -iEo "error[^:,\n]{0,40}|fail[^:,\n]{0,40}" "$OUT_DIR/errors.log" 2>/dev/null \
            | sed 's/[[:space:]]\+/ /g' \
            | sort | uniq -c | sort -rn \
            | head -10 \
            | awk '{printf "  %5d x  %s\n", $1, substr($0, index($0,$2))}' \
            || true
    else
        printf '  (none)\n'
    fi

    printf '\n--------------------------------------------------\n'
    printf 'Top auth events (auth.log):\n'
    if [[ -s "$OUT_DIR/auth.log" ]]; then
        awk '{
            if (/Accepted password/)  acc++
            if (/Failed password/)    fail++
            if (/Invalid user/)       inv++
            if (/sudo/)               sudo_c++
            if (/session opened/)     sess_open++
            if (/session closed/)     sess_close++
        }
        END {
            printf "  Accepted logins : %d\n", acc+0
            printf "  Failed logins   : %d\n", fail+0
            printf "  Invalid users   : %d\n", inv+0
            printf "  Sudo events     : %d\n", sudo_c+0
            printf "  Sessions opened : %d\n", sess_open+0
            printf "  Sessions closed : %d\n", sess_close+0
        }' "$OUT_DIR/auth.log"
    else
        printf '  (none)\n'
    fi

    printf '\n--------------------------------------------------\n'
    printf 'HTTP status code breakdown (web.log):\n'
    if [[ -s "$OUT_DIR/web.log" ]]; then
        grep -oE '" [0-9]{3} ' "$OUT_DIR/web.log" 2>/dev/null \
            | tr -d '" ' \
            | sort | uniq -c | sort -rn \
            | awk '{printf "  HTTP %s : %d requests\n", $2, $1}' \
            | head -15 \
            || true
    else
        printf '  (none)\n'
    fi

    printf '\n==================================================\n'
    printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '==================================================\n'
} > "$SUMMARY"

log "Summary written to $SUMMARY"
log "Processing complete. Output: $OUT_DIR"
