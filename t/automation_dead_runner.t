use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR} = tempdir(CLEANUP => 1);
PGAutomation::ensure_store();
my $execution_path = PGAutomation::base_dir() . '/execution.json';
# Never a live process: pid_is_live needs /proc/<pid> and a matching cmdline.
my $dead_pid = 2147483647;

sub write_run {
 my ($id, %run) = @_;
 make_path(PGAutomation::run_dir($id) . '/items');
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id) . '/run.json', {id=>$id,token=>'t',status=>'running',active_item=>0,active_stage=>'greyscale-done',runner_pid=>$dead_pid,items=>[{name=>'Item',status=>'running',checkpoints=>[]}],%run});
 return PGAutomation::run_dir($id) . '/run.json';
}
sub write_execution {
 my (%execution) = @_;
 PGAutomation::write_json_atomic($execution_path, {owner=>'automation',token=>'t',status=>'running',pid=>$dead_pid,updated_at=>PGAutomation::now(),%execution});
}

is(main::webui_automation_reap_dead_runner(), 0, 'nothing to reap without an execution claim');

my $id = PGAutomation::new_id();
my $path = write_run($id);
write_execution(run_id=>$id);
is(main::webui_automation_reap_dead_runner(), 1, 'a running claim whose runner pid is dead is reaped');
my $run = PGAutomation::read_json_file($path);
is($run->{status}, 'interrupted', 'run is marked interrupted');
is($run->{failure}{error_code}, 'runner-died', 'failure names the dead runner');
is($run->{runner_pid}, 0, 'stale runner pid cleared');
is($run->{items}[0]{status}, 'interrupted', 'active item is marked interrupted');
is($run->{items}[0]{checkpoints}[-1]{status}, 'interrupted', 'active stage gets an interrupted checkpoint');
my $execution = PGAutomation::read_json_file($execution_path);
is($execution->{status}, 'interrupted', 'execution claim is released to interrupted so Stop and Resume work');
is($execution->{pid}, 0, 'execution pid cleared');
is(main::webui_automation_reap_dead_runner(), 0, 'an interrupted claim is left alone');

$id = PGAutomation::new_id();
$path = write_run($id, status=>'starting', runner_pid=>0);
write_execution(run_id=>$id, status=>'starting', pid=>0);
is(main::webui_automation_reap_dead_runner(), 0, 'a freshly launched runner with no pid yet is given a grace period');
is(PGAutomation::read_json_file($path)->{status}, 'starting', 'run untouched inside the grace period');
write_execution(run_id=>$id, status=>'starting', pid=>0, updated_at=>PGAutomation::now() - main::webui_automation_start_grace() - 1);
is(main::webui_automation_reap_dead_runner(), 1, 'a runner that never recorded a pid is reaped after the grace period');
is(PGAutomation::read_json_file($path)->{status}, 'interrupted', 'never-started run is marked interrupted');
is(PGAutomation::read_json_file($execution_path)->{status}, 'interrupted', 'never-started claim is released');

$id = PGAutomation::new_id();
$path = write_run($id, status=>'paused', runner_pid=>0);
write_execution(run_id=>$id, status=>'paused', pid=>0);
is(main::webui_automation_reap_dead_runner(), 0, 'a paused run has no runner by design and is not reaped');
is(PGAutomation::read_json_file($path)->{status}, 'paused', 'paused run untouched');

# A live runner is never reaped, whichever platform the daemon runs on.
{
 no warnings 'redefine';
 local *PGAutomation::pid_is_live = sub { my ($pid, $needle) = @_; return ($pid == 4242 && ($needle || '') eq 'pgen_automation_runner.pl') ? 1 : 0; };
 $id = PGAutomation::new_id();
 $path = write_run($id, runner_pid=>4242);
 write_execution(run_id=>$id, pid=>4242);
 is(main::webui_automation_reap_dead_runner(), 0, 'a live runner is left alone');
 is(PGAutomation::read_json_file($path)->{status}, 'running', 'live run untouched');
 is(PGAutomation::read_json_file($execution_path)->{status}, 'running', 'live claim untouched');
}

# Death between stages: the item is interrupted but no checkpoint is invented,
# so resume keeps the item's verified progress.
$id = PGAutomation::new_id();
$path = write_run($id, active_stage=>'', items=>[{name=>'Item',status=>'running',checkpoints=>[{name=>'greyscale-done',status=>'done',verified=>1}]}]);
write_execution(run_id=>$id);
is(main::webui_automation_reap_dead_runner(), 1, 'a runner that died between stages is reaped');
$run = PGAutomation::read_json_file($path);
is($run->{items}[0]{status}, 'interrupted', 'item interrupted between stages');
is(scalar(@{$run->{items}[0]{checkpoints}}), 1, 'no checkpoint is fabricated when no stage was active');
is($run->{items}[0]{checkpoints}[-1]{name}, 'greyscale-done', 'the last real checkpoint is preserved');

