#!/usr/bin/perl
# Issue #66: the AP-config path still had #62's defect pair.
#  - webui_wifi_ap_apply() parsed the POST body with quote-terminated
#    regexes, so an SSID/passphrase containing an escaped quote was
#    truncated before it reached WIFI_AP_APPLYCONF.
#  - webui_wifi_ap_json() escaped quotes but not backslashes, so an AP
#    SSID containing \ emitted invalid JSON (\b decoded to backspace) or
#    failed to parse outright.
#  - apply() also lacked connect's guards: leading dash, control bytes,
#    length bounds — and its !$ssid test rejected an SSID of "0".
# Model: t/webui_wifi_scan_ssid_signal.t connect section.
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use Test::More;
use JSON::PP qw(decode_json);
use File::Temp qw(tempdir);
binmode(Test::More->builder->output,':utf8');
binmode(Test::More->builder->failure_output,':utf8');
require "$Bin/../usr/share/PGenerator/webui.pm";

# apply: what the browser JSON-stringifies must reach sudo byte-for-byte
my @sudo;
local *main::sudo = sub { @sudo = @_; "OK" };
sub ap_body { return JSON::PP->new->utf8(1)->encode({ssid=>$_[0], password=>$_[1]}); }
for my $ssid ('back\\slash', 'say "hi"', 'evil\\', 'a\\b"c', "caf\x{e9}", "\x{1F4F6} ap", '0') {
  @sudo = ();
  my $res = decode_json(main::webui_wifi_ap_apply(ap_body($ssid, 'pa"ss\\word1')));
  is($res->{status}, 'ok', "apply accepts $ssid") or diag(JSON::PP->new->encode($res));
  my $want = $ssid; utf8::encode($want);
  is($sudo[1], $want, "SSID reaches WIFI_AP_APPLYCONF unchanged: $ssid");
  is($sudo[2], 'pa"ss\\word1', 'passphrase with quote and backslash is not truncated');
}

# values built with \" \\ and \\" byte sequences, verified against the
# decoder. Bytes spelled with chr() so the fixture cannot rot in escaping.
my ($bs,$q)=(chr(92),chr(34));
for my $pair (['has '.$bs.$q.' quote', 'has '.$q.' quote'],
              ['slash '.$bs.$bs.' end', 'slash '.$bs.' end'],
              ['both '.$bs.$bs.$bs.$q.' here', 'both '.$bs.$q.' here']) {
  my ($encoded_form,$decoded_form)=@$pair;
  # the body bytes are exactly what JSON.stringify emits for the decoded value
  my $body='{"ssid":"'.$encoded_form.'","password":"passw0rd!"}';
  my $parsed = eval { JSON::PP->new->utf8(1)->decode($body) };
  ok(ref($parsed) eq 'HASH' && $parsed->{ssid} eq $decoded_form, "fixture is valid JSON for [$decoded_form]")
    or next;
  @sudo = ();
  my $res = decode_json(main::webui_wifi_ap_apply($body));
  is($res->{status}, 'ok', "apply accepts escaped-quote/backslash SSID");
  is($sudo[1], $decoded_form, "escaped sequence decodes exactly: [$decoded_form]");
}

# rejected input keeps its existing error paths and never reaches sudo
@sudo = ();
my $res = decode_json(main::webui_wifi_ap_apply('{"ssid":"","password":"abcdefgh"}'));
is($res->{status}, 'error', 'empty SSID rejected');
is($res->{message}, 'SSID required', 'empty SSID keeps SSID required message');
$res = decode_json(main::webui_wifi_ap_apply('not json'));
is($res->{status}, 'error', 'garbage body rejected');
$res = decode_json(main::webui_wifi_ap_apply(ap_body('x' x 33, 'abcdefgh')));
is($res->{status}, 'error', 'SSID over 32 bytes rejected');
$res = decode_json(main::webui_wifi_ap_apply(ap_body('y' x 32, 'a' x 64)));
is($res->{status}, 'error', 'passphrase over 63 bytes rejected');
$res = decode_json(main::webui_wifi_ap_apply(ap_body("a\x01b", 'abcdefgh')));
is($res->{status}, 'error', 'SSID with a control byte rejected');
$res = decode_json(main::webui_wifi_ap_apply(ap_body('ok', "a\x01b\x{ff}c")));
is($res->{status}, 'error', 'passphrase with a control byte rejected');
$res = decode_json(main::webui_wifi_ap_apply(ap_body('-p', 'abcdefgh')));
is($res->{status}, 'error', 'SSID starting with - rejected');
$res = decode_json(main::webui_wifi_ap_apply(ap_body('ok', '-pssphrase')));
is($res->{status}, 'error', 'passphrase starting with - rejected');
$res = decode_json(main::webui_wifi_ap_apply(ap_body('net', 'short')));
is($res->{status}, 'error', 'short passphrase still rejected');
is($res->{message}, 'Password must be at least 8 characters', 'short passphrase keeps its message');
is(scalar(@sudo), 0, 'rejected requests never reach sudo');
for my $bad ('{"ssid":123,"password":"abcdefgh"}', '{"ssid":"net","password":123}',
             '{"ssid":"net","password":["a"]}', '{"ssid":"net","password":{"a":1}}',
             '{"ssid":["net"],"password":"abcdefgh"}') {
  $res = decode_json(main::webui_wifi_ap_apply($bad));
  is($res->{status}, 'error', "non-string field rejected: $bad");
}
is(scalar(@sudo), 0, 'wrong-type requests never reach sudo');

# GET -> edit -> POST round trip: a hostapd.conf whose ssid and passphrase
# contain backslashes and quotes must come out as JSON that parses back to
# the exact stored value (quote-only escaping corrupted \b into backspace).
my $tmp = tempdir(CLEANUP=>1);
open(my $w, '>', "$tmp/hostapd.conf") or die $!;
print $w "interface=wlan0\n";
print $w "ssid=a\\b\"c\n";
print $w "wpa_passphrase=evil\\\n";
close($w);
{
  local $main::hostapd_conf = "$tmp/hostapd.conf";
  my $ap;
  ok(eval { $ap = decode_json(main::webui_wifi_ap_json()); 1 }, 'AP GET JSON parses')
    or diag('quote-only escaping emitted invalid JSON');
  is($ap && $ap->{ssid}, 'a\\b"c', 'AP SSID with backslash and quote round-trips');
  is($ap && $ap->{password}, 'evil\\', 'AP passphrase ending in backslash round-trips');
}

done_testing();
