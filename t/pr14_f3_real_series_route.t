# Agent BC: REAL webui_meter_series_start + webui_meter_series_status with
# system() captured (no worker launched) and the state file redirected.
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
my @system;
BEGIN { *CORE::GLOBAL::system = sub { push @system, join(' ',@_); return 0; }; }
use File::Temp qw(tempdir);
use Test::More;
my $WT;BEGIN{require FindBin;$WT="$FindBin::Bin/.."}
use lib "$WT/usr/share/PGenerator";
use PGAutomation ();
use threads; use threads::shared;
{ local $SIG{__WARN__}=sub{}; for my $m (qw(variables.pm command.pm)) { do "$WT/usr/share/PGenerator/$m"; die "$m: $@" if $@; } }
require "$WT/usr/share/PGenerator/webui.pm";
my $tmp=tempdir(CLEANUP=>1);

$ENV{PGEN_AUTOMATION_DIR}="$tmp/automation";PGAutomation::ensure_store();
$main::_meter_series_file="$tmp/meter_series.json";
local *main::webui_meter_series_alive=sub {0};
local *main::webui_meter_session_alive=sub {0};
local *main::webui_meter_session_stop_only=sub {1};
local *main::lg_automation_guard_json=sub {''};
my $body=PGAutomation::encode_json({type=>'greyscale',points=>21,display_type=>'lcd',signal_mode=>'sdr',target_gamma=>'bt1886',
  delay_ms=>1000,patch_size=>10,automation_worker_id=>'runA-0-20260917-010203-abcdef',automation_token=>'tok'});
my $r=eval {PGAutomation::decode_json(main::webui_meter_series_start($body))};
diag($@) if $@;
is($r->{status},'started','real series start route accepts payload') or diag explain $r;
ok(scalar(@system)>=1,'worker launch captured, not executed');
my $seed=PGAutomation::read_json_file($main::_meter_series_file)||{};
is($seed->{automation_worker_id},'runA-0-20260917-010203-abcdef','seeded state carries the attempt id (first poll)');
ok(exists $seed->{points},'seed carries points so the shell writer will re-splice identity');
my $st=PGAutomation::decode_json(main::webui_meter_series_status(0));
is(PGAutomation::worker_id($st),'runA-0-20260917-010203-abcdef','very first status poll returns the id');
my $st2=PGAutomation::decode_json(main::webui_meter_series_status(1));
is(PGAutomation::worker_id($st2),'runA-0-20260917-010203-abcdef','summary status poll returns the id');
# replay of the same start (lost reply) must not launch again
my $n=scalar(@system);
my $again=PGAutomation::decode_json(main::webui_meter_series_start($body));
is($again->{status},'started','replayed start answers started');
ok($again->{replayed},'replay flagged');
is(scalar(@system),$n,'replayed start launches nothing');
# "process died" rewrite after 3 s keeps id
utime(time()-10,time()-10,$main::_meter_series_file);
my $died=PGAutomation::decode_json(main::webui_meter_series_status(0));
is($died->{status},'error','dead worker reported');
is(PGAutomation::worker_id($died),'runA-0-20260917-010203-abcdef','process-died rewrite keeps the id');
done_testing();
