# PR14 automation safety and regression contracts

Hardening baseline: `6b929baec0aed06ac3a385c74239b056eb8b9dc3`.
These changes preserve calibration algorithms, LUT geometry, solver targets and
existing audit-only workflows. They are not physical TV certification.

## Ownership and durable state

The existing attempt/acceptance handshake remains mandatory before device work.
Production runner arguments contain the run ID, `--launch` and a non-secret
attempt ID. A small owner-only launch journal supplies the token without parsing
the full manifest before the handshake. Automation directories are private and
new records/configuration files containing credentials are owner-only. The
legacy explicit-token CLI remains available for compatibility; do not use it in
process launchers or diagnostic commands whose arguments may be logged.

Journal publication syncs the temporary file, renames it, then syncs the parent
directory; deletion also syncs the directory. Persistence errors propagate. A
missing ownership record is distinct from an unreadable/malformed record; the
latter blocks new device work. An unreadable run manifest never authorises
claim deletion. Preserve and repair recovery evidence; do not delete an
uncertain claim merely to unblock another calibration.

Locks are bounded. The listener is non-blocking, as is its overload response,
and silent browser preconnect sockets do not occupy request workers. Existing
appliance allocator mitigation remains unchanged. The loopback test covers
repeated failed starts and silent clients, not reproduction of a Pi/glibc
allocator deadlock. That original hardware report still requires confirmation.

## Cleanup and Pause

A panel-protection restoration obligation is written before any disable is sent.
Partial dispatch, a lost reply, artifact failure and process interruption cannot
silently erase it. Finalisation checks protection, protective settings, preflight,
viewing-context, worker/CAL_END and meter obligations. Failed restoration leaves
an interrupted, owned run with Retry cleanup; Clear, Delete and Resume cannot
bypass it. A successful retry clears stale failure records.

A TV without a readback API cannot supply verified TPC/GSR values. Successful
re-enable dispatch is labelled `sent-unverified`, not fabricated readback. The
runner's existing conservative end state is to enable both controls, not claim
it recovered an unknowable original value.

Pause safely parks at a checkpoint: workers and meter stop, calibration mode
closes, temporary protective settings are restored, and results/checkpoints are
retained. Resume reconstructs and checks the required settings and saved profile
baseline without unnecessarily repeating completed calibration. Failed parking
is cleanup-required; Retry cleanup preserves the pending Pause. Boot recovery
also notices older paused manifests with outstanding protective changes.

## Whole-queue checks and the C1 regression

Readable TVs retain strict reversible whole-queue probing. Independent original
modes, input and compatibility signatures are required; an unexpected read
failure or virtual/echoed selector does not become valid restoration evidence.

For a reviewed legacy profile explicitly reporting unavailable mode readback,
preflight performs scoped compatibility checks without changing signal or
picture mode. Each job is labelled `checked-limited`, not live-mode verified.
Its real signal/mode is still selected and settings rechecked before calibration,
using the existing matrix-authorised accepted-write/manual-control path.
No guessed original mode is recorded or restored. This narrows the consequence
of the legacy flag without changing DDC generation classification globally.

Preflight restoration and run-level viewing restoration use separate journals.
The queue's `finish_policy` defaults to `restore-original`; `keep-last` leaves the
final calibrated mode selected. Temporary protection restoration is mandatory
for either policy. Original selection/transport restoration never rewrites the
new LUT. Known unreadable original modes yield output-only restoration with an
explicit limited outcome. A neutral grey pattern, not the previous arbitrary
image/video, is the idle output.

## Retry, measurements and reporting

Reconnection alone does not permit repeating a destructive mutation. A reset or
other non-repeatable action may be retried only with evidence it was not sent.
Ambiguous post-send connection loss remains an actionable unknown outcome.
Absolute-value writes and explicit idempotent reads retain bounded recovery.

Each worker launch carries an attempt ID. Seeded and subsequent status records
retain it; the worker adds its PID and Linux process start identity. Adoption,
completion and archived evidence must match the awaited attempt. A repeated
start with the same ID adopts the existing result rather than starting the same
calibration again. Emergency Stop remains intentionally broad because workers
share one physical TV/meter; that is not used as proof of result ownership.

Live status and Stop controls still poll promptly. Repeated manifest progress
writes are coalesced to 5–10 seconds and terminal boundaries; durable checkpoints
and safety obligations are not deferred. Measure resource/latency behaviour on
the appliance before claiming performance improvements.

