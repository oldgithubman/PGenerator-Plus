use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
my $id='cleanup-proof';my $token='cleanup-token';
my $path=PGAutomation::run_dir($id).'/run.json';my $execution=PGAutomation::base_dir().'/execution.json';
{local @ARGV=($id,$token);do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my ($meter_ok,$launched)=(1,0);
local *main::_log=sub{};
# This suite supplies completed cleanup evidence directly; the separate
# Stop tests exercise reacting to control requests and running cleanup.
local *main::_control=sub {{request=>'none'}};
local *main::_api=sub {is($_[1],'/api/meter/session/stop','finish only releases the meter after recorded TV cleanup');return $meter_ok?{status=>'ok'}:{status=>'error',message=>'USB still held'};};
local *main::webui_automation_reap_dead_runner=sub{0};
sub save {
 my (%extra)=@_;
 PGAutomation::write_json_atomic($path,{id=>$id,token=>$token,status=>'stopping',items=>[{id=>'finished',status=>'complete',checkpoints=>[{name=>'item-complete',status=>'done'}]}],%extra});
 PGAutomation::write_json_atomic($execution,{owner=>'automation',run_id=>$id,token=>$token,status=>'stopping',pid=>0});
}
save(stop_cleanup=>{verified=>JSON::PP::false,completed_at=>time(),message=>'CAL_END not acknowledged'},failure=>{message=>'Original failure'});
ok(!main::_finish('stopped'),'unverified exit is not a terminal successful Stop');
my $run=PGAutomation::read_json_file($path);
is($run->{status},'interrupted','failed cleanup remains recoverable');
ok($run->{cleanup_required},'cleanup requirement persists across process exits');
ok(!exists($run->{completed_at}),'unfinished cleanup has no completion timestamp');
is($run->{items}[0]{status},'complete','completed calibration evidence is not reopened');
is(PGAutomation::read_json_file($execution)->{run_id},$id,'ownership retained after CAL_END failure');
is(PGAutomation::read_json_file($execution)->{status},'interrupted','claim identifies required recovery');
{
 local *main::webui_automation_reconnect_for_resume=sub{die 'Resume must not touch TV while cleanup required'};
 my $r=PGAutomation::decode_json(main::webui_automation_control($id,'resume'));
 is($r->{error_code},'cleanup-required','Resume refuses before connection or readiness calls');
 $r=PGAutomation::decode_json(main::webui_automation_control($id,'clear'));
 is($r->{error_code},'cleanup-required','Clear cannot hide pending cleanup');
 $r=PGAutomation::decode_json(main::webui_automation_delete_run($id));
 is($r->{error_code},'cleanup-required','Delete cannot remove required recovery evidence');
 ok(main::webui_automation_public_run($run)->{cleanup_required},'UI receives the recovery requirement');
}
{
 local *main::webui_automation_launch_runner=sub{$launched++;return 0;};
 for (1..2) {
  my $r=PGAutomation::decode_json(main::webui_automation_control($id,'stop'));
  is($r->{error_code},'stop-cleanup-unverified','failed cleanup launch is retryable, not success');
  is(PGAutomation::read_json_file($execution)->{run_id},$id,'failed retry retains ownership');
 }
 is($launched,2,'each explicit Stop actually attempts recovery, without permanent relaunch lockout');
}
# A genuinely verified retry can finish; merely issuing Stop never clears proof.
PGAutomation::with_lock($path,sub {$_[0]{stop_cleanup}={verified=>JSON::PP::true,completed_at=>time(),message=>'Workers stopped; meter released; CAL_END acknowledged'};return $_[0];});
ok(main::_finish('stopped'),'verified cleanup releases ownership');
$run=PGAutomation::read_json_file($path);
is($run->{status},'stopped','successful retry becomes terminal');
ok(!$run->{cleanup_required},'successful retry clears cleanup requirement');
ok(!-e $execution,'successful cleanup releases the matching claim');
ok(!$run->{failure},'obsolete cleanup failure is no longer active');
is($run->{items}[0]{checkpoints}[0]{name},'item-complete','calibration results survive cleanup retry');

$meter_ok=0;
save(status=>'completing',stop_cleanup=>{verified=>JSON::PP::true,completed_at=>time()});
ok(!main::_finish('complete'),'failed final meter release cannot report clean completion');
$run=PGAutomation::read_json_file($path);
like($run->{failure}{message},qr/USB still held/,'actual meter-release failure is visible');
ok(-e $execution,'meter release failure retains claim');
is($run->{status},'interrupted','final meter failure remains retryable');
$meter_ok=1;
# Terminal state must be durable before releasing the claim.
save(stop_cleanup=>{verified=>JSON::PP::true});
{
 local *main::_update_run=sub{undef};
 ok(!eval {main::_finish('stopped');1},'terminal persistence failure is not silently accepted');
 ok(-e $execution,'failed terminal write does not release ownership');
}
# Upgrade path from the old bug: terminal failure with no claim can be retried.
save(status=>'failed',stop_cleanup=>{verified=>JSON::PP::false,message=>'Legacy cleanup failure',completed_at=>time()});unlink $execution;
{
 local *main::webui_automation_launch_runner=sub {$launched++;return 0;};
 my $r=PGAutomation::decode_json(main::webui_automation_control($id,'stop'));
 is($r->{error_code},'stop-cleanup-unverified','legacy failed cleanup is admitted to recovery');
 is(PGAutomation::read_json_file($execution)->{run_id},$id,'legacy cleanup reclaims otherwise idle ownership');
}
# Never steal another current run from an old interrupted or terminal history row.
for my $status (qw(interrupted failed stopped)) {
 save(status=>$status,cleanup_required=>1);
 PGAutomation::write_json_atomic($execution,{run_id=>'other-run',token=>'other-token',status=>'running'});
 my $before=$launched;
 local *main::webui_automation_launch_runner=sub{$launched++;return 1;};
 my $r=PGAutomation::decode_json(main::webui_automation_control($id,'stop'));
 is($r->{error_code},'automation-owner-mismatch',"$status recovery does not steal another run");
 is($launched,$before,'no cleanup child is launched against another owner');
 is(PGAutomation::read_json_file($execution)->{run_id},'other-run','other owner remains untouched');
}
# Reconciliation must preserve legacy terminal cleanup, not clear its claim.
save(status=>'failed',stop_cleanup=>{verified=>JSON::PP::false,completed_at=>time()});
main::webui_automation_reconcile_execution();
is(PGAutomation::read_json_file($execution)->{status},'interrupted','reconciliation preserves cleanup obligation');
# Stale evidence from before a later resume is not a new failure.
save(status=>'completing',resumed_at=>200,stop_cleanup=>{verified=>JSON::PP::false,completed_at=>100});
ok(main::_finish('complete'),'old cleanup evidence cannot describe a later successful attempt');
done_testing();
