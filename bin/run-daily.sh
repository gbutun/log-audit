#!/usr/bin/env bash
# Master daily pipeline: collect → process.
# Called by cron; logs overall status to data/pipeline-YYYY-MM-DD.log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATE="$(date +%Y-%m-%d)"
PIPELINE_LOG="$PROJECT_DIR/data/pipeline-$DATE.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$PIPELINE_LOG"; }

log "====== Daily pipeline start ======"

log "Step 1/2: collect"
bash "$SCRIPT_DIR/collect.sh" "$DATE" && log "collect: OK" || { log "collect: FAILED"; exit 1; }

log "Step 2/2: process"
bash "$SCRIPT_DIR/process.sh" "$DATE" && log "process: OK" || { log "process: FAILED"; exit 1; }

log "====== Pipeline complete. Reports at data/processed/$DATE/ ======"
