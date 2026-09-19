# Regression for PR 14 test report P24: a job planned by a limited preflight
# (a TV whose picture mode cannot be read) is not refused as stale merely
# because its readiness output changes once the job's mode is selected.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
use PGAutomationPlan ();
my $planned={name=>'C1 job',signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',settings=>{contrast=>100},
 tv_input=>'hdmi2',capability_profile=>{hash=>'c'x64},device_identity=>{model_name=>'OLED65C1'}};
my $planned_intent=PGAutomationPlan::intent_hash($planned);
my $limited={%{PGAutomationPlan::contract($planned)},limited=>JSON::PP::true};
my $full=PGAutomationPlan::contract($planned);
# Readiness in the now-selected mode adds a mode-dependent control.
my $merged={%{PGAutomation::clone($planned)},settings=>{contrast=>100,energySaving=>'off'}};
ok(!PGAutomationPlan::matches($merged,$limited),'the merged job no longer hashes to the limited contract (the P24 failure)');
ok(PGAutomationPlan::job_start_matches($planned_intent,$merged,$limited),'a limited contract accepts mode-dependent readiness output at job start');
ok(!PGAutomationPlan::job_start_matches($planned_intent,$merged,$full),'a full-preflight contract still requires the exact merged plan');
my $edited={%{PGAutomation::clone($planned)},picture_mode=>'hdrCinema'};
ok(!PGAutomationPlan::job_start_matches(PGAutomationPlan::intent_hash($edited),$merged,$limited),'a changed queue intent is still stale');
ok(!PGAutomationPlan::job_start_matches($planned_intent,{%$merged,tv_input=>'hdmi3'},$limited),'a changed input is still stale');
ok(!PGAutomationPlan::job_start_matches($planned_intent,{%$merged,capability_profile=>{hash=>'d'x64}},$limited),'a changed compatibility profile is still stale');
ok(!PGAutomationPlan::job_start_matches($planned_intent,{%$merged,device_identity=>{model_name=>'OLED65C2'}},$limited),'a different TV is still stale');
ok(PGAutomationPlan::job_start_matches($planned_intent,$planned,$full),'an unchanged full-preflight plan matches');

# Runner level: job start with a limited contract whose readiness adds a setting.
{
 require File::Temp;
 my $store=File::Temp::tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 {local @ARGV=('limited-run','limited-token');local $SIG{__WARN__}=sub {};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
 no warnings qw(once redefine);
 my $job={%{PGAutomation::clone($planned)},preflight_contract=>$limited};
 PGAutomation::write_json_atomic(PGAutomation::run_dir('limited-run').'/run.json',{id=>'limited-run',token=>'limited-token',status=>'running',items=>[$job]});
 local *main::_log=sub {};local *main::_log_action=sub {};
 local *main::_apply_signal=sub {1};local *main::_freeze_job_lg_context=sub {{}};local *main::_select_item_picture_mode=sub {1};
 my $ok=eval {main::_prepare_job_context(0,$job);1};
 ok($ok,'job preparation completes') or diag $@;
 unlike($@||'',qr/Queue preflight is stale/,'a limited job is not refused as stale at job start');
 my $stored=PGAutomation::read_json_file(PGAutomation::run_dir('limited-run').'/run.json')->{items}[0];
 is($stored->{preflight_contract}{intent_hash},PGAutomationPlan::intent_hash($stored),'job start pins the limited contract to the job it verified');
 ok(PGAutomationPlan::matches($stored,$stored->{preflight_contract}),'the stored job matches its contract, so a claim after Pause needs no re-check');
}


# Regression for PR 14 test report P13, found live on 18 September 2026: a start
# is meant to reuse a Check Readiness that passed moments ago, and it never did.
# The reuse compares the queue intent of the readiness run's items with the
# start run's, and the hash covered fields that differ between any two runs by
# construction: a freshly minted per-item id, plus the TV-derived fields a
# readiness pass adds and a static start cannot have.
my $queued={name=>'SDR Filmmaker',signal_format=>'sdr',picture_mode=>'filmMaker',settings=>{contrast=>85}};
my $from_readiness={%{PGAutomation::clone($queued)},id=>'20260918-013137-f8297b',
 apply_all_supported=>1,panel_protection_supported=>1,
 lg_generation=>{generation_id=>'lg2022plus_oled',device_id=>'64:e4:a5:33:b6:01',platform_year=>2023}};
my $from_start={%{PGAutomation::clone($queued)},id=>'20260918-013549-c44039'};
is(PGAutomationPlan::intent_hash($from_readiness),PGAutomationPlan::intent_hash($from_start),
 'the same queued job hashes alike whether a readiness pass or a static start prepared it');
is(PGAutomationPlan::intent_hash($from_start),PGAutomationPlan::intent_hash($queued),
 'and alike to the queue entry the operator saved');
# The guard still does its job: anything the operator chose still changes it.
for my $edit ([picture_mode=>'cinema'],[signal_format=>'hdr10'],[name=>'Renamed']) {
 my ($key,$value)=@$edit;
 isnt(PGAutomationPlan::intent_hash({%{PGAutomation::clone($from_start)},$key=>$value}),
  PGAutomationPlan::intent_hash($from_start),"an edited $key is still a different queue intent");
}
isnt(PGAutomationPlan::intent_hash({%{PGAutomation::clone($from_start)},settings=>{contrast=>90}}),
 PGAutomationPlan::intent_hash($from_start),'an edited pinned setting is still a different queue intent');
# A TV that changed is caught by identity, which is where it belongs.
my $planned_tv={%{PGAutomation::clone($queued)},tv_input=>'hdmi4',capability_profile=>{hash=>'d'x64},
 device_identity=>{model_name=>'OLED55G36LA'}};
my $tv_contract=PGAutomationPlan::contract($planned_tv);
ok(PGAutomationPlan::identity_matches($planned_tv,$tv_contract),'the planned TV still matches its contract');
ok(!PGAutomationPlan::identity_matches({%$planned_tv,capability_profile=>{hash=>'e'x64}},$tv_contract),
 'a changed compatibility profile is still refused');
ok(!PGAutomationPlan::identity_matches({%$planned_tv,tv_input=>'hdmi2'},$tv_contract),
 'and so is a different TV input');
done_testing();
