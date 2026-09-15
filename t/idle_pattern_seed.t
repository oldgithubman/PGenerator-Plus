#!/usr/bin/perl
# The renderer must never be started against an empty operations.txt.
#
# With no pattern to parse, ofApp::draw() returns at `if(entered == 0)` and
# ofApp::setBackground() is never reached, so the framebuffer keeps
# openFrameworks' default clear color (ofStyle bgColor, 60,60,60 in the 0.11.2
# the README pins) as plain RGB. On an RGB wire that is a dark grey nobody
# notices -- it measured a neutral 4.2 nits. On a YPbPr wire the
# same bytes are read as Y=Cb=Cr, red and blue clip to zero, and the panel
# sits on its green primary until the first pattern lands -- measured on an LG
# OLED at 9.7 nits / CIE 0.293,0.613 in SDR and 26.1 nits / 0.271,0.672 in
# HDR10, against 0.000 nits once any pattern is pushed. An empty file also
# leaves ofxRPI4Window::bit_depth at 0, which pins the window to an 8-bit
# surface regardless of max_bpc.
#
# seed_idle_pattern_file() is the fix that ships without rebuilding the
# renderer, so these are the properties that keep it working.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More tests => 44;

my $dir = "$Bin/../usr/share/PGenerator";
ok(-f "$dir/pattern.pm", 'pattern.pm is present');

# variables.pm pulls in threads::shared, which a unit test has no use for.
# log.pm, conf.pm and pattern.pm load standalone; set the few globals the
# seeder reads so the test stays hermetic.
unshift @INC, $dir;
for my $m (qw(log.pm conf.pm pattern.pm)) {
  my $rc = do "$dir/$m";
  ok(defined $rc, "$m loads") or diag("error: $@");
}
ok(defined &main::idle_pattern_text,      'idle_pattern_text is defined');
ok(defined &main::seed_idle_pattern_file, 'seed_idle_pattern_file is defined');

our ($debug, $bits_default, $w_s, $h_s, $command_file, %pgenerator_conf);
$debug = 0;    # keep &log quiet; it is not what this test is about
$w_s   = 3840;
$h_s   = 2160;

# idle_pattern_text() reads $bits_default as the conf-change sites left it,
# rather than re-deriving it -- resolve.pm deliberately desyncs the two.
# sync_pattern_bits_default() is what those sites call, so calling it here
# reproduces the state the seeder actually sees in production.
sub conf {
  my (%o) = @_;
  %pgenerator_conf = (max_bpc => 10, color_format => 0, rgb_quant_range => 1,
                      dv_status => 0, %o);
  sync_pattern_bits_default();
}

# --- SOURCE_RANGE belongs to the RGB transport only ---
# normalizeSourceValue() returns early when output_format != 0, and
# webui_pattern_set() emits SOURCE_RANGE only for color_format 0. A seeded
# idle frame has to agree, or it stops being byte-identical to a WebUI "stop".
conf(color_format => 0, rgb_quant_range => 1);
like(idle_pattern_text(), qr/^SOURCE_RANGE=LIMITED$/m, 'RGB Limited declares LIMITED');
conf(color_format => 0, rgb_quant_range => 2);
like(idle_pattern_text(), qr/^SOURCE_RANGE=FULL$/m,    'RGB Full declares FULL');
conf(color_format => 1);
unlike(idle_pattern_text(), qr/^SOURCE_RANGE=/m, 'YCbCr 4:4:4 omits SOURCE_RANGE');
conf(color_format => 2);
unlike(idle_pattern_text(), qr/^SOURCE_RANGE=/m, 'YCbCr 4:2:2 omits SOURCE_RANGE');

# --- BITS must carry the link depth, or the window comes up at 8 bpc ---
conf(max_bpc => 10);
like(idle_pattern_text(), qr/^BITS=10$/m,        '10 bpc seeds BITS=10');
like(idle_pattern_text(), qr/^SOURCE_MAX=1023$/m,'and SOURCE_MAX=1023');
conf(max_bpc => 8);
like(idle_pattern_text(), qr/^BITS=8$/m,         '8 bpc seeds BITS=8');
like(idle_pattern_text(), qr/^SOURCE_MAX=255$/m, 'and SOURCE_MAX=255');
# ofApp::setBackground() branches on bit_depth == 10 and otherwise falls back to
# its 8-bit path -- it has no 12-bit encoding, so a seeded BITS=12 leaves the
# idle background unconverted and green (measured 6.9 nits at CIE 0.273,0.673 on
# a 12 bpc HDR10 4:4:4 link, against 0.000 nits with BITS=10). Draw through the
# 10-bit path; the first real pattern restores the link depth.
conf(max_bpc => 12);
like(idle_pattern_text(), qr/^BITS=10$/m, '12 bpc draws through the 10-bit path, which is the only one that encodes');

