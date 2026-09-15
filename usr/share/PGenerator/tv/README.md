# TV capability profiles

This directory is PGenerator's reviewed compatibility library. It is data,
not a model-name allowlist and not a record of the connected TV's current
state.

For LG TVs, resolution is deterministic and least-to-most specific:

1. conservative base;
2. common setting contracts and retail-model fallback;
3. internal `HE_DTV_WxxH/O/G` platform;
4. exact firmware read/write and value catalogues;
5. observations from this physical TV, firmware, signal, picture mode, input,
   category and native/DDC control channel.

The internal platform wins if it conflicts with the retail model. Unknown
platform geometry fails closed before a 3D LUT reset, probe, generation or
upload. A firmware catalogue entry is labelled `firmware_inventory`; it does
not become a live read, write, or verification claim simply because a key is
listed.

`PGLGCapabilities.pm` validates and atomically loads the files in
`lg/index.json`. If any reviewed profile is malformed, no partial profile set
is used and the resolver returns the conservative base.

To add a TV:

1. capture retail model, full internal platform and full firmware version;
2. add or confirm platform geometry using an attributed source;
3. import public read and write lists separately for the exact firmware;
4. keep calibration recipe values separate from firmware defaults;
5. add a fixture and tests;
6. promote live operations only with their route and complete context;
7. mark a write `verified` only after independent readback and restoration.

The schema is `schema-v1.json`; source identifiers and licences are in
`sources.json`.

## Runtime integration

### Contributing picture-mode knowledge

