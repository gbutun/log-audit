#!/usr/bin/env bash
# Pushes rsyslog forwarder config to all hosts in config/hosts.conf via SSH.
# Requirements: SSH key access to each host (or will prompt for password).
# Usage:
#   bin/setup-remote.sh              # configure all hosts
#   bin/setup-remote.sh tekaden      # configure a single host by name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOSTS_CONF="$PROJECT_DIR/config/hosts.conf"
FORWARDER_CONF="$PROJECT_DIR/config/rsyslog-forwarder.conf"
TARGET_HOST="${1:-}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Remote rsyslog forwarder setup"
log "Forwarder config: $FORWARDER_CONF"
echo

while IFS=' ' read -r ip hostname fqdn; do
    [[ -z "$ip" || "$ip" == \#* ]] && continue

    # Filter to a single host if argument given
    if [[ -n "$TARGET_HOST" && "$TARGET_HOST" != "$hostname" && "$TARGET_HOST" != "$ip" && "$TARGET_HOST" != "$fqdn" ]]; then
        continue
    fi

    log "─── Configuring $hostname ($ip) ───"

    # 1. Copy the forwarder config
    log "  Copying rsyslog forwarder config..."
    scp "$FORWARDER_CONF" "${ip}:/tmp/50-forward-to-voltron.conf"

    # 2. Install it and restart rsyslog
    ssh "$ip" bash -s << 'REMOTE'
set -e
sudo mv /tmp/50-forward-to-voltron.conf /etc/rsyslog.d/50-forward-to-voltron.conf
sudo chown root:root /etc/rsyslog.d/50-forward-to-voltron.conf
sudo chmod 644 /etc/rsyslog.d/50-forward-to-voltron.conf
echo "  Validating rsyslog config..."
sudo rsyslogd -N1
echo "  Restarting rsyslog..."
sudo systemctl restart rsyslog
echo "  rsyslog status:"
sudo systemctl is-active rsyslog
REMOTE

    log "  $hostname: done"
    echo

done < "$HOSTS_CONF"

log "All hosts configured."
log "Check incoming logs on voltron at: /var/log/remote/"
