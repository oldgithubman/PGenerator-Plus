use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use Test::More;
use File::Temp qw(tempdir);
use PGAutomation ();
use PGAutomationETA ();
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
sub job {
 return {signal_format=>'sdr',picture_mode=>'filmMaker',status=>'running',settings=>{gamma=>'high2'},
  device_identity=>{model_name=>'Test TV'},calibration=>{target_delta_e=>.5},
  stages=>{pre_readings=>0,calibration=>1,post_readings=>0,apply_all=>0}};
}
sub run {
 return {id=>'eta-test',status=>'running',active_item=>0,active_stage=>'greyscale-done',stage_started_at=>1000,
  items=>[job()],worker_status=>{status=>'running',current_step=>6,total_steps=>26},
  worker_timing=>{kind=>'grey',stage=>'greyscale-done',started_at=>1000,start_step=>0}};
}
my $r=run();
my $before=PGAutomation::clone($r);
PGAutomationETA::update($r,1100,[]);
is($r->{time_estimate}{scope},'unknown','no guessed ETA before sufficient elapsed time');
my $after=PGAutomation::clone($r);delete $after->{time_estimate};
is_deeply($after,$before,'estimate metadata does not alter calibration configuration');
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{scope},'stage','live point pace gives a labelled stage estimate');
is($r->{time_estimate}{remaining_seconds},1260,'five completed points in 300 seconds leaves 21 points');
$r->{worker_status}{current_step}=7;
PGAutomationETA::update($r,1350,[]);
is($r->{time_estimate}{calculated_at},1350,'advancing to the next calibrated point recalculates immediately');
PGAutomationETA::update($r,1420,[]);
is($r->{time_estimate}{calculated_at},1350,'same-point polls remain throttled');
PGAutomationETA::update($r,1470,[]);
is($r->{time_estimate}{remaining_seconds},1566,'pace is recomputed after two minutes on a slow point');

$r=run();$r->{worker_timing}{start_step}=3;
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{scope},'unknown','counter restart waits for three new completed points');
$r->{worker_status}{current_step}=8;
PGAutomationETA::update($r,1420,[]);
is($r->{time_estimate}{remaining_seconds},1995,'counter restart uses only progress since the reset');

$r=run();
my $history=[map {{profile=>PGAutomationETA::profile($r->{items}[0]),stage=>$_,seconds=>60}} @{PGAutomationETA::plan($r->{items}[0])}];
$r->{items}[0]{checkpoints}=[map {{name=>$_,status=>'done',duration_seconds=>60}} qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled)];
my $next=job();$next->{status}='queued';delete $next->{device_identity};push @{$r->{items}},$next;
PGAutomationETA::update($r,1300,$history);
is($r->{time_estimate}{scope},'batch','comparable history plus live pace gives a full batch estimate');
is($r->{time_estimate}{remaining_seconds},2040,'batch includes current remainder, later stages and next job, but not completed checkpoints');
my $no_post=$r->{time_estimate}{remaining_seconds};
$r->{items}[1]{stages}{post_readings}=1;
push @$history,{profile=>PGAutomationETA::profile($r->{items}[0]),stage=>'post-readings-done',seconds=>600};
PGAutomationETA::update($r,1310,$history);
cmp_ok($r->{time_estimate}{remaining_seconds},'>',$no_post+590,'pending sweep opt-in changes the estimate immediately');
is($r->{time_estimate}{calculated_at},1310,'queue edits invalidate the cache');
$r->{items}[1]{signal_format}='hdr10';
PGAutomationETA::update($r,1320,$history);
is($r->{time_estimate}{scope},'stage','unknown HDR timing is not filled with SDR history');
$r->{items}[1]{signal_format}='sdr';$r->{items}[1]{calibration}{target_delta_e}=.2;
PGAutomationETA::update($r,1330,$history);
is($r->{time_estimate}{scope},'stage','a different target needs comparable history');

$r=run();$r->{active_stage}='post-readings-done';
$r->{items}[0]{post_series}=[qw(greyscale-21 colors-30 saturations-24)];
$r->{worker_timing}={kind=>'series',stage=>'post-readings-done',started_at=>1000,series_key=>'colors-30'};
$r->{worker_status}={status=>'running',current_step=>7,total_steps=>30};
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{remaining_seconds},2450,'post-stage estimate includes ColorChecker plus 24 saturations and their white reference, not finished greyscale');
$r->{worker_status}{status}='complete';
PGAutomationETA::update($r,1310,[]);
is($r->{time_estimate}{scope},'unknown','completed sub-pass never shows a false zero-time batch estimate');
$r->{active_stage}='volume-done';
PGAutomationETA::update($r,1320,[]);
is($r->{time_estimate}{scope},'unknown','previous stage pace does not leak into volume solve/upload');
for my $status (qw(paused stopped complete failed interrupted stopping)) {
 $r=run();PGAutomationETA::update($r,1300,[]);$r->{status}=$status;
 PGAutomationETA::update($r,1310,[]);
 ok(!exists($r->{time_estimate}),"$status clears live ETA");
}
$r=run();PGAutomationETA::update($r,1300,[]);$r->{resumed_at}=1310;
PGAutomationETA::update($r,1320,[]);
is($r->{time_estimate}{calculated_at},1320,'resume invalidates earlier estimate');
is($r->{time_estimate}{scope},'unknown','pre-resume worker clock cannot count paused time as measurement pace');

