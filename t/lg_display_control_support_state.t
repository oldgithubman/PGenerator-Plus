#!/usr/bin/perl
# The Display Control grid decides whether each picture control is usable. It
# used to infer that from value presence alone, so a control the TV refuses
# rendered as a dead slider showing "--" with no reason -- on a 2021 C1, webOS
# refuses oledLight outright while the equivalent Backlight control works.
#
# lgDisplayControlSupportState() is the pure function that now answers this
# from the capability data lg_picture_settings already returns. These are real
# execution tests, not source assertions: the helper is loaded into a Node vm
# sandbox (t/js/lg_display_control_support_state.js) and called.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $driver = "$Bin/js/lg_display_control_support_state.js";
plan skip_all => "driver missing: $driver" unless(-f $driver);
my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp($node);
plan skip_all => "Node is not installed; JS behaviour not exercised" if($node eq "");
plan tests => 12;

my $json = `"$node" "$driver" 2>&1`;
ok($? == 0, 'the Node driver ran') or diag($json);
like($json, qr/\{/, 'driver produced output') or diag($json);
unlike($json, qr/"loadError"/, 'webui-lg.js loaded and the helper is defined')
  or diag($json);

# Tiny extractor: pull one object's fields out of the driver's JSON without a
# JSON module dependency (core Perl only, matching the rest of the suite).
sub field {
 my ($case,$key)=@_;
 return "" unless($json =~ /"\Q$case\E"\s*:\s*\{(.*?)\}/s);
 my $body=$1;
 return $1 if($body =~ /"\Q$key\E"\s*:\s*"((?:[^"\\]|\\.)*)"/s);
 return $1 if($body =~ /"\Q$key\E"\s*:\s*(true|false)/s);
 return "";
}

# --- a refused key is unavailable, and names the control that does work ---
is(field('refused','supported'), 'false', 'a refused control (oledLight) is not usable');
like(field('refused','reason'), qr/does not accept this control/i,
     'the refusal is explained in plain language');
like(field('refused','reason'), qr/Use Backlight instead/,
     'and it names the working equivalent on this TV');
is(field('refusedSibling','supported'), 'false', 'oledPixelBrightness is refused too');

# --- controls the TV does accept stay usable ---
is(field('works','supported'), 'true', 'backlight remains usable');
is(field('worksBrightness','supported'), 'true', 'brightness remains usable');

# --- fail open: with no capability data, behave exactly as before ---
is(field('legacyPresent','supported'), 'true',
   'without capability data a present value is still usable (old behaviour)');
is(field('legacyAbsent','supported'), 'false',
   'without capability data an absent value is still unusable (old behaviour)');

# --- the equivalence hint is data-driven, not hardcoded one way ---
like(field('reverse','reason'), qr/Use OLED Light instead/,
     'the hint points the other way when backlight is the refused key');
