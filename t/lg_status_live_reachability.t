#!/usr/bin/perl
# /api/lg/status used to derive `connected` from the saved client record alone
# (paired && !disconnected). A C1 in standby with both SSAP ports closed still
# reported connected: true, so automation readiness, resume and the runner's
# _ensure_lg_connection() all skipped reconnecting and started against a
# sleeping TV. A failed /api/lg/connect inherited the same stale flag, so the
# runner's retry loop, which checks only `connected`, counted the failure as a
# success. Reproduced on the unit 2026-09-23: ports 3000/3001 closed, status
# connected: true, connect status: error with connected: true.
#
# These assertions pin the live probe in lg_status_data(), the failed-connect
# override, and the successful-connect cache refresh.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
our (%pgenerator_conf);
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

no warnings qw(redefine once);

my $TV='192.0.2.35';
my %clients=(client_key=>'saved-key',ip=>$TV,name=>'OLED65C1PUB',model_name=>'OLED65C1PUB');
my $port_open=0;
my $probes=0;
local *main::log=sub {};
local *main::lg_load_clients=sub { return {%clients} };
local *main::lg_save_clients=sub { %clients=%{$_[0]}; return 1 };
local *main::lg_reconcile_pin_pairing=sub { return ($_[0],{}) };
local *main::lg_cec_status=sub { return {} };
local *main::lg_detect_from_cec=sub { return 0 };
local *main::lg_webos_port_open=sub { $probes++; return $port_open ? 3000 : 0 };
my $real_update_connect_metadata=\&main::lg_update_connect_metadata;

sub status_now { &main::lg_webos_reachable_reset(); return &main::lg_status_data() }

# Sleeping TV: paired, not user-disconnected, but nothing answers.
$port_open=0;
my $s=status_now();
ok(!$s->{connected},'a paired TV that answers on neither SSAP port is not connected');
ok(!$s->{reachable},'reachable reports the failed live probe');
ok($s->{paired},'the saved pairing is still reported as paired');
like($s->{message},qr/not answering/i,'the message says the TV is not answering');
like($s->{message},qr/\Q$TV\E/,'the message names the address that was probed');

# Awake TV.
$port_open=1;
$s=status_now();
ok($s->{connected},'a paired TV that answers is connected');
ok($s->{reachable},'reachable reports the successful live probe');

# A user-disconnected TV is not probed at all.
$clients{disconnected}=1;
$probes=0;
$s=status_now();
ok(!$s->{connected},'a user-disconnected TV stays disconnected');
is($probes,0,'no network probe while the user has disconnected the TV');
delete $clients{disconnected};

# UI polling is bounded: back-to-back status calls share one probe.
&main::lg_webos_reachable_reset();
$probes=0;
&main::lg_status_data() for 1..5;
is($probes,1,'repeated status calls inside the cache window probe once');

# A failed connect must not report connected, even when the ports answer
# (for example a rejected key) - neither in the connect reply nor in the
# status call the runner makes right after it.
$port_open=1;
local *main::lg_helper_run=sub {
 my $req=shift;
 return {status=>'ok'} if(($req->{action}||'') eq 'probe');
 return {status=>'error',message=>'Unable to connect to LG WebOS TV'};
};
&main::lg_webos_reachable_reset();
my $r=&main::lg_decode_json(&main::webui_lg_connect('{}'));
is($r->{status},'error','the failed connect keeps its error status');
ok(!$r->{connected},'a failed connect reports connected: false');
$s=status_now();
ok($s->{reachable},'the ports still answer after the failed connect');
ok(!$s->{connected},'status after a failed connect is not connected, even with open ports');
ok($s->{connect_failed},'status reports the failed connect');
like($s->{message},qr/last connection .* failed/i,'the message names the failed connection');

# A helper that returns no result at all (a crash, garbled output) is a failed
# connect too: it must set the marker, not leave status reading connected.
delete $clients{connect_failed_at};
local *main::lg_helper_run=sub {
 my $req=shift;
 return {status=>'ok'} if(($req->{action}||'') eq 'probe');
 return undef;
};
$r=&main::lg_decode_json(&main::webui_lg_connect('{}'));
is($r->{status},'error','a connect with no helper result reports an error');
ok(!$r->{connected},'a connect with no helper result reports connected: false');
$s=status_now();
ok($s->{reachable} && !$s->{connected},'status after a connect with no helper result is not connected, even with open ports');
ok($s->{connect_failed},'status reports the connect with no helper result as failed');