my $saved={id=>'saved-eta',items=>[job()]};
$saved->{items}[0]{checkpoints}=[{name=>'greyscale-done',status=>'done',duration_seconds=>500},
 {name=>'volume-done',status=>'skipped',duration_seconds=>100},
 {name=>'post-readings-done',status=>'done',duration_seconds=>900,timing_interrupted=>1},
 {name=>'tv-setup-verified',status=>'done'}];
is(scalar @{PGAutomationETA::samples($saved)},1,'only timed completed stages enter history');
PGAutomation::write_json_atomic(PGAutomation::run_dir($saved->{id}).'/run.json',$saved);
is(scalar @{PGAutomationETA::history('current')},1,'historical timings survive process restart');
is(scalar @{PGAutomationETA::history($saved->{id})},0,'current run is not counted twice');
$r=run();PGAutomationETA::update($r,1300,[]);$r->{time_estimate}{private}='secret';
my $public=main::webui_automation_public_run($r);
is($public->{time_estimate}{remaining_seconds},1260,'ETA reaches lightweight status API');
ok(!exists($public->{time_estimate}{identity})&&!exists($public->{time_estimate}{private}),'internal fingerprints and extra fields stay private');
$r->{resumed_at}=1400;
ok(!exists(main::webui_automation_public_run($r)->{time_estimate}),'API suppresses pre-resume estimates');

$r=run();
my $prior=job();$prior->{picture_mode}='cinema';$prior->{settings}{gamma}='low';
$prior->{low_light}={enabled=>JSON::PP::true,mode=>'a',trigger=>1};
$r->{items}[0]{low_light}=PGAutomation::clone($prior->{low_light});
is(PGAutomationETA::timing_profile($prior,'greyscale-done'),PGAutomationETA::timing_profile($r->{items}[0],'greyscale-done'),'structured low-light policy compares by values, not memory addresses');
$prior->{checkpoints}=[map {{name=>$_,status=>'done',duration_seconds=>60}} @{PGAutomationETA::plan($prior)}];
my $similar=PGAutomationETA::samples({items=>[$prior]});
$r->{items}[0]{checkpoints}=[map {{name=>$_,status=>'done',duration_seconds=>60}} qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled)];
$next=job();$next->{picture_mode}='expert1';$next->{status}='queued';delete $next->{device_identity};push @{$r->{items}},$next;
$next->{low_light}=PGAutomation::clone($prior->{low_light});
PGAutomationETA::update($r,1300,$similar);
is($r->{time_estimate}{scope},'batch','same signal/meter/workload can reuse another picture mode timings');
ok($r->{time_estimate}{approximate_history},'broader timing match is labelled approximate');
is($r->{time_estimate}{job_remaining_seconds},1500,'current job includes remaining 1D pass and later stages');
is($r->{time_estimate}{batch_unknown_stages},0,'complete coverage produces whole-batch estimate');
is(scalar @{$r->{time_estimate}{jobs}},2,'remaining jobs each retain their timing coverage');
my $exposed=main::webui_automation_public_run($r)->{time_estimate};
is($exposed->{job_remaining_seconds},1500,'current-job estimate reaches status API');
ok(!exists($exposed->{jobs}),'bulk per-job timing internals are not exposed');
$r->{items}[1]{signal_format}='dv';
PGAutomationETA::update($r,1310,$similar);
ok($r->{time_estimate}{batch_unknown_stages}>0,'unknown signal does not inherit SDR algorithm timing');
ok($r->{time_estimate}{batch_known_seconds}>0,'known remaining work stays available even with unknown jobs');
is($r->{time_estimate}{job_unknown_stages},0,'current job can be complete coverage independently of batch');
$r->{items}[1]{signal_format}='sdr';$r->{items}[1]{calibration}{target_delta_e}=.2;
PGAutomationETA::update($r,1320,$similar);
ok($r->{time_estimate}{batch_unknown_stages}>0,'stricter calibration target is not borrowed from compatible history');
$r->{items}[1]{calibration}{target_delta_e}=.5;$r->{items}[1]{display_type}='other meter mode';
PGAutomationETA::update($r,1330,$similar);
ok($r->{time_estimate}{batch_unknown_stages}>0,'different meter mode is not treated as comparable');
$r=run();$next=job();$next->{status}='queued';$next->{picture_mode}='cinema';push @{$r->{items}},$next;
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{jobs}[1]{remaining_seconds},1560,'observed current pace seeds the same remaining workload in a later job');
is($r->{time_estimate}{jobs}[1]{known_stages},1,'live greyscale pace does not fabricate timings for later profile/upload stages');
ok($r->{time_estimate}{approximate_history},'live pace transferred between picture modes is labelled approximate');
$r=run();$r->{worker_timing}{recent_point_seconds}=[120,180,180,240,240];
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{stage_remaining_seconds},3780,'slower recent near-black points replace bright-point average');
$r->{worker_timing}{recent_point_seconds}=[10,20,30];
PGAutomationETA::update($r,1310,[]);
is($r->{time_estimate}{stage_remaining_seconds},1302,'a few fast points do not erase the overall measured pace');
done_testing();
