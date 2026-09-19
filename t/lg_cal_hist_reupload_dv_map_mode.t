#!/usr/bin/perl
# A Dolby Vision archive-reupload enters calibration mode (CAL_START), which the
# TV rejects with an opaque "500 Driver error" unless the display is in Relative
# DV map mode (dv_map_mode 2). The DV AutoCal path already enforces this
# (webui_lg_autocal_dv_map_mode_error, PR #3) and the Web UI switches to Relative
# before a run; the reupload path did neither, so a reupload while in Absolute map
# mode failed with the same opaque 500 and no actionable message.
#
# webui_lg_calibration_history_reupload now refuses a DV reupload that is not in
# Relative map mode, before reading the archive or touching the TV. This pins that
# call site: delete the guard and these go red.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 8;

# lg.pm reads this main-program global for the current DV map mode; declare it so
# the test can localize it without a strict error.
our %pgenerator_conf;

my $dir = "$Bin/../usr/share/PGenerator";
ok(-f "$dir/lg.pm", 'lg.pm is present');

# lg.pm is a plain module: loading it defines its subs without starting a daemon.
# Its siblings must be on @INC. (No webui.pm needed -- the guard is self-contained.)
unshift @INC, $dir;
ok(defined(do "$dir/lg.pm"), 'lg.pm loads') or diag("error: $@");
ok(defined &main::webui_lg_calibration_history_reupload, 'reupload dispatcher is defined');

# Drive the dispatcher with a DV id and a chosen dv_map_mode. The guard runs
# before any archive read, so a non-existent id still exercises it.
sub reupload_map_error {
    my ($id, $map_mode) = @_;
    local %pgenerator_conf = (dv_map_mode => $map_mode);
    my $out = main::webui_lg_calibration_history_reupload(
        main::lg_encode_json({ id => $id, enable_calibration => 1 }));
    my $r = main::lg_decode_json($out);
    return "" unless(ref($r) eq "HASH" && ($r->{error_code} || "") eq "dv-map-mode-not-relative");
    return $r->{message} || "refused";
}

# Absolute (1): a DV reupload is refused with an actionable message.
like(reupload_map_error('dv:run-x', '1'), qr/Relative/,
     'DV run reupload in Absolute (1) is refused and names Relative');
like(reupload_map_error('dvfile:archive-y', '1'), qr/Relative/,
     'DV file reupload in Absolute (1) is refused (both DV id forms)');

# Unset map mode is refused too (never assumed safe).
isnt(reupload_map_error('dv:run-x', ''), '',
     'DV reupload with an unset map mode is refused');

# Relative (2): the guard passes -- the reupload proceeds past it (and only then
# fails on the missing test archive), so it must NOT be the map-mode error.
is(reupload_map_error('dv:run-x', '2'), '',
   'DV reupload in Relative (2) is allowed past the map-mode guard');

# The guard is scoped to DV: a 1D reupload is never blocked by the DV map mode.
is(reupload_map_error('1d:run-x', '1'), '',
   'a 1D reupload in Absolute map mode is not blocked by the DV guard');