# A successful connect proves reachability: a stale "unreachable" cache entry
# from a status call made just before the TV woke must not contradict it.
$port_open=0;
&main::lg_webos_reachable_reset();
&main::lg_status_data();
$port_open=1;
local *main::lg_helper_run=sub { return {status=>'ok',ip=>$TV,client_key=>'saved-key'} };
local *main::lg_update_connect_metadata=$real_update_connect_metadata;
$r=&main::lg_decode_json(&main::webui_lg_connect('{}'));
is($r->{status},'ok','the successful connect reports ok');
ok($r->{connected},'a successful connect is connected despite an earlier cached miss');
$s=status_now();
ok($s->{connected} && !$s->{connect_failed},'a successful connect clears the failure marker');

# A disconnect (power-cycle, unplug) drops the cached probe, so the next status
# probes the TV afresh instead of reusing an answer from before it went away.
&main::lg_status_data();
$port_open=0;
&main::lg_mark_disconnected();
delete $clients{disconnected};
$s=&main::lg_status_data();
ok(!$s->{reachable} && !$s->{connected},'status right after a disconnect probes afresh');
$port_open=1;

# Readiness must not pass a paired TV that is not connected; it has to try
# the reconnect, which produces the "turn the TV on" error.
{
 my $reconnects=0;
 local *main::webui_lg_status_json=sub { &main::lg_encode_json({status=>'ok',paired=>1,connected=>0,reachable=>0,disconnected=>0}) };
 local *main::webui_automation_reconnect_for_readiness=sub { $reconnects++; return {status=>'error',error_code=>'tv-reconnect-failed',message=>'The LG TV is paired, but reconnecting failed: TV did not answer.'} };
 local *main::webui_meter_status=sub {'{"detected":1}'};
 local *main::webui_meter_series_alive=sub {0};local *main::webui_meter_lg_autocal_running=sub {0};
 local *main::webui_meter_lg_3d_autocal_running=sub {0};local *main::webui_meter_lg_dv_profile_running=sub {0};local *main::webui_meter_session_alive=sub {0};
 local *main::webui_automation_read_execution=sub { undef };
 my $ready=&main::webui_automation_readiness_data({items=>[{name=>'Q',signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>1,apply_all=>1,post_readings=>0}}]});
 my ($lg_check)=grep { ($_->{name}||'') eq 'lg-paired' } @{$ready->{checks}||[]};
 is($reconnects,1,'readiness attempts the reconnect for a paired TV that is not connected');
 ok($lg_check && !$lg_check->{ok},'readiness fails the TV check instead of reporting it connected');
 like($lg_check ? $lg_check->{message} : '',qr/reconnecting failed/,'readiness shows the reconnect error');
}

# Pin the load-bearing code so deleting the probe cannot stay green.
my $src=do { local(@ARGV,$/)="$Bin/../usr/share/PGenerator/lg.pm"; <> };
my ($body)=$src=~/^sub lg_status_data \(\@\) \{\n(.*?)^\}/ms;
like($body,qr/lg_webos_reachable_cached\(/,'lg_status_data probes the TV live');
like($body,qr/my \$connected=\(\$paired && !\$disconnected && \$reachable && !\$connect_failed\)/,'connected requires reachability and no failed connect');
like($body,qr/reachable => &lg_json_bool\(\$reachable\)/,'status exposes the reachable field');
my ($conn)=$src=~/^sub webui_lg_connect \(\@\) \{\n(.*?)^\}/ms;
like($conn,qr/"connected"\}=&lg_json_false\(\)/,'webui_lg_connect forces connected false on failure');
my ($meta)=$src=~/^sub lg_update_connect_metadata \(\@\) \{\n(.*?)^\}/ms;
like($meta,qr/delete\(\$clients->\{"connect_failed_at"\}\);/,'a successful connect clears the failure marker');
like($meta,qr/\$clients->\{"connect_failed_at"\}=time\(\);/,'a failed connect sets the failure marker');
my $webui=do { local(@ARGV,$/)="$Bin/../usr/share/PGenerator/webui.pm"; <> };
my ($readiness)=$webui=~/^sub webui_automation_readiness_data \(\@\) \{\n(.*?)^\}/ms;
like($readiness,qr/my \$lg_connected=\$static_only \? 1 : \(\$lg->\{connected\} && !\$lg->\{disconnected\}\)/,'readiness gates on connected');
unlike($readiness,qr/\(\$lg->\{paired\} && !\$lg->\{disconnected\}\) \|\|/,'readiness no longer treats paired as connected');

done_testing();

