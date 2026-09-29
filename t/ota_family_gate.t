#!/usr/bin/perl
# Regression tests for the OTA family gate and per-target asset selection.
#
# Family gate (issue #47 follow-up): same MAJOR.MINOR updates always
# apply; crossing MINOR applies only when the release notes carry the
# directive line "OTA-Family: cross"; crossing the MAJOR component is
# never OTA. Missing directive must fail safe to the old refuse/reflash
# behaviour, so a release that forgets the marker can never widen OTA
# by accident.
#
# Asset selection: a release carries one payload per build target. A Pi 5
# device must pick the "-pi5" tagged tarball and a Pi 4 device must never
# pick one, regardless of asset order in the release.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More tests => 24;

my $script = "$Bin/../usr/sbin/pgenerator-update";
ok(-f $script, 'pgenerator-update is present');

my $full = do { local(@ARGV,$/); open(my $fh,'<',$script) or die "$script: $!"; <$fh> };
my ($head) = split(/cmd="\$\{1:-help\}"/, $full, 2);
ok(defined $head && $head =~ /ota_gate_reason/, 'header contains the family gate');
ok(defined $head && $head =~ /device_target/, 'header contains target detection');

my $tmp = tempdir(CLEANUP => 1);
my $headfile = "$tmp/head.sh";
open(my $hf,'>',$headfile) or die $!; print $hf $head; close($hf);

sub run_bash {
 my ($code, %env) = @_;
 my $runner = "$tmp/runner.sh";
 open(my $rf,'>',$runner) or die $!;
 print $rf "#!/bin/bash\nset -uo pipefail\n";
 print $rf qq{export PGENERATOR_CONF_FILE="$tmp/conf-absent"\n};
 while (my ($k,$v) = each %env) {
  my $e = $v; $e =~ s/'/'\\''/g;
  print $rf qq{export $k='$e'\n};
 }
 print $rf ". \"$headfile\"\n$code\n";
 close($rf);
 my $out = `bash "$runner" 2>/dev/null`;
 my $rc = $? >> 8;
 chomp $out;
 return ($out, $rc);
}

# ── ota_gate_reason ──
# Allowed cases produce empty output and rc 0; refusals print a reason.
{
 my ($out,$rc) = run_bash(q{gate_reason=""; if ota_gate_reason "2.13.0" "2.13.4" ""; then echo "RC=0"; else echo "RC=1"; fi});
 unlike($out, qr/outside the OTA family/, 'same family: no refusal text');
 like($out, qr/RC=0/, 'same family patch bump: gate passes');
}
{
 my ($out) = run_bash(q{if ota_gate_reason "2.13.4" "2.13.4" ""; then echo "RC=0"; else echo "RC=1"; fi});
 like($out, qr/RC=0/, 'same version: gate passes (apply re-checks version_gt)');
}
{
 my ($out) = run_bash(q{if ota_gate_reason "2.13.4" "2.14.0" ""; then echo "RC=0"; else echo "RC=1"; fi});
 like($out, qr/RC=1/, 'cross-MINOR without directive: refused (fail-safe default)');
 like($out, qr/outside the OTA family/, 'cross-MINOR refusal is the reflash message');
}
{
 my ($out) = run_bash(q{if ota_gate_reason "2.13.4" "2.14.0" "What is new\n\nOTA-Family: cross\n\n- features"; then echo "RC=0"; else echo "RC=1"; fi});
 like($out, qr/RC=0/, 'cross-MINOR with directive: allowed');
}
{
 my ($out) = run_bash(q{if ota_gate_reason "2.13.4" "2.14.0" "ota-family:   CROSS"; then echo "RC=0"; else echo "RC=1"; fi});
 like($out, qr/RC=0/, 'directive match is case-insensitive and whitespace-tolerant');
}
{
 my ($out) = run_bash(q{if ota_gate_reason "2.13.4" "3.0.0" "OTA-Family: cross"; then echo "RC=0"; else echo "RC=1"; fi});
 like($out, qr/RC=1/, 'cross-MAJOR refuses even WITH the directive');
 like($out, qr/major version boundary/, 'cross-MAJOR names the major boundary');
}
{
 my ($out) = run_bash(q{if ota_gate_reason "2.13.4-beta" "2.14.0" "OTA-Family: cross"; then echo "RC=0"; else echo "RC=1"; fi});
 like($out, qr/RC=0/, 'prerelease suffix normalizes for the gate (apply has its own beta guard)');
}

