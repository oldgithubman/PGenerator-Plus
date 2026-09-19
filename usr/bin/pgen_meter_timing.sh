#!/bin/bash
# Read the Linux monotonic clock without launching a process per phase. The
# Perl fallback keeps the helper usable in macOS shell regression tests.
meter_clock_ms() {
 local meter_uptime meter_rest meter_whole meter_fraction
 if [[ -r /proc/uptime ]] && read -r meter_uptime meter_rest < /proc/uptime; then
  meter_whole=${meter_uptime%%.*}
  meter_fraction=${meter_uptime#*.}000
  METER_CLOCK_MS=$((10#$meter_whole * 1000 + 10#${meter_fraction:0:3}))
 else
  METER_CLOCK_MS=$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f", clock_gettime(CLOCK_MONOTONIC)*1000' 2>/dev/null) || METER_CLOCK_MS=0
 fi
}

meter_timing_start() {
 meter_clock_ms
 METER_READ_STARTED_MS=$METER_CLOCK_MS
 METER_PATTERN_DONE_MS=$METER_CLOCK_MS
 METER_SETTLE_DONE_MS=$METER_CLOCK_MS
}

meter_timing_finish() {
 meter_clock_ms
 # Measurement includes integration, averaging, retries and result parsing.
 # Only advertise a timing breakdown when every clock sample was available.
 METER_TIMING_JSON='{}'
 if (( METER_READ_STARTED_MS > 0 && METER_PATTERN_DONE_MS >= METER_READ_STARTED_MS && METER_SETTLE_DONE_MS >= METER_PATTERN_DONE_MS && METER_CLOCK_MS >= METER_SETTLE_DONE_MS )); then
  METER_TIMING_JSON="{\"pattern_ms\":$((METER_PATTERN_DONE_MS-METER_READ_STARTED_MS)),\"settle_ms\":$((METER_SETTLE_DONE_MS-METER_PATTERN_DONE_MS)),\"measurement_ms\":$((METER_CLOCK_MS-METER_SETTLE_DONE_MS)),\"total_ms\":$((METER_CLOCK_MS-METER_READ_STARTED_MS))}"
 fi
}
