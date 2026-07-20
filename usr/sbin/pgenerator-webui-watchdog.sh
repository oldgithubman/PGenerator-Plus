#!/bin/sh
# Keep PGenerator WebUI (port 80) alive if the daemon exits unexpectedly.
# Installed as a cron every-minute helper on the device.

PID_FILE=/var/run/PGenerator/PGeneratord.pl.pid
LOG=/tmp/pgenerator-watchdog.log
MAX_LOG=50

log() {
  ts=$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "?")
  echo "$ts $*" >>"$LOG" 2>/dev/null
  # keep log short
  if [ -f "$LOG" ]; then
    lines=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG" ] 2>/dev/null; then
      tail -n 30 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    fi
  fi
}

# Already listening?
if wget -q -O /dev/null -T 2 http://127.0.0.1/api/ping 2>/dev/null; then
  exit 0
fi

# Avoid thrash if init is mid-restart
if [ -f /tmp/pgenerator-watchdog.lock ]; then
  # stale lock older than 120s?
  age=0
  if [ -n "$(find /tmp/pgenerator-watchdog.lock -mmin +2 2>/dev/null)" ]; then
    rm -f /tmp/pgenerator-watchdog.lock
  else
    exit 0
  fi
fi
touch /tmp/pgenerator-watchdog.lock

log "WebUI down — restarting PGenerator"
/etc/init.d/PGenerator restart >>"$LOG" 2>&1
sleep 4
if wget -q -O /dev/null -T 3 http://127.0.0.1/api/ping 2>/dev/null; then
  log "WebUI recovered"
else
  log "WebUI still down after restart"
fi
rm -f /tmp/pgenerator-watchdog.lock
exit 0
