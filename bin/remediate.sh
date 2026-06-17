#!/usr/bin/env bash
# Scans processed category logs against remediation-rules.conf.
# Outputs data/processed/YYYY-MM-DD/remediation.log (combined)
# and    data/processed/YYYY-MM-DD/hosts/<hostname>/remediation.log (per-host)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATE="${1:-$(date +%Y-%m-%d)}"
OUT_DIR="$PROJECT_DIR/data/processed/$DATE"
RULES="$PROJECT_DIR/config/remediation-rules.conf"
LOG_FILE="$PROJECT_DIR/data/process-$DATE.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [[ ! -d "$OUT_DIR" ]]; then
    log "ERROR: Processed directory not found: $OUT_DIR — run process.sh first"
    exit 1
fi

if [[ ! -f "$RULES" ]]; then
    log "ERROR: Rules file not found: $RULES"
    exit 1
fi

log "Running remediation analysis for $DATE"

# ── Write findings for a given scope (combined or per-host) ──────────────────
# Args: $1 = scope label ("all" or hostname), $2 = directory containing category files
# $3 = output file path
run_analysis() {
    local scope="$1"
    local src_dir="$2"
    local output="$3"

    local finding_count=0
    local critical=0 high=0 medium=0 low=0 info_c=0

    # Temp file for findings (so we can count before writing the header)
    local tmpfile
    tmpfile=$(mktemp)

    while IFS='|' read -r category pattern severity title steps; do
        [[ -z "$category" || "$category" == \#* ]] && continue
        [[ -z "$pattern" || -z "$severity" || -z "$title" || -z "$steps" ]] && continue

        local cat_file="$src_dir/${category}.log"
        [[ -f "$cat_file" ]] || continue

        # Count matching lines
        local match_count
        match_count=$(grep -icE "$pattern" "$cat_file" 2>/dev/null || true)
        [[ "$match_count" -eq 0 ]] && continue

        # Collect sample lines (up to 3 unique examples)
        local samples
        samples=$(grep -iE "$pattern" "$cat_file" 2>/dev/null \
            | sed 's/^[[:space:]]*//' \
            | sort -u \
            | head -3 \
            || true)

        # Track severity counts
        case "$severity" in
            CRITICAL) ((critical++)) ;;
            HIGH)     ((high++))     ;;
            MEDIUM)   ((medium++))   ;;
            LOW)      ((low++))      ;;
            INFO)     ((info_c++))   ;;
        esac
        ((finding_count++)) || true

        # Write finding block
        {
            printf '\n'
            printf '┌─────────────────────────────────────────────────────────┐\n'
            printf '│ [%s] %s\n' "$severity" "$title"
            printf '│ Category: %-10s  Matches: %d\n' "$category" "$match_count"
            printf '├─────────────────────────────────────────────────────────┤\n'
            printf '│ SAMPLE LOG LINES:\n'
            while IFS= read -r line; do
                # Truncate long lines for readability
                printf '│   %.110s\n' "$line"
            done <<< "$samples"
            printf '├─────────────────────────────────────────────────────────┤\n'
            printf '│ REMEDIATION STEPS:\n'
            # Steps are semicolon-separated; split and print each
            IFS=';' read -ra step_arr <<< "$steps"
            for step in "${step_arr[@]}"; do
                step="${step#"${step%%[! ]*}"}"  # ltrim
                printf '│   %s\n' "$step"
            done
            printf '└─────────────────────────────────────────────────────────┘\n'
        } >> "$tmpfile"

    done < "$RULES"

    # Write final output file
    {
        printf '==================================================\n'
        printf '  REMEDIATION REPORT — %s\n' "$DATE"
        if [[ "$scope" != "all" ]]; then
            printf '  HOST: %s\n' "$scope"
        fi
        printf '==================================================\n\n'

        if [[ "$finding_count" -eq 0 ]]; then
            printf 'No rule matches found. Logs look clean.\n'
        else
            printf 'Findings: %d total\n' "$finding_count"
            printf '  CRITICAL : %d\n' "$critical"
            printf '  HIGH     : %d\n' "$high"
            printf '  MEDIUM   : %d\n' "$medium"
            printf '  LOW      : %d\n' "$low"
            printf '  INFO     : %d\n' "$info_c"
            printf '\n'
            cat "$tmpfile"
        fi

        printf '\n==================================================\n'
        printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '==================================================\n'
    } > "$output"

    rm -f "$tmpfile"
    echo "$finding_count"
}

# ── Combined (all hosts) ──────────────────────────────────────────────────────
combined_findings=$(run_analysis "all" "$OUT_DIR" "$OUT_DIR/remediation.log")
log "Combined remediation: $combined_findings finding(s) → remediation.log"

# ── Per-host ──────────────────────────────────────────────────────────────────
for host_dir in "$OUT_DIR/hosts"/*/; do
    [[ -d "$host_dir" ]] || continue
    host=$(basename "$host_dir")
    host_findings=$(run_analysis "$host" "$host_dir" "$host_dir/remediation.log")
    log "Host [$host] remediation: $host_findings finding(s)"
done

log "Remediation analysis complete."
