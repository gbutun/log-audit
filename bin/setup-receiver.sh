#!/usr/bin/env bash
# Configures THIS machine (voltron) as the central rsyslog receiver.
# Run once with sudo: sudo bin/setup-receiver.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RECEIVER_CONF="$PROJECT_DIR/config/rsyslog-receiver.conf"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo: sudo bin/setup-receiver.sh"
    exit 1
fi

log "Setting up rsyslog receiver on $(hostname)"

# 1. Install receiver config
log "Installing /etc/rsyslog.d/10-remote-receiver.conf ..."
cp "$RECEIVER_CONF" /etc/rsyslog.d/10-remote-receiver.conf
chown root:root /etc/rsyslog.d/10-remote-receiver.conf
chmod 644 /etc/rsyslog.d/10-remote-receiver.conf

# 2. Create remote log directory
log "Creating /var/log/remote/ ..."
mkdir -p /var/log/remote
chown syslog:adm /var/log/remote
chmod 750 /var/log/remote

# 3. Open firewall port 514 (UFW)
if command -v ufw &>/dev/null; then
    log "Opening UFW port 514/tcp and 514/udp ..."
    ufw allow 514/tcp comment "rsyslog remote receiver"
    ufw allow 514/udp comment "rsyslog remote receiver"
    ufw reload
else
    log "UFW not found — open port 514 manually if you have a firewall."
fi

# 4. Validate and restart rsyslog
log "Validating rsyslog config ..."
rsyslogd -N1

log "Restarting rsyslog ..."
systemctl restart rsyslog
systemctl is-active rsyslog && log "rsyslog is running."

log ""
log "Done. Remote logs will appear in /var/log/remote/<hostname>/"
log "Test with:  logger -n 127.0.0.1 -P 514 --tcp 'test from voltron'"
