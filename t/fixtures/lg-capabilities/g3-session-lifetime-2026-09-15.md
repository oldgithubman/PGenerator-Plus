# G3 reset failure: transport lifetime

Run `20260915-162429-315b18` (Test Queue / SDR Filmmaker) stopped at
`reset-and-reapply-verified`. All 18 preparation checks matched. Before
readings were disabled. Cleanup stopped workers, released the meter, and
received the TV's calibration-exit acknowledgement.

The UI reported “LG TV rejected picture reset.” The diagnostic response
contained missing replies throughout reset, not an explicit TV rejection.

## Reproduction and cause

On the OLED55G36LA / W23O, firmware 23.25.55, webOS 9.2.2, HDMI4:

- The installed helper authenticated successfully over WSS.
- Profile construction and its calibration guard finished at 5.734 seconds.
- The next mode read could not be sent; subsequent reads also failed.
- The helper launched socat with `-T 5`, an inactivity timeout, even though
  local capability resolution can exceed five seconds between requests.
- Profile construction resolved the entire matrix twice, including once
  solely to obtain its already-resolved picture-mode catalogue.

## Verification of the patch

Two staged-helper checks authenticated, deliberately stayed idle for six
seconds, and ran the same read-only preparation sequence. Both received
native `pictureMode=filmMaker` replies after profile resolution and again
after reset-key contract resolution. The second explicitly recorded WSS;
its first post-idle mode reply arrived at 9.283 seconds, and its final reply
at 15.852 seconds.

Unfiltered settings-inventory requests received explicit `500 Application
error` replies. Those are different from missing transport replies. The
existing matrix fallback supplied 40 eligible reset keys; this does not
prove those keys can all be reset successfully.

The diagnostic harness permitted only authentication and read-only
system/software/settings requests. It sent no reset, settings write,
calibration command, or LUT upload. A full calibration rerun is still needed.

`t/lg_session_lifetime.t` covers transport arguments, bounded reads and child
cleanup, single profile resolution, missing-response reset diagnostics,
explicit rejection details, and acknowledged native reset behavior. These
are transport-wide fixes, not a G3-specific compatibility exception.
