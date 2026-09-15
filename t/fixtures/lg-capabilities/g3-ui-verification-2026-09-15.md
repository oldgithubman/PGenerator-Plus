# G3 visible-Chrome verification — 15 September 2026

TV: OLED55G36LA, firmware 23.25.55, W23O. Context: HDMI4, SDR,
`filmMaker`. This is evidence for this physical TV and context, not a blanket
claim for other models, firmware, inputs, HDR10 or Dolby Vision.

## Deployment

- 26 release files matched SHA-256 checksums on the Raspberry Pi.
- Application service restarted; `/api/ping` returned `{"ok":1}`.
- Release files have root ownership. Unrelated automation UI changes were not deployed.
- Backup: Pi `/root/pgen-lg-verification-backup.Dntb5X`.
- Manifest: Pi `/root/pgen-lg-verification.dSTAdq/SHA256SUMS`.
- Independent reviewer checked restoration, connection/queue serialization,
  frozen input forwarding, alias rendering and evidence wording. Reported
  blockers were fixed and the narrow follow-up passed.

## Automated checks

- Full local suite: 61 test files, 4,698 tests, all passed.
- Pi staged compatibility/verification/guard tests: 278 assertions passed.
- JavaScript and Perl syntax checks and `git diff --check` passed.
- Failure tests cover missing readback, lost responses after applying a write,
  failed restoration, wrong TV signature/input, unconfirmed context, active
  meter/calibration guards, and queue-start lock ownership/release.

## Actual browser interactions

Tests ran in visible Google Chrome, using clicks, keyboard input and scrolling.
Network responses were observed passively; no application APIs or functions
were invoked directly to perform the TV tests.

1. Display Control showed one enabled **OLED Pixel Brightness** control,
   mapped to `backlight`, initially 18. Duplicate alias controls were absent.
2. **Verify this TV** completed without settings writes: 72 API keys checked,
   60 values readable. Missing aliases were not reported as proof that the
   logical OLED control was unsupported.
3. **Test panel-light write + restore** and its confirmation performed
   18 → 19 → 18. Independent reads confirmed both change and restoration.
   Response: `status=ok`, `test_verified=1`, `restored=1`, `evidence_saved=true`.
4. The normal OLED brightness field independently passed 18 → 19 → 18,
   with verified write responses and a fresh Refresh Settings read of 18.
5. After another service restart and page reload, a fresh TV read returned
   the original value and the persisted `roundtrip.status=verified` observation.
6. The final scan retained that evidence and reported four write-verified
   settings (including prior brightness/contrast evidence); it did not infer
   write support for all 60 readable values.
7. The Noise Reduction dropdown passed Off → Low → Off through click/key
   interactions, with verified write responses and an independent refresh.
8. Final readback matched all 21 original displayed values. No JavaScript
   page errors were recorded. No LUT uploads, mode resets, calibration starts,
   or queue starts were performed.

## Discovered limitations

The first scan included three internal logical identifiers as API names.
The scan now resolves each profile control's `wire_key`; a regression test
was added, the correction deployed, and the scan repeated successfully.

An early Connect click after reload attempted PIN pairing before saved-pairing
status had loaded. The browser safety guard blocked that request. Reloading,
waiting for saved-pairing status, then clicking Connect succeeded without a PIN.
That separate connection-initialization issue was not fixed in this change.

Raw test evidence and screenshots are in the local directory
`/private/tmp/lg-verification-ui.PDw3u8`. The final screenshot is
`17-final-restored-report.png`; passive responses and interaction steps are in
`visible-chrome.json`.