Browser picture caches are partitioned by device/profile/input/signal/mode and
category, with per-key read times. An unscoped/virtual response invalidates the
current pointer; values and capability envelopes never merge across contexts.

Quality is an explicit policy: `audit` preserves the original order and reports
warnings; `enforce` requires enabled post-readings and configured limits, then
blocks Apply to All Inputs until every selected sweep passes. Evidence is bound
to targets, limits, context and the calibration checkpoints. Changed calibration
or limits invalidate an old proof. Stored quality results are separate from the
recipe, so copying History cannot erase its acceptance limits. No universal
HDR/DV thresholds are imposed.

## Automated verification

Run syntax checks, `prove -v t/`, and all eleven scripts listed in the existing
browser CI job, using Chromium's sandbox. Do not run `*_deployed.cjs` scripts as
part of hardware-free CI.

Key new/extended tests:

- `automation_review_hardening.t`: durable writes, permissions, bounded locks,
  corrupt ownership, disable/restore failure injection, safe Pause, retry delivery,
  worker attempt ownership/replay and enforced quality proof.
- `automation_http_responsiveness.t`: real threaded loopback HTTP listener,
  failed-start routing, silent sockets and responsive ping, with equipment mocked.
- `automation_whole_queue_preflight.t`: real runner, storage, transport and plan
  code with simulated device responses; legacy limited checks, modern fail-closed
  reads, cancellation and separate final viewing restoration without LUT writes.
- `automation_launch_verification.t`: real subprocess handshake, cancelled/late
  attempts, private credential journal and secret-free production argv.
- `lg_browser_read_cache.t`: cross-mode, cross-input and profile isolation.
- `automation_restart_cleanup.t`: safe paused runs versus legacy unsafe pauses.

## Physical acceptance outstanding

On the exact candidate commit, complete SDR, HDR10 with Dark Detail, and Dolby
Vision jobs on the G3 and contributor's C1. Verify C1 can reach calibration,
unsupported native controls stay manual/unverified, and modern failures still
block. Independently check output, settings and before/after measurements.

Exercise Pause/Resume after setup, reset and greyscale completion; Stop and reboot;
partial protection failures; failed restoration/reconnect/retry; and both finish
policies. Check actual CAL_END and protective end state, then verify a new batch
can start. Repeat the contributor's failed-readiness/Run-queue sequence on the Pi
and inspect accept backlog, descriptors and allocator behaviour. Test enforced
quality with a deliberately failed limit and verify no propagation occurs.

Hardware-free tests and hosted CI do not substitute for these checks or for an
independent agent/human code review. No hardware deployment is part of this change.

## Review follow-up: worker series, readback limits and archive bookends

Follow-up baseline: `a787bbe5fab9e4a88e1300e34fca1967724b47cb`.

Before/After Reading sweeps use the same attempt-fenced start path as AutoCal.
Each sweep has a fresh identity, including after AutoCal and across job boundaries.
The shell worker retains its run/attempt/PID metadata even when a state payload
already contains `points`. Saved measurements retain provenance; a mismatched
status cannot overwrite a previous snapshot. Regression tests drive the real
start/wait/snapshot functions and execute the shell state writer in isolation.

Mode-read limitations are read from `lg_generation.picture_mode_read_forbidden`
(or the legacy direct shape), never inferred solely from DDC-only white balance.
The C1 virtual/nested preflight fix remains in place. Readable and unknown TVs
still need independent mode evidence. An explicitly rejected transient DV
CAL_START can retry at most three times on a read-banned generation, retaining
its resolved target and reporting unavailable mode verification. A timeout,
missing acknowledgement or permission error does not authorise a retry.

The 3D LUT and both DV profile history upload routes now require requested
calibration entry to be acknowledged before upload, preserve upload failures,
and report unconfirmed exit instead of success. The existing 1D restore route
already enforced those bookends and is covered without changing its policy.
Successful explicit caller-managed bookend options remain supported.

Limited readiness results count as jobs checked, not completed calibrations, in
both live and saved preflight displays. The optional HTML-attribute hardening
escapes catalogue numeric limits without changing their valid numeric values.

These are source/test fixes, not an additional physical calibration or a
reproduction of the reported Pi daemon freeze. The hardware acceptance checklist
above still applies to the exact follow-up commit before deployment is certified.