# ── asset_matches_target ──
for my $c (
 [ 'pgenerator-plus-2.13.0.tar.gz',                    'pi4-biasi',          0, 'pi4 accepts unsuffixed payload'  ],
 [ 'pgenerator-plus-2.13.0-pi5-bookworm-armhf.tar.gz', 'pi4-biasi',          1, 'pi4 rejects pi5 payload'         ],
 [ 'pgenerator-plus-2.13.0.tar.gz',                    'pi5-bookworm-armhf', 1, 'pi5 rejects unsuffixed payload'  ],
 [ 'pgenerator-plus-2.13.0-pi5-bookworm-armhf.tar.gz', 'pi5-bookworm-armhf', 0, 'pi5 accepts pi5 payload'         ],
) {
 my ($name,$target,$want_rc,$label) = @$c;
 my ($out) = run_bash("if asset_matches_target '$name' '$target'; then echo MATCH; else echo NOMATCH; fi");
 is($out eq 'MATCH' ? 0 : 1, $want_rc, "asset_matches_target: $label");
}

# ── release_field asset_url picks per-target ──
# Real-world v2.13.0 asset order: pi5 tarball listed FIRST.
my $release_json = '{"tag_name":"v2.13.0","assets":['
 . '{"name":"pgenerator-plus-2.13.0-pi5-bookworm-armhf.tar.gz","browser_download_url":"https://example.invalid/pi5.tar.gz"},'
 . '{"name":"pgenerator-plus-2.13.0.tar.gz","browser_download_url":"https://example.invalid/pi4.tar.gz"},'
 . '{"name":"PGenerator_Plus_v2.13.0_pi4.img.7z.001","browser_download_url":"https://example.invalid/img.7z.001"}'
 . ']}';
open(my $b6,'>',"$tmp/b600.txt") or die $!; print $b6 ("x" x 600) . "\nOTA-Family: cross"; close($b6);
my $jsonfile = "$tmp/release.json";
open(my $jf,'>',$jsonfile) or die $!; print $jf $release_json; close($jf);

sub picked_asset {
 my ($target) = @_;
 my ($out) = run_bash(
  "release_json=\$(cat '$jsonfile'); release_field asset_url",
  (defined $target ? (PG_OTA_TARGET => $target) : ()));
 return $out;
}
is(picked_asset('pi5-bookworm-armhf'), 'https://example.invalid/pi5.tar.gz',
   'pi5 device picks the pi5 tarball');
is(picked_asset('pi4-biasi'), 'https://example.invalid/pi4.tar.gz',
   'pi4 device picks the unsuffixed tarball even when pi5 is listed first');
is(picked_asset(undef), 'https://example.invalid/pi5.tar.gz',
   'no target env keeps legacy first-tarball behaviour');

# Pi5-only release seen by a pi4 device: nothing matches, empty pick.
my $pi5only = '{"tag_name":"v2.99.0","assets":['
 . '{"name":"pgenerator-plus-2.99.0-pi5-bookworm-armhf.tar.gz","browser_download_url":"https://example.invalid/pi5.tar.gz"}'
 . ']}';
my $pi5onlyfile = "$tmp/pi5only.json";
open(my $pf,'>',$pi5onlyfile) or die $!; print $pf $pi5only; close($pf);
my ($empty) = run_bash("release_json=\$(cat '$pi5onlyfile'); release_field asset_url",
                       PG_OTA_TARGET => 'pi4-biasi');
is($empty, '', 'pi4 device gets no asset from a pi5-only release (apply refuses)');

# ── device_target: conf key wins, model string fallback ──
{
 my $conf = "$tmp/tconf";
 open(my $cf,'>',$conf) or die $!; print $cf "ota_target=pi5-bookworm-armhf\n"; close($cf);
 my ($out) = run_bash("device_target", PGENERATOR_CONF_FILE => $conf);
 is($out, 'pi5-bookworm-armhf', 'conf ota_target honored');
 open(my $cf2,'>',$conf) or die $!; print $cf2 "ota_target=banana-pi\n"; close($cf2);
 # No /proc/device-tree/model here (non-Pi test host) -> falls back to pi4.
 my ($out2) = run_bash("device_target", PGENERATOR_CONF_FILE => $conf);
 is($out2, 'pi4-biasi', 'unknown ota_target value falls back to model probe (pi4 default off-Pi)');
}

# ── directive window: body excerpt must reach past the old 500-char cap ──
{
 # Build the release JSON with a perl emitter file (no nested-quote maze).
 my $emit = "$tmp/emit.pl";
 open(my $ef,'>',$emit) or die $!;
 print $ef <<'PL';
use JSON::PP;
local $/; my $body = <STDIN>;
print encode_json({ body => $body });
PL
 close($ef);
 my $cmd = "release_json=\$(perl '$emit' < '$tmp/b600.txt'); release_field body | tail -c 60";
 my ($out) = run_bash($cmd);
 like($out, qr/OTA-Family: cross/, 'directive survives the body excerpt window (600+ chars in)');
}
