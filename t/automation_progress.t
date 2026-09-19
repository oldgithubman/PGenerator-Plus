use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use Test::More;
use PGAutomation ();
use PGAutomationETA ();
require "$Bin/../usr/share/PGenerator/webui.pm";

my $item={status=>'queued',stages=>{calibration=>0,pre_readings=>1,post_readings=>0}};
my $r={status=>'running',active_stage=>'queue-preflight',stage_started_at=>1000,items=>[PGAutomation::clone($item),PGAutomation::clone($item)],
 preflight_result=>{started_at=>1000,progress_done=>3,progress_total=>9}};
my $p=PGAutomationETA::progress($r);
is($p->{stage_completed},3,'initial checks report completed operations before any job finishes');
is($p->{stage_total},9,'initial checks include equipment, context, both jobs and restoration');
cmp_ok($p->{completed},'>',0,'whole queue begins advancing during preflight');
is($p->{total},7,'whole queue includes preflight plus three stages for each readings-only job');
PGAutomationETA::update($r,1120,[]);
is($r->{time_estimate}{stage_remaining_seconds},240,'completed check operations seed an initial-check estimate');
ok($r->{time_estimate}{batch_unknown_stages}>0,'unmeasured calibration/reading time remains explicitly unknown');
ok(main::webui_automation_public_run($r)->{time_estimate},'preflight estimate is public before an active job exists');
$r->{preflight_result}{progress_done}=4;
PGAutomationETA::update($r,1121,[]);
is($r->{time_estimate}{calculated_at},1121,'check completion refreshes the estimate immediately');
$r->{preflight_only}=1;
delete $r->{time_estimate};PGAutomationETA::update($r,1122,[]);
is($r->{time_estimate}{batch_unknown_stages},0,'readiness-only estimate excludes calibration that will not run');
delete $r->{preflight_only};
$r->{preflight_result}{ready}=1;$r->{active_item}=0;$r->{active_stage}='tv-setup-verified';
$r->{items}[0]{checkpoints}=[{name=>'item-started',status=>'done'}];
$r->{operation_progress}={stage=>'tv-setup-verified',completed=>3,total=>19,unit=>'settings and verification',message=>'Applying contrast',secret=>'hidden'};
$p=main::webui_automation_public_run($r);
is($p->{progress}{stage_completed},3,'TV settings advance within the first job');
cmp_ok($p->{progress}{completed},'>',2,'whole queue includes preflight, readiness and partial TV setup');
ok(!exists($p->{operation_progress}{secret}),'operation API exposes only defined presentation fields');
$r->{active_stage}='pre-readings-done';
$r->{worker_status}={current_step=>11,total_steps=>21,status=>'running'};
$p=main::webui_automation_public_run($r);
is($p->{progress}{stage_completed},10,'current in-flight patch is not reported as measured');
is($p->{progress}{unit},'patches','measurement units replace TV-setting units');
ok(!exists($p->{operation_progress}),'TV-setting details cannot leak into a later stage');
$r->{worker_status}{current_step}=21;$r->{worker_status}{status}='complete';
$p=PGAutomationETA::progress($r);
is($p->{stage_completed},21,'completed measurement pass reaches its final patch');
cmp_ok($p->{completed},'<',$p->{total},'a finished pass does not claim the whole batch is complete');
$r->{status}='complete';
$p=PGAutomationETA::progress($r);
is($p->{completed},$p->{total},'only completed batch reaches whole-queue completion');

$r={status=>'running',active_item=>0,active_stage=>'volume-done',stage_started_at=>1000,
 items=>[{status=>'running',stages=>{calibration=>1,apply_all=>0}}],
 worker_status=>{status=>'running',current_step=>11,total_steps=>101},
 worker_timing=>{kind=>'3d',stage=>'volume-done',started_at=>1000,start_step=>0}};
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{pass_remaining_seconds},2730,'3D profiling uses measured patch pace');
cmp_ok($r->{time_estimate}{batch_known_seconds},'>=',2730,'whole-batch known work includes the active long profile pass');
ok($r->{time_estimate}{batch_unknown_stages}>0,'profile pass estimate does not invent solve/upload timings');
is(main::webui_automation_public_run($r)->{time_estimate}{pass_remaining_seconds},2730,'profile timing reaches the live API');
done_testing();
