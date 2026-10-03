#!/usr/bin/perl
# Issue #50: scanWifi() built each network row with
# d.innerHTML = '...<div class="name">' + n.ssid + '...'. SSIDs come from the
# air: an access point broadcasting <img src=x onerror=...> gained script
# execution in the WebUI origin as soon as the operator opened the Wi-Fi scan
# list -- no interaction beyond viewing the results.
#
# Real execution test (model: t/lg_display_control_support_state.t): the
# driver loads the real scanWifi() from webui-app.js into a Node vm sandbox
# with a recording fake DOM, renders a crafted SSID, and asserts the payload
# lands as inert text -- zero dynamic innerHTML writes during rendering and no
# element ever built from the payload. A source-text pin would pass while a
# runtime-rendered sibling regressed; this exercises the function itself.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $driver = "$Bin/js/wifi_scan_xss.js";
plan skip_all => "driver missing: $driver" unless(-f $driver);
my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp($node);
plan skip_all => "Node is not installed; JS behavior not exercised" if($node eq "");
plan tests => 5;

my $out = `"$node" "$driver" 2>&1`;
my $rc = $?;
is($rc, 0, 'the Node driver ran clean (all vm assertions passed)')
  or diag($out);
like($out, qr/"ok"\s*:\s*true/, 'the driver reported success') or diag($out);
like($out, qr/"rows"\s*:\s*2/, 'dedupe kept one row per SSID');
like($out, qr/onerror/, 'the crafted SSID text survives as the row text');
unlike($out, qr/uncaught|SyntaxError|TypeError/,
  'no sandbox error escaped the run') or diag($out);
