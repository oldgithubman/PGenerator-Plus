#!/usr/bin/perl
# An explicit /api/pattern {"name":"stabilization"} request must honor the
# durable stabilization stimulus/size settings. Historically the configured
# values were resolved only on the stop->stabilization idle conversion, so
# an explicit request drew at the hardcoded 25% size-100 defaults no matter
# what Meter Settings held (observed live on the bench 2026-11-15: a device
# configured for 100% showed 25% from the API path; only a webui-driven
# render used the configured value).
#
# The decision block lives deep inside webui_pattern(); rather than boot the
# whole module, extract the block by anchors and evaluate it against stubbed
# settings accessors. The anchors ARE part of the pin: moving or renaming
# the block fails the test so the extraction is updated deliberately.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More tests => 14;

my $webui = "$Bin/../usr/share/PGenerator/webui.pm";
ok(-f $webui, 'webui.pm is present');

my $src = do { open(my $fh, '<', $webui) or BAIL_OUT("open $webui: $!"); local $/; <$fh> };
my $start = index($src, 'my $stabilization_stimulus=25;');
my $end   = index($src, 'my $signal_mode=&webui_pattern_signal_mode($body);', $start);
ok($start >= 0,    'start anchor (hardcoded defaults) found exactly once-ish');
is(index($src, 'my $stabilization_stimulus=25;', $start + 1), -1, 'start anchor is unique');
ok($end > $start,  'end anchor follows the start anchor');
my $block = substr($src, $start, $end - $start);
like($block, qr/if\(\$name eq "stop"\)/,            'block resolves stabilization on the stop conversion');
like($block, qr/elsif\(\$name eq "stabilization"\)/, 'block resolves stabilization for explicit requests');

# Stubbed settings accessors; the evaluated block calls them bare.
our ($ENABLED, $CFG_STIM, $CFG_SIZE, $ACTIVE);
sub webui_meter_stabilization_settings { ($ENABLED, $CFG_STIM, $CFG_SIZE) }
sub webui_meter_stabilization_active   { ($ACTIVE ? (1, $CFG_STIM, $CFG_SIZE) : (0, $CFG_STIM, $CFG_SIZE)) }

my $decide = eval "sub { my \$name = shift; $block return (\$name, \$stabilization_stimulus, \$stabilization_size); }";
BAIL_OUT("extracted block does not compile: $@") if (!defined $decide);

# 1. Explicit stabilization with a configured 100% / apl_50 patch: the fix.
($ENABLED, $CFG_STIM, $CFG_SIZE, $ACTIVE) = (1, 100, 150, 0);
is_deeply([$decide->('stabilization')], ['stabilization', 100, 150],
    'explicit stabilization uses the configured stimulus and size');

# 2. Same but the idle conversion path must keep the meter-detection gate.
($ENABLED, $CFG_STIM, $CFG_SIZE, $ACTIVE) = (1, 100, 150, 0);
is_deeply([$decide->('stop')], ['stop', 25, 100],
    'stop with no meter detected stays stop (idle gate unchanged)');
($ENABLED, $CFG_STIM, $CFG_SIZE, $ACTIVE) = (1, 100, 150, 1);
is_deeply([$decide->('stop')], ['stabilization', 100, 150],
    'stop with a detected meter converts at the configured values');

# 3. Explicit request while the feature is disabled keeps the defaults.
($ENABLED, $CFG_STIM, $CFG_SIZE, $ACTIVE) = (0, 42, 75, 1);
is_deeply([$decide->('stabilization')], ['stabilization', 25, 100],
    'explicit stabilization without the enabled setting draws the defaults');

# 4. Unrelated names are untouched by the block.
($ENABLED, $CFG_STIM, $CFG_SIZE, $ACTIVE) = (1, 100, 150, 1);
is_deeply([$decide->('patch')], ['patch', 25, 100], 'patch name passes through');
is_deeply([$decide->('crosshatch')], ['crosshatch', 25, 100], 'named patterns pass through');

# 5. The renderer branch consumes these two lexicals (drift tripwire).
like($src, qr/if\(\$name eq "stabilization"\) \{\s*\(\$pr,\$imax\)=&webui_meter_stabilization_code\(\s*\$stabilization_stimulus/m,
    'stabilization draw path consumes the resolved stimulus lexical');
like($src, qr/\$sz=\$stabilization_size;/,
    'stabilization draw path consumes the resolved size lexical');