# --- Dolby Vision authors the tunnel, not plain RGB ---
# Standard DV keeps the 8-bit framebuffer while its shader consumes 12-bit
# codes, and its black is the legal floor 256 -- webui_pattern_set() does the
# same. RGB=0 with SOURCE_MAX=255 would emit a sub-black tunnel code.
conf(max_bpc => 10, dv_status => 1);
like(idle_pattern_text(), qr/^BITS=8$/m,          'Dolby Vision stays on the 8-bit tunnel');
like(idle_pattern_text(), qr/^SOURCE_MAX=4095$/m, 'but declares 12-bit source precision');
like(idle_pattern_text(), qr/^RGB=256,256,256$/m, 'and authors black at the legal floor');
like(idle_pattern_text(), qr/^BG=256,256,256$/m,  'background too');
like(idle_pattern_text(), qr/^SOURCE_RANGE=LIMITED$/m,
     'DV inner components are legal-range even on a Full tunnel');
# DV signalled through the transport flags with dv_status still 0 must still get
# the 8-bit tunnel. sync_pattern_bits_default() only pins bits on dv_status==1, so
# without the $bits=8-if-$dv guard this leaked BITS=10 under a 12-bit DV black.
conf(max_bpc => 10, dv_status => 0, is_std_dovi => 1);
like(idle_pattern_text(), qr/^RGB=256,256,256$/m, 'is_std_dovi alone is enough to mean DV');
like(idle_pattern_text(), qr/^BITS=8$/m,          'is_std_dovi alone still forces the 8-bit tunnel');
like(idle_pattern_text(), qr/^SOURCE_MAX=4095$/m, 'and still declares 12-bit source precision');
conf(max_bpc => 10, dv_status => 0, is_ll_dovi => 1);
like(idle_pattern_text(), qr/^BITS=8$/m,          'is_ll_dovi alone forces the 8-bit tunnel too');

# --- the frame itself is full-screen black ---
conf();
my $txt = idle_pattern_text();
like($txt, qr/^BG=0,0,0$/m,           'background is black');
like($txt, qr/^RGB=0,0,0$/m,          'patch is black too');
like($txt, qr/^DIM=3840,2160$/m,      'covers the whole screen');
like($txt, qr/^POSITION=0,0$/m,       'anchored at the origin');
like($txt, qr/^DRAW=RECTANGLE$/m,     'drawn through the rectangle path');
like($txt, qr/^PATTERN_NAME=stop$/m,  'named stop, which the WebUI already treats as idle');
like($txt, qr/^END=1$/m,              'terminates the draw');
like($txt, qr/^FRAME=1$/m,            'and the frame');

# --- seeding writes only into an empty slot ---
my $tmp = tempdir(CLEANUP => 1);
$command_file = "$tmp/operations.txt";
conf();

is(seed_idle_pattern_file(), 1, 'seeds when the file is missing');
like(slurp($command_file), qr/^BG=0,0,0$/m, 'and the file holds the idle frame');

unlink $command_file;
open(my $e, '>', $command_file) or die $!; close $e;
is(seed_idle_pattern_file(), 1, 'seeds when the file exists but is empty');

open(my $w, '>', $command_file) or die $!; print $w "\n  \n\t\n"; close $w;
is(seed_idle_pattern_file(), 1, 'seeds when the file is only whitespace');

# A real pattern is somebody's measurement in progress. Never clobber it.
my $real = "PATTERN_NAME=patch\nBITS=10\nRGB=288,288,288\nBG=0,0,0\nEND=1\nFRAME=1\n";
open(my $r, '>', $command_file) or die $!; print $r $real; close $r;
is(seed_idle_pattern_file(), 0, 'declines when a real pattern is loaded');
is(slurp($command_file), $real, 'and leaves it byte-for-byte alone');

ok(!-e "$command_file.tmp", 'no shared staging file is left behind');
ok(!glob("$command_file.seed.*"), 'no pid-unique staging file is left behind');

# The bare "$command_file.tmp" is written by get_pattern() and the WebUI from
# daemon threads while this runs in the forked apply worker, which shares no
# lock with them. Staging must stay pid-unique; rename() is atomic either way,
# so nothing else would notice the regression.
my $pat_src = do { open(my $pf, '<', "$Bin/../usr/share/PGenerator/pattern.pm") or die $!;
                   local $/; <$pf> };
my ($stage) = $pat_src =~ /sub seed_idle_pattern_file.*?my \$tmp=("[^"]+")/s;
is($stage, '"$command_file.seed.$$"', 'stages under a pid-unique name');

# --- the call site itself, so deleting one line cannot pass silently ---
my $cmd = "$Bin/../usr/share/PGenerator/command.pm";
open(my $cf, '<', $cmd) or die "read $cmd: $!";
my $src = do { local $/; <$cf> };
close $cf;
my ($body) = $src =~ /(sub pattern_generator_start\(\@\)\s*\{.*?\n\})/s;
ok($body, 'found the pattern_generator_start body');
$body //= '';
ok(index($body, '&seed_idle_pattern_file();') >= 0,
   'pattern_generator_start seeds the idle pattern');
ok(index($body, '&get_hdmi_info();') < index($body, '&seed_idle_pattern_file();')
   && index($body, '&seed_idle_pattern_file();') < index($body, 'system('),
   'and does it after the mode settles, before the renderer spawns');

sub slurp { my $f = shift; open(my $fh, '<', $f) or return ''; local $/; my $c = <$fh>; close $fh; return $c; }