# Boot recovery uses the same path with its own reason.
$id = PGAutomation::new_id();
$path = write_run($id);
write_execution(run_id=>$id);
ok(main::webui_automation_boot_recover(), 'boot recovery runs');
$run = PGAutomation::read_json_file($path);
is($run->{status}, 'interrupted', 'boot recovery interrupts a run with a dead runner');
is($run->{failure}{error_code}, 'daemon-restarted', 'boot recovery names the daemon restart');
is($run->{items}[0]{checkpoints}[-1]{evidence}{reason}, 'daemon-restarted', 'interrupted checkpoint records the reason');
is(PGAutomation::read_json_file($execution_path)->{status}, 'interrupted', 'boot recovery releases the claim');

# A stale claim over a finished run is deleted.
$id = PGAutomation::new_id();
write_run($id, status=>'complete', runner_pid=>0);
write_execution(run_id=>$id);
ok(main::webui_automation_reconcile_execution(), 'reconcile runs');
ok(!-f $execution_path, 'a claim left behind by a complete run is removed');

# Completing window: active_item still names the last item after it finished.
$id = PGAutomation::new_id();
$path = write_run($id, status=>'completing', active_stage=>'', items=>[{name=>'Item',status=>'complete',checkpoints=>[{name=>'item-complete',status=>'done'}]}]);
write_execution(run_id=>$id, status=>'completing');
is(main::webui_automation_reap_dead_runner(), 1, 'a runner that died while completing is reaped');
$run = PGAutomation::read_json_file($path);
is($run->{status}, 'interrupted', 'run can be resumed to finish');
is($run->{items}[0]{status}, 'complete', 'the finished item is not reopened');

# A claim whose manifest is unreadable is dropped, not left blocking the guided UI.
$id = PGAutomation::new_id();
make_path(PGAutomation::run_dir($id) . '/items');
PGAutomation::write_atomic(PGAutomation::run_dir($id) . '/run.json', "garbage\n");
write_execution(run_id=>$id);
is(main::webui_automation_reap_dead_runner(), 1, 'a claim over an unreadable manifest is handled');
ok(!-f $execution_path, 'the claim is removed because nothing can act on that run');

# A cleanup runner that never starts keeps the run parked for a later Stop retry.
{
 no warnings 'redefine';
 local *main::webui_automation_launch_runner = sub { 1 };
 $id = PGAutomation::new_id();
 $path = write_run($id, status=>'interrupted', runner_pid=>0, failure=>{stage=>'greyscale-done',error_code=>'runner-died',message=>'m'});
 write_execution(run_id=>$id, status=>'interrupted', pid=>0);
 my $reply = PGAutomation::decode_json(main::webui_automation_control($id, 'stop'));
 is($reply->{status}, 'ok', 'first stop relaunches the runner for cleanup');
 $run = PGAutomation::read_json_file($path);
 is($run->{stop_relaunches}, 1, 'relaunch is counted');
 is($run->{status}, 'stopping', 'cleanup runner is visibly stopping, not running calibration');
 write_execution(run_id=>$id, status=>'stopping', pid=>0, updated_at=>PGAutomation::now() - main::webui_automation_start_grace() - 1);
 is(main::webui_automation_reap_dead_runner(), 1, 'the cleanup runner that never started is reaped');
 $reply = PGAutomation::decode_json(main::webui_automation_control($id, 'stop'));
 is($reply->{status}, 'error', 'failed cleanup is not reported as successful stop');
 like($reply->{message}, qr/calibration exit is unconfirmed/, 'operator is told TV cleanup did not run');
 $run = PGAutomation::read_json_file($path);
 is($run->{status}, 'interrupted', 'run retains a visible, retryable cleanup failure');
 is($run->{failure}{error_code}, 'runner-start-failed', 'failure explains why');
 ok(!$run->{stop_cleanup}{verified}, 'TV exit remains explicitly unverified');
 is(PGAutomation::read_json_file($execution_path)->{run_id},$id,
  'claim remains until Stop cleanup can confirm TV exit');
 # Resume clears the counter so a later, unrelated interruption gets a fresh cleanup attempt.
 $id = PGAutomation::new_id();
 $path = write_run($id, status=>'interrupted', runner_pid=>0, stop_relaunches=>1, failure=>{error_code=>'runner-died'});
 write_execution(run_id=>$id, status=>'interrupted', pid=>0);
 local *main::webui_automation_readiness_data = sub { return {ready=>1, items=>[]}; };
 local *main::webui_lg_status_json = sub { return PGAutomation::encode_json({connected=>1,paired=>1}); };
 $reply = PGAutomation::decode_json(main::webui_automation_control($id, 'resume'));
 is($reply->{status}, 'ok', 'resume succeeds');
 is($reply->{run}{status}, 'starting', 'resume reports launch rather than an already-running worker');
 is($reply->{run}{active_stage}, 'readiness', 'resume no longer publishes the failed stage as current work');
 ok(!defined($reply->{run}{heartbeat_age}), 'old heartbeat is not presented as a new runner stall');
 ok(!exists($reply->{run}{worker_status}{current_step}), 'previous attempt patch counter is cleared');
 ok(!exists(PGAutomation::read_json_file($path)->{stop_relaunches}), 'resume resets the relaunch counter');
}
done_testing();
