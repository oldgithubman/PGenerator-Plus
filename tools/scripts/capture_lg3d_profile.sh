#!/usr/bin/env bash
# Poll live LG 3D LUT AutoCal state on the Pi and write a re-solvable snapshot.
# Usage: capture_lg3d_profile.sh [PI_IP] [OUTDIR]
set -euo pipefail
PI="${1:-192.168.1.167}"
OUTDIR="${2:-}"
if [[ -z "$OUTDIR" ]]; then
  TS=$(date +%Y%m%d-%H%M%S)
  OUTDIR="data/3d-lut-profiles/hybrid-capture-${TS}"
fi
mkdir -p "$OUTDIR"
export SSHPASS="${SSHPASS:-PGenerator!!$}"
SSH=(sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts root@"$PI")
SCP=(sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/pgen_known_hosts)

pull() {
  "${SCP[@]}" -q \
    root@"$PI":/tmp/meter_lg_3d_autocal.json \
    root@"$PI":/tmp/meter_lg_3d_autocal_config.json \
    root@"$PI":/tmp/meter_lg_3d_autocal.log \
    "$OUTDIR/" 2>/dev/null || true
}

finalize() {
  python3 - "$OUTDIR" <<'PY'
import csv, json, sys, time
from pathlib import Path
outdir = Path(sys.argv[1])
st_path = outdir / "meter_lg_3d_autocal.json"
if not st_path.exists():
    print("no state file", file=sys.stderr)
    sys.exit(1)
st = json.loads(st_path.read_text())
cfg = {}
cp = outdir / "meter_lg_3d_autocal_config.json"
if cp.exists():
    try:
        cfg = json.loads(cp.read_text())
    except Exception:
        cfg = {}
readings = st.get("readings") or []
profile = [r for r in readings if str(r.get("phase") or "") != "post_check"]
lattice = []
for r in profile:
    name = r.get("name") or ""
    if not isinstance(name, str):
        continue
    parts = name.split("/")
    if len(parts) != 3:
        continue
    try:
        float(parts[0]); float(parts[1]); float(parts[2])
    except Exception:
        continue
    lattice.append({
        "name": name,
        "X": r.get("X"), "Y": r.get("Y"), "Z": r.get("Z"),
        "x": r.get("x"), "y": r.get("y"),
        "luminance": r.get("luminance", r.get("Y")),
        "kind": r.get("kind"),
        "level": r.get("level"),
        "phase": r.get("phase"),
        "r_code": r.get("r_code"), "g_code": r.get("g_code"), "b_code": r.get("b_code"),
        "ire": r.get("ire"), "stimulus": r.get("stimulus"),
        "signal_mode": r.get("signal_mode"),
        "target_gamut": r.get("target_gamut"),
        "target_gamma": r.get("target_gamma"),
        "timestamp": r.get("timestamp"),
        "cct": r.get("cct"),
    })

sig = st.get("signal_mode") or cfg.get("signal_mode") or cfg.get("requested_signal_mode") or "sdr"
gamut = st.get("target_gamut") or cfg.get("target_gamut") or "bt709"
gamma = st.get("target_gamma") or cfg.get("target_gamma") or "bt1886"
payload = {
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "source": "live Pi 3D LUT AutoCal snapshot",
    "status": st.get("status"),
    "method": st.get("method") or cfg.get("method") or "hybrid",
    "phase": st.get("phase"),
    "profile_total": st.get("profile_total") or st.get("profile_patch_count"),
    "profile_current": st.get("profile_current"),
    "signal_mode": sig,
    "target_gamut": gamut,
    "target_gamma": gamma,
    "lut_solve_gamma": st.get("lut_solve_gamma"),
    "white_y": st.get("white_y"),
    "lattice_drift": st.get("lattice_drift") or st.get("volume_drift"),
    "lattice_solve": st.get("lattice_solve"),
    "export": st.get("export"),
    "reading_count": len(profile),
    "lattice_node_count": len(lattice),
    "lattice_readings": lattice,
    "raw_readings": profile,
    "config": {
        "method": cfg.get("method"),
        "signal_mode": sig,
        "target_gamut": gamut,
        "target_gamma": gamma,
        "signal_range": cfg.get("signal_range") or cfg.get("pattern_signal_range"),
        "transport_signal_range": cfg.get("transport_signal_range"),
        "max_bpc": cfg.get("max_bpc"),
        "patch_size": cfg.get("patch_size"),
        "delay_ms": cfg.get("delay_ms"),
        "display_type": cfg.get("display_type"),
        "picture_mode": cfg.get("picture_mode"),
        "solve_matrix_only": cfg.get("solve_matrix_only"),
        "lattice_patches": cfg.get("lattice_patches"),
    },
}
solve_body = {
    "signal_mode": sig,
    "requested_signal_mode": sig,
    "target_gamut": gamut,
    "target_gamma": gamma,
    "display_type": payload["config"].get("display_type") or "",
    "solve_cube_size": 33,
    "lattice_readings": [
        {"name": n["name"], "X": n["X"], "Y": n["Y"], "Z": n["Z"]}
        for n in lattice
        if n.get("Y") is not None or n.get("name") == "0/0/0"
    ],
}
(outdir / "hybrid_profile_capture.json").write_text(json.dumps(payload, indent=2) + "\n")
(outdir / "solve_only_payload.json").write_text(json.dumps(solve_body, indent=2) + "\n")
with open(outdir / "lattice_readings.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["name","X","Y","Z","x","y","luminance","kind","r_code","g_code","b_code","timestamp"])
    for n in lattice:
        w.writerow([n.get(k) for k in ["name","X","Y","Z","x","y","luminance","kind","r_code","g_code","b_code","timestamp"]])
readme = f"""# 3D LUT profile capture ({payload['method']})

- Captured: {payload['captured_at']}
- Run status: {payload['status']} phase={payload['phase']}
- Method: {payload['method']}
- Signal: {payload['signal_mode']} / {payload['target_gamut']} / {payload['target_gamma']}
- Profile patches stored: {payload['lattice_node_count']} (of {payload['profile_total']})

## Files

- hybrid_profile_capture.json — full capture (readings + config + meta)
- solve_only_payload.json — body for re-solve via /api/3d-lut/solve
- lattice_readings.csv — XYZ by patch name
- meter_lg_3d_autocal.json — last raw worker state
- meter_lg_3d_autocal_config.json — worker config
- meter_lg_3d_autocal.log — worker log

## Re-solve without re-measuring

```bash
curl -sS -X POST http://PI/api/3d-lut/solve \\
  -H 'Content-Type: application/json' \\
  --data-binary @solve_only_payload.json
curl -sS http://PI/api/3d-lut/solve/status
```

Corner requirements for residual solve: 100/100/100, 100/0/0, 0/100/0, 0/0/100 (and ideally 0/0/0).
"""
(outdir / "README.md").write_text(readme)
print(f"FINAL {outdir}")
print(f"status={payload['status']} nodes={payload['lattice_node_count']}/{payload['profile_total']}")
print(f"solve_readings={len(solve_body['lattice_readings'])}")
PY
}

echo "capturing to $OUTDIR" | tee -a "$OUTDIR/capture.log"
while true; do
  pull
  if [[ -f "$OUTDIR/meter_lg_3d_autocal.json" ]]; then
    line=$(python3 -c "import json;s=json.load(open('$OUTDIR/meter_lg_3d_autocal.json'));print(s.get('status',''),s.get('phase',''),s.get('profile_current',0),s.get('profile_total',0),len(s.get('readings') or []))")
    echo "$(date -Iseconds) $line" | tee -a "$OUTDIR/capture.log"
    # progressive extract so we always have something if capture is interrupted
    finalize || true
    status=$(python3 -c "import json;print(json.load(open('$OUTDIR/meter_lg_3d_autocal.json')).get('status',''))")
    if [[ "$status" == "complete" || "$status" == "error" || "$status" == "cancelled" || "$status" == "idle" ]]; then
      break
    fi
  else
    echo "$(date -Iseconds) no-state-yet" | tee -a "$OUTDIR/capture.log"
  fi
  sleep 8
done
finalize
echo "DONE" | tee -a "$OUTDIR/capture.log"
echo "$OUTDIR"
