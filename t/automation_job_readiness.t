use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
{
 local @ARGV=('job-readiness-test','fake-token');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
# Job start trusts the whole-queue check (18 Sep 2026: on the G3 every job
# start repeated the batch and job readiness passes the queue check had just
# run, about 3.5 min per job). It selects the job's signal and picture mode,
# freezes the live TV identity against the plan, carries the check's readiness
# record and the hazard values the check observed, then resumes or applies.
my @calls;
my $state={items=>[{}, {}, {}],hazard_restore=>{autoPowerOff=>{value=>'original',category=>'power'}}};
local *main::_log=sub {};
local *main::_log_action=sub {};
local *main::_update_item_snapshot=sub {1};
local *main::_update_run=sub {$_[0]->($state);$state};
local *main::_apply_signal=sub {push @calls,'signal:'.$_[0]{signal_format};1};
local *main::_select_item_picture_mode=sub {push @calls,'mode:'.$_[1]{picture_mode};1};
local *main::_prepare_resume=sub {push @calls,'resume';ok($_[2],'resume uses already-restored context')};
local *main::_pause_after_checkpoint=sub {0};
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 if($path eq '/api/lg/picture-settings') {
  push @calls,'freeze';
  ok($payload->{include_current_input},'initial context uses a live input probe');
  return {status=>'ok',current_input=>'hdmi1',generation_profile=>{capability_profile_hash=>'a'x64,capability_profile_id=>'test',capability_library_valid=>1,capability_platform_profile_applied=>1}};
 }
 fail("job start must not call $path: its readiness came from the whole-queue check");
 push @calls,$path;
 return {status=>'error'};
};
local *main::_stage=sub {
 my ($number,$item,$stage,$callback)=@_;
 return 1 if $stage eq 'item-started'; # simulate an existing completed checkpoint
 if($stage eq 'tv-setup-verified'){$callback->();return 0;} # no measurements in this fixture
 die "Unexpected stage $stage";
};
local *main::_apply_and_verify=sub {push @calls,'apply';ok($_[3],'settings application does not switch signal/mode again');1};
local *main::_sleep_controlled=sub {1};
my @hazards=(
 {key=>'autoPowerOff',value=>'off',category=>'power',controllable=>1},
 {key=>'screenSaver',value=>'original-saver',category=>'screenSaver',controllable=>1},
 {key=>'energySaving',value=>'auto',category=>'picture',controllable=>1},
 {key=>'noSignalPowerOff',value=>'on',category=>'power',controllable=>0},
);
for my $signal (qw(sdr hdr10 dv)) {
 @calls=();
 my $item={name=>'Job',signal_format=>$signal,picture_mode=>'mode-'.$signal,settings=>{},
  checkpoints=>[{name=>'item-started',status=>'done',verified=>1}],
  readiness=>{ready=>1,scope=>'queue-preflight',checks=>[{ok=>0,level=>'warning',message=>'Manual control check',item_number=>2}]},
  hazards=>PGAutomation::clone(\@hazards),hazard_restore=>{autoPowerOff=>{value=>'preserved'}}};
 main::_run_item(2,$item);
 is_deeply(\@calls,['signal:'.$signal,'freeze','mode:mode-'.$signal,'resume','apply'],'signal -> frozen context -> mode -> resume -> apply, with no readiness call');
 is($item->{checkpoints}[0]{name},'item-started','existing checkpoints preserved');
 is($item->{readiness}{scope},'queue-preflight','the whole-queue check is the job\'s readiness record');
 is($item->{readiness}{checks}[0]{item_number},2,'and it keeps the global queue index');
 is($item->{hazard_restore}{autoPowerOff}{value},'preserved','item hazard restoration survives preparation');
}
is($state->{hazard_restore}{autoPowerOff}{value},'original','later job observations cannot replace original global hazard value');
is($state->{hazard_restore}{screenSaver}{value},'original-saver','hazards the check observed are journalled before settings application');
is($state->{hazard_restore}{screenSaver}{category},'screenSaver','with their category');
ok(!exists($state->{hazard_restore}{energySaving}),'a picture-side hazard the recipe itself sets is not a restoration value');
ok(!exists($state->{hazard_restore}{noSignalPowerOff}),'nor is a control the TV cannot set');
ok($state->{hazard_restore_pending},'the run owes their restoration');

# The identity read before the mode write is where a changed TV is caught.
@calls=();
my $moved={name=>'Moved',signal_format=>'sdr',picture_mode=>'filmMaker',settings=>{},
 preflight_contract=>{tv_input=>'hdmi2',profile_hash=>'a'x64,intent_hash=>'x'}};
ok(!main::_run_item(2,$moved),'a TV on a different input than the check saw stops the job');
is_deeply(\@calls,['signal:sdr','freeze'],'before any mode write, resume or settings');
like($moved->{failure}{message},qr/Queue preflight is stale/,'and the failure names the stale plan');
is($moved->{failure}{stage},'job-readiness','at job readiness');
done_testing();
