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
my @calls;my $healthy=1;my $supported=1;
my $state={items=>[{}, {}, {}],hazard_restore=>{autoPowerOff=>{value=>'original',category=>'power'}}};
local *main::_log=sub {};
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
 is($path,'/api/automation/readiness','job setup only calls the scoped readiness endpoint');
 push @calls,$payload->{scope};
 is(scalar @{$payload->{items}},1,'job checks cannot query later queue entries');
 return {ready=>0,message=>'Meter unavailable',checks=>[{ok=>0,level=>'error',message=>'Physical meter disconnected'}]} if !$healthy;
 return {ready=>0,message=>'Unsupported setting',checks=>[{ok=>0,level=>'error',message=>'contrast unsupported in this mode'}]} if $payload->{scope} eq 'job' && !$supported;
 return {ready=>1,checks=>[{ok=>0,level=>'warning',message=>'Manual control check',item_number=>0}],items=>[{name=>$payload->{items}[0]{name},settings=>{contrast=>85}}],hazard_restore=>{autoPowerOff=>{value=>'off',category=>'power'},screenSaver=>{value=>'original-saver',category=>'screenSaver'}}};
};
local *main::_stage=sub {
 my ($number,$item,$stage,$callback)=@_;
 return 1 if $stage eq 'item-started'; # simulate an existing completed checkpoint
 if($stage eq 'tv-setup-verified'){$callback->();return 0;} # no measurements in this fixture
 die "Unexpected stage $stage";
};
local *main::_apply_and_verify=sub {push @calls,'apply';ok($_[3],'settings application does not switch signal/mode again');1};
local *main::_sleep_controlled=sub {1};
for my $signal (qw(sdr hdr10 dv)) {
 @calls=();
 my $item={name=>'Job',signal_format=>$signal,picture_mode=>'mode-'.$signal,settings=>{},checkpoints=>[{name=>'item-started',status=>'done',verified=>1}],hazard_restore=>{autoPowerOff=>{value=>'preserved'}}};
 main::_run_item(2,$item);
 is_deeply(\@calls,['batch','signal:'.$signal,'freeze','mode:mode-'.$signal,'job','resume','apply'],'fresh health -> signal -> frozen context -> mode -> current-job controls -> resume -> apply');
 is($item->{checkpoints}[0]{name},'item-started','existing checkpoints preserved without skipping fresh readiness');
 is($item->{readiness}{checks}[0]{item_number},2,'job readiness uses global queue index in saved results');
 is($item->{hazard_restore}{autoPowerOff}{value},'preserved','item hazard restoration survives preparation');
}
is($state->{hazard_restore}{autoPowerOff}{value},'original','later job observations cannot replace original global hazard value');
is($state->{hazard_restore}{screenSaver}{value},'original-saver','newly discovered hazards are saved before settings application');
@calls=();$healthy=0;
my $missing={name=>'Missing meter',signal_format=>'sdr',picture_mode=>'filmMaker',checkpoints=>[{name=>'item-started',status=>'done'}]};
ok(!main::_run_item(2,$missing),'missing meter stops a resumed job');
is_deeply(\@calls,['batch'],'no signal changes, TV settings queries or writes when meter missing');
like($missing->{failure}{message},qr/Physical meter disconnected/,'job failure includes the actual readiness cause');
@calls=();$healthy=1;$supported=0;
my $bad={name=>'Unsupported control',signal_format=>'dv',picture_mode=>'dolbyVisionCinema'};
ok(!main::_run_item(2,$bad),'unsupported current-mode control stops this job');
is_deeply(\@calls,['batch','signal:dv','freeze','mode:dolbyVisionCinema','job'],'unsupported setting prevents application and baseline measurements');
like($bad->{failure}{message},qr/contrast unsupported/,'mode-specific error is retained on the job');
done_testing();
