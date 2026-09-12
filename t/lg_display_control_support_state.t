#!/usr/bin/perl
# The Display Control grid decides whether each picture control is usable, and
# now explains WHY a control has no value to show. On a 2021 C1, webOS reports
# no value for oledLight while the equivalent Backlight control works.
#
# lgDisplayControlSupportState() is the pure function behind that. These are
# real execution tests, not source assertions: the helper is loaded into a Node
# vm sandbox (t/js/lg_display_control_support_state.js) and called.
#
# The load-bearing property is that the supported/unsupported VERDICT is
# identical to the old "value is present" rule -- this change only adds a
# reason string on controls that were already disabled. The value-wins case
# pins that: a key the daemon lists as unsupported but for which it also
# returned a live value must stay usable.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $driver = "$Bin/js/lg_display_control_support_state.js";
plan skip_all => "driver missing: $driver" unless(-f $driver);
my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp($node);
plan skip_all => "Node is not installed; JS behavior not exercised" if($node eq "");
plan tests => 17;

my $json = `"$node" "$driver" 2>&1`;
ok($? == 0, 'the Node driver ran') or diag($json);
like($json, qr/\{/, 'driver produced output') or diag($json);
unlike($json, qr/"loadError"/, 'webui-lg.js loaded and the helper is defined')
  or diag($json);

# Pull one object's fields out of the driver's JSON without a JSON module
# dependency (core Perl only, matching the rest of the suite).
sub obj  { my ($c)=@_; return ($json =~ /"\Q$c\E"\s*:\s*\{(.*?)\}/s) ? $1 : ""; }
sub bool { my ($c)=@_; my $b=obj($c); return ($b =~ /"supported"\s*:\s*(true|false)/) ? $1 : ""; }
sub why  { my ($c)=@_; my $b=obj($c); return ($b =~ /"reason"\s*:\s*"((?:[^"\\]|\\.)*)"/) ? $1 : ""; }

# --- a refused key has no value, is explained, and names the working sibling ---
is(bool('refused'), 'false', 'a refused control (oledLight) is not usable');
like(why('refused'), qr/did not report a value/i,
     'the empty control is explained in read-only terms');
like(why('refused'), qr/available as Backlight/,
     'and it names the panel-light control that is reporting a value');
is(bool('refusedSibling'), 'false', 'oledPixelBrightness is refused too');

# --- THE FIX: a live value wins even when the key is also listed unsupported ---
is(bool('valueWinsOverUnsupported'), 'true',
   'a key with a reported value stays usable despite being in unsupportedKeys');
is(why('valueWinsOverUnsupported'), '',
   'and a usable control carries no reason');

# --- controls the TV does report stay usable ---
is(bool('works'), 'true', 'backlight (a reported value) remains usable');
is(bool('worksBrightness'), 'true', 'brightness remains usable');

# --- fail open: with no capability data, the verdict matches the old rule ---
is(bool('legacyPresent'), 'true',
   'without capability data a present value is still usable (old behavior)');
is(bool('legacyAbsent'), 'false',
   'without capability data an absent value is still unusable (old behavior)');
is(bool('legacyUndef'), 'false', 'an explicit undefined value is unusable');

# --- defensive: junk arguments must not throw (driver would have exited nonzero) ---
is(bool('nullArgs'), 'false', 'null values/caps produce a clean unusable verdict');

# --- the sibling hint is data-driven and points the other way when apt ---
like(why('reverse'), qr/available as OLED Light/,
     'when backlight is the empty key the hint names OLED Light');
unlike(why('refusedNoSibling'), qr/available as/i,
     'no brightness hint when no sibling is reporting a value');