`lg/picture-modes/catalogue.json` is the shared picture-mode vocabulary. Each
signal has records keyed by the stable application value. A record separates
the human-facing `label`, `settings_key` / `settings_value`, accepted `aliases`,
and `calibration.bank` (externalpq wire token) / `calibration.internal_mode`
(the helper's internal namespace). `offered` controls menu visibility, not
hardware availability. Selection, readback and calibration support are
independent; `inventory` does not mean a write has been verified.

For example, HDR Cinema Home is labelled `HDR Cinema Home`, selects
`pictureMode: hdrCinemaBright`, and has no reviewed calibration bank. The job
editor offers it for readings but blocks AutoCal, without replacing a saved
selection. HDR Cinema has a different selector, `hdrCinema`, and bank,
`hdr_cinema`. The older DV Cinema menu label and bank override are profile data,
not a special C1 workflow.

Add new modes as complete records; use a higher-priority, model/platform/firmware
scoped profile to override an existing record. Attach source IDs and evidence
scope. Do not promote G3 observations to every LG TV, or infer a bank from a
similar name. Hidden legacy application tokens can share a selector with an
offered menu row; exact internal spellings retain their identity and native
readback prefers the offered row. Ambiguous offered aliases fail closed.

The job editor and Display picker consume the resolved catalogue; readiness
and HDR reset use its bank eligibility. The helper uses the same records for
selector mapping, mode comparison and calibration-mode resolution. Existing
legacy/free-text adapters remain fallbacks for older spellings outside the
catalogue; they are not evidence that an unknown mode supports AutoCal.
Runtime platform, input, signal, write-acknowledgement and verification guards
still apply. Adding a label or alias never grants those capabilities.

Run `prove -Iusr/share/PGenerator t/lg_calibration_mode_contract.t
t/lg_capability_library.t` and `node t/browser/automation_settings_plan.cjs`.
The contribution regression adds a scoped profile in a temporary library and
checks that its label, selector, readback alias and bank reach the shared
planner and helper, without application code changes. Other controls continue
to use `settings.controls` for schemas, routes and verification policies;
recipe targets are not manufacturer defaults or measured values.

The shared `pgenerator-lg` picture read/write workflows resolve the contracts
on every connection. They validate types, ranges and enum tokens, isolate
context-sensitive requests, retry omissions from grouped reads, require a
preflight read for unlisted writes, and compare post-write values using the
setting's semantics. Mismatched readback returns an error with per-key evidence;
missing readback does too unless the matrix explicitly permits acknowledged-only
operation for that control and signal. Native controls and PGenerator's fractional DDC arrays have
separate contracts. DDC and older picture-mode transports report
`acknowledged_unverified` when hardware readback is unavailable.

The Display controls use the returned schemas and applicability decisions.
AutoCal job readiness validates essential SDR/HDR10/DV recipe settings and
records the selected profile and hash. Automation uses the contracts for
readback comparisons and retains the selected profile in calibration receipts.
It confirms that signature again before applying settings or starting resets.
Runner and calibration-worker requests carry the frozen HDMI input and profile
signature through the API to the TV helper. The helper checks both on the
authenticated connection before starting the operation. A changed or unreadable
input blocks the request; calibration exit remains available for cleanup.
The 3D worker rejects a frozen profile that no longer matches the supplied TV
identity. Direct 1D/DDC, Dolby Vision, tone-map and calibration-start paths also
require a reviewed internal platform; calibration exit remains available.

Reset candidates are filtered through the matrix and live key inventory.
Reset replies distinguish accepted requests from per-key verified values; they
do not claim universal manufacturer defaults. AutoCal reapplies and verifies
the signal-specific recipe before measurement. Panel-light values remain
target-dependent instead of reusing one C2 cinema value for every model.

DDC writes require hardware verification wherever the reviewed transport can
provide it, including iterative writes. On readback-incapable 2020/2021
transports, acknowledgement is explicitly unverified; optical validation is
still necessary. An unavailable or untrusted LUT reply is not hardware proof.

Apply-to-all has a separate operation contract. A fresh action transition can
confirm completion, but does not prove that every destination setting matches.

Device observations live in `/var/lib/PGenerator/lg/capabilities`, outside
the reviewed library. They are written atomically under a lock. Missing device
identity prevents persistence; observed refusals remain probeable because
picture processing state can change within the same input/mode. A successful
write still attempts verification on each subsequent operation. An explicitly
permitted acknowledged-only result never promotes the control to verified.
Incomplete or unconfirmed contexts are not persisted. Scoped native reads
carry input/mode dimensions, and post-write verification uses the accepted
write's scope rather than searching another input for a matching value.

## Best available settings on readback-limited TVs

`lg/settings/legacy-best-available.json` supplies policy data to the same resolver
used for newer TVs. Application code does not select behaviour by C1 or G3 name.
The shared planner splits the requested settings into automatic, manual-required,
and blocked entries after a live, current-input read. It keeps the original
requested values for the run's audit trail.

- Readable controls use their normal write and readback contracts.
- Explicitly unavailable native reads on reviewed legacy platforms produce
  manual TV-menu instructions, including the requested value, mode and input.
- A control may permit an acknowledged-only write through
  `write.allow_unverified_readback: true`, scoped by the profile's
  `best_available.unverified_write_signals`. This still requires an actual TV
  write acknowledgement and an attempted post-write read. Missing capability
  responses may be accepted as `acknowledged_unverified`; mismatches, transport
  failures and authentication failures are not waived.
- Unknown keys, invalid values, inapplicable signal controls, explicit write
  blocks and unreviewed internal platforms remain blocked.

AutoCal readiness shows the manual values as warnings in the existing readiness
UI. The runner retains `manual-required` checkpoint evidence and excludes those
controls from automatic writes and the 3D worker's processing-settings payload.
Manual instructions are not proof the user applied them. Such checkpoints stay
unverifiable; optical calibration results must still be evaluated separately.
Target-luminance panel adjustment cannot use this fallback to bypass a missing
panel-light read. Frozen profile/input/mode checks and LUT geometry rules remain
unchanged.

A real native picture-mode mismatch blocks readiness. A reviewed legacy matrix
may explicitly lack mode readback; this remains a visible unverified-mode warning,
not a `context_confirmed` claim. In the 3D worker, matching native processing
values can still be checked in that case, but a mismatch cannot trigger a repair
without confirmed mode. An `unsupported_picture_keys` flag alone never authorizes
the runner to continue: automatic write-only settings need an actual per-key
acknowledgement for the requested value under the matrix.

The C1 entry is based on the user-supplied 15 September 2026 run log, recorded in
`t/fixtures/lg-capabilities/c1-run-2026-09-15.json`. It reports five working SDR
controls and thirteen refused read/capability keys. It is **not** a verified
firmware inventory or proof of thirteen unsupported writes. Its webOS release
6.5.3 is not a captured firmware version. The fixture's W21O platform is supplied
separately, not claimed as captured from that log. Regional C1 names resolve
through the same retail-family parser; calibration still requires the actual
internal platform. The five acknowledged-only candidates are scoped to SDR;
HDR/Dolby Vision do not inherit that evidence.

Regression coverage: `t/lg_best_available.t`, `t/automation_best_available.t`,
`t/lg_capability_runtime.t`, `t/automation_runner_load.t` and
`t/lg_autocal_recipe.t`. These are local simulated-response tests, not a live
C1 calibration result.

## Verifying a connected TV

Display Control's **Verify this TV** scans the current input and picture mode
without changing settings. It reports readable, write-verified, blocked and
unverified keys separately. It does not discover every private firmware API or
prove write support from a successful read. Evidence is specific to the device,
firmware and context; it is not automatically promoted to every G3 or C3.

Panel-light aliases appear as one logical control. On the verified G3 the label
is **OLED Pixel Brightness** and the TV API key is `backlight`. Missing alternate
names do not mean the logical control is unavailable.

After a scan, **Test panel-light write + restore** offers an explicit opt-in
one-step change. The daemon checks the frozen context, requires independent
readback, attempts restoration after any attempted write, then independently
checks the original value. It holds the TV helper lock across this sequence and
refuses active calibration/meter operations. Only a verified change and verified
restoration produce a passing roundtrip observation. A failed restoration is
shown prominently with the original value. The test never resets modes or LUTs.

Exact firmware value profiles can be reproduced for review with:

```
node t/fixtures/lg-capabilities/import-catalogue-values.cjs /path/to/bscpylgtv/docs
```

The importer only emits JSON. Review its output before updating
`lg/firmware/known-oled-values.json`. These are firmware catalogues, not proof
that each listed setting has been tested on a physical TV. Unknown models and
firmware continue to require live probes; new binary calibration geometry
requires an attributed platform profile.
