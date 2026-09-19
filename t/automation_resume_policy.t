#!/usr/bin/perl
# Resume after a failure in the profile stage keeps a verified 1D result.
# The 18 Sep 2026 batch repeated a 95-minute greyscale after a restore write
# timed out in the 3D LUT stage; the settings-recovery resume already knew
# how to keep the 1D result and restore the unity 3D baseline instead.
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();

local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('resume-test','test-token'); local $SIG{__WARN__}=sub {}; do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
my @actions;
local *main::_log=sub {};
local *main::_log_action=sub { push(@actions,$_[0]); };
local *main::_heartbeat=sub {};
local *main::_refresh_control=sub {};
local *main::_apply_signal=sub { 1 };

my @order=qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified);
sub item {
 my (%extra)=@_;
 my $signal=delete($extra{signal_format}) || 'hdr10';
 return {name=>'Job',signal_format=>$signal,picture_mode=>'hdrCinema',settings=>{},
  checkpoints=>[map { {name=>$_,status=>'done',at=>1} } @order],%extra};
}
sub names { [map { $_->{name} } @{$_[0]{checkpoints}}] }
sub grey_state {
 my ($number,$state)=@_;
 my $dir=PGAutomation::item_dir('resume-test',$number).'/calibration';
 make_path($dir);
 if(!defined($state)) { unlink("$dir/grey-state.json"); return; }
 open(my $fh,'>',"$dir/grey-state.json") or die $!;
 print {$fh} JSON::PP->new->encode($state);
 close($fh);
}

# A verified 1D result survives a profile-stage failure.
{
 grey_state(0,{status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 my $item=item(failure=>{stage=>'volume-done',message=>'Processing settings check: failed to restore smoothGradation',at=>2});
 @actions=();
 main::_prepare_resume(0,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],
  'volume-done failure keeps the reset, panel light and greyscale checkpoints');
 is($item->{profile_baseline_needs_restore},1,'the unity 3D baseline is restored before profiling');
 like(join("\n",@actions),qr/failure in Color calibration: retaining the verified 1D result/,'the resume names the stage and says the 1D result is kept');
}

# A session that failed to close after a verified profile keeps the profile.
{
 my $number=6;
 grey_state($number,{status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 my $dir=PGAutomation::item_dir('resume-test',$number).'/calibration';
 for my $name (qw(profile.cube profile.bin)) { open(my $fh,'>',"$dir/$name") or die $!; print {$fh} 'x'; close($fh); }
 open(my $fh,'>',"$dir/3d-state.json") or die $!;
 print {$fh} JSON::PP->new->encode({status=>'complete',upload_verified=>JSON::PP::true,
  export=>{cube_path=>'/var/lib/PGenerator/lg/luts/profile.cube',payload_path=>'/var/lib/PGenerator/lg/luts/profile.bin'}});
 close($fh);
 my $item=item(failure=>{stage=>'session-closed',message=>'x',at=>2});
 push(@{$item->{checkpoints}},{name=>'volume-done',status=>'done',at=>3},{name=>'volume-settings-verified',status=>'done',at=>3});
 @actions=();
 main::_prepare_resume($number,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified)],
  'session-closed failure with a verified profile keeps the profile checkpoints');
 ok(!$item->{profile_baseline_needs_restore},'no baseline restore when the profile is kept');
 like(join("\n",@actions),qr/failure in Calibration-mode exit: retaining the verified 1D and profile results/,'the resume says both results are kept');
}

# Without the saved 1D curve the baseline cannot be restored, so the old full
# reset applies rather than a resume that would fail at job readiness.
{
 grey_state(7,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2});
 @actions=();
 main::_prepare_resume(7,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'a verified 1D result without its curve resets from the calibration start');
 ok(!$item->{profile_baseline_needs_restore},'and arms no baseline restore');
 like(join("\n",@actions),qr/saved 1D curve is missing/,'the resume says why');
}

# A session-close failure on a Dolby Vision job keeps the 1D result too, and
# has no 3D baseline to restore.
{
 grey_state(1,{status=>'complete',final_1d_lut_upload_verified=>JSON::PP::true});
 my $item=item(signal_format=>'dv',failure=>{stage=>'session-closed',message=>'x',at=>2});
 push(@{$item->{checkpoints}},{name=>'volume-done',status=>'done',at=>3},{name=>'volume-settings-verified',status=>'done',at=>3});
 main::_prepare_resume(1,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],
  'session-closed failure drops the profile checkpoints and keeps the greyscale');
 ok(!$item->{profile_baseline_needs_restore},'a Dolby Vision job sets no 3D baseline restore');
}

# Without the committed 1D file the old full reset still applies.
{
 grey_state(2,undef);
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2});
 main::_prepare_resume(2,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'missing 1D artifacts reset from the calibration start');
 ok(!$item->{profile_baseline_needs_restore},'no baseline restore without a 1D result');
}

# An unverified 1D upload is not a result to keep.
{
 grey_state(3,{status=>'complete'});
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2});
 main::_prepare_resume(3,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'an unverified 1D upload resets from the calibration start');
}

# Failures before the greyscale finished still reset everything.
{
 grey_state(4,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(failure=>{stage=>'greyscale-done',message=>'x',at=>2});
 $item->{checkpoints}=[grep { $_->{name} !~ /^greyscale/ } @{$item->{checkpoints}}];
 main::_prepare_resume(4,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'a greyscale failure resets from the calibration start');
}

# A pending drift recovery keeps the full reset regardless of the stage.
{
 grey_state(5,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2},drift_recovery_pending=>1);
 main::_prepare_resume(5,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'drift recovery resets from the calibration start');
}

# A flag left by an earlier attempt is not carried into a full reset.
{
 grey_state(8,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2},profile_baseline_needs_restore=>1);
 main::_prepare_resume(8,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'the reset applies');
 ok(!$item->{profile_baseline_needs_restore},'and the stale baseline flag is cleared');
}

# A pause after the greyscale on a result without its curve resets rather
# than arming a restore that would fail at job readiness.
{
 grey_state(9,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item();
 main::_prepare_resume(9,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'a greyscale pause without the curve resets from the calibration start');
 ok(!$item->{profile_baseline_needs_restore},'no baseline restore without the curve');
 grey_state(10,{status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 my $kept=item();
 main::_prepare_resume(10,$kept,1);
 is_deeply(names($kept),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],'with the curve the greyscale is kept and rechecked');
 is($kept->{profile_baseline_needs_restore},1,'and the baseline restore is armed');
}

# A saved settings-recovery plan needs the curve too.
{
 grey_state(11,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(settings_recovery=>{resume_from=>'volume-done',point=>'c7'});
 @actions=();
 main::_prepare_resume(11,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'a recovery plan without the curve resets from the calibration start');
 ok(!$item->{profile_baseline_needs_restore},'and arms no restore');
 like(join("\n",@actions),qr/saved 1D curve is missing/,'and the operator is told why');
 grey_state(12,{status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 my $kept=item(settings_recovery=>{resume_from=>'volume-done',point=>'c7'});
 main::_prepare_resume(12,$kept,1);
 is_deeply(names($kept),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],'with the curve the plan resumes at the profile stage');
 is($kept->{profile_baseline_needs_restore},1,'and arms the restore');
}

# A Dolby Vision profile failure keeps the 1D result unless an upload was
# dispatched without an accepted result.
{
 grey_state(13,{status=>'complete',final_1d_lut_upload_verified=>JSON::PP::true});
 my $dir=PGAutomation::item_dir('resume-test',13).'/calibration';
 my $item=item(signal_format=>'dv',failure=>{stage=>'volume-done',message=>'x',at=>2});
 @actions=();
 main::_prepare_resume(13,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],'a DV profile failure before any upload keeps the greyscale');
 ok(!$item->{profile_baseline_needs_restore},'with no 3D baseline to restore');
 open(my $fh,'>',"$dir/dv-profile-upload-dispatched.json") or die $!; print {$fh} '{"dispatched_at":1}'; close($fh);
 my $dispatched=item(signal_format=>'dv',failure=>{stage=>'volume-done',message=>'x',at=>2});
 @actions=();
 main::_prepare_resume(13,$dispatched,1);
 is_deeply(names($dispatched),[qw(item-started tv-setup-verified)],'a dispatched upload without an accepted result restarts from the reset');
 like(join("\n",@actions),qr/upload was dispatched without an accepted result/,'and says why');
 open($fh,'>',"$dir/dv-profile-upload.json") or die $!; print {$fh} '{"status":"ok"}'; close($fh);
 my $accepted=item(signal_format=>'dv',failure=>{stage=>'volume-done',message=>'x',at=>2});
 main::_prepare_resume(13,$accepted,1);
 is_deeply(names($accepted),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],'an accepted result written after the dispatch keeps the greyscale');
}

# A Dolby Vision session-close failure with a verified profile keeps it.
{
 grey_state(14,{status=>'complete',final_1d_lut_upload_verified=>JSON::PP::true});
 my $dir=PGAutomation::item_dir('resume-test',14).'/calibration';
 for my $pair (['dv-profile-state.json','{"status":"complete"}'],['dv-profile-upload.json','{"status":"ok"}']) {
  open(my $fh,'>',"$dir/$pair->[0]") or die $!; print {$fh} $pair->[1]; close($fh);
 }
 my $item=item(signal_format=>'dv',failure=>{stage=>'session-closed',message=>'x',at=>2});
 push(@{$item->{checkpoints}},{name=>'volume-done',status=>'done',at=>3},{name=>'volume-settings-verified',status=>'done',at=>3});
 main::_prepare_resume(14,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified)],'the verified Dolby Vision profile is kept');
}

# The pre-read of a resume-time pass carries the same ownership.
{
 my $owned={signal_format=>'hdr10',settings=>{colorGamut=>'auto'},
  checkpoints=>[map { {name=>$_,status=>'done',verified=>1} } qw(reset-and-reapply-verified greyscale-done volume-done)]};
 is(main::_calibration_manages_setting($owned,'colorGamut','resume-setup-pre'),1,'the resume-setup pre-read sees the kept LUT as the owner');
 my $one_d={signal_format=>'hdr10',settings=>{colorGamut=>'auto'},
  checkpoints=>[map { {name=>$_,status=>'done',verified=>1} } qw(reset-and-reapply-verified greyscale-done)]};
 is(main::_expected_calibration_gamut_state($one_d,'colorGamut','resume-profile-baseline-pre'),1,'the baseline pre-read expects the post-1D transition');
}

# A baseline restore that failed on the previous resume is not armed again.
{
 grey_state(15,{status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 my $item=item(failure=>{stage=>'job-readiness',message=>'Cannot restore profile baseline',at=>2},profile_baseline_restore_failed=>1);
 $item->{checkpoints}=[grep { $_->{name} ne 'greyscale-settings-verified' } @{$item->{checkpoints}}];
 @actions=();
 main::_prepare_resume(15,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'a failed baseline restore sends the next resume to the reset');
 ok(!$item->{profile_baseline_needs_restore} && !$item->{profile_baseline_restore_failed},'and clears both markers');
 like(join("\n",@actions),qr/could not be restored on the previous resume/,'and says why');
}

# The resume-time settings passes respect LUT ownership like the post-1D
# checkpoints, so a restored or kept LUT keeps its gamut and gamma.
{
 my $owned={signal_format=>'hdr10',settings=>{colorGamut=>'auto',gamma=>'2.2'},
  checkpoints=>[map { {name=>$_,status=>'done',verified=>1} } qw(reset-and-reapply-verified greyscale-done volume-done)]};
 is(main::_calibration_manages_setting($owned,'colorGamut','resume-setup'),main::_calibration_manages_setting($owned,'colorGamut','c7'),'resume-setup treats the gamut like c7 after a verified profile');
 is(main::_calibration_manages_setting($owned,'colorGamut','c7'),1,'which a verified profile owns');
 my $one_d={signal_format=>'hdr10',settings=>{colorGamut=>'auto'},
  checkpoints=>[map { {name=>$_,status=>'done',verified=>1} } qw(reset-and-reapply-verified greyscale-done)]};
 is(main::_expected_calibration_gamut_state($one_d,'colorGamut','resume-profile-baseline'),main::_expected_calibration_gamut_state($one_d,'colorGamut','c6'),'resume-profile-baseline treats the gamut like c6 after a verified 1D result');
 is(main::_expected_calibration_gamut_state($one_d,'colorGamut','c6'),1,'where Auto may read as Wide');
 my $sdr={signal_format=>'sdr',settings=>{gamma=>'2.2'},
  checkpoints=>[map { {name=>$_,status=>'done',verified=>1} } qw(reset-and-reapply-verified greyscale-done)]};
 is(main::_calibration_manages_setting($sdr,'gamma','resume-setup'),main::_calibration_manages_setting($sdr,'gamma','c6'),'resume-setup treats SDR gamma like c6 after a verified 1D result');
 my $fresh={signal_format=>'hdr10',settings=>{colorGamut=>'auto'},checkpoints=>[{name=>'tv-setup-verified',status=>'done'}]};
 is(main::_calibration_manages_setting($fresh,'colorGamut','resume-setup'),0,'with no LUT the gamut is written as usual');
 is(main::_expected_calibration_gamut_state($fresh,'colorGamut','resume-setup'),0,'and no waiver applies');
}

# The profile stage starts with no record of an earlier attempt's upload.
{
 my $dir=PGAutomation::item_dir('resume-test',16).'/calibration';
 make_path($dir);
 for my $name (qw(dv-profile-upload-dispatched.json dv-profile-upload.json)) { open(my $fh,'>',"$dir/$name") or die $!; print {$fh} '{"status":"ok"}'; close($fh); }
 my $seen;
 no warnings 'redefine';
 local *main::_set_dv_map=sub { $seen=[grep { -e "$dir/$_" } qw(dv-profile-upload-dispatched.json dv-profile-upload.json)]; return 0; };
 my $item=item(signal_format=>'dv');
 is(main::_calibration_volume_stage(16,$item),0,'the stage stops at the stubbed map step');
 is_deeply($seen,[],'both records were removed before anything else ran');
}

# A restore cut short by a stop request is not a refusal; two refusals latch.
{
 no warnings 'redefine';
 local *main::_prepare_job_context=sub {1};
 local *main::_prepare_resume=sub {};
 local *main::_update_item_snapshot=sub {};
 local *main::_update_run=sub { my ($cb)=@_; my $run={items=>[]}; $cb->($run); return $run; };
 local *main::_run=sub {{}};
 my $error='TV refused the unity reset';
 local *main::_restore_profile_baseline=sub { $::LAST_ERROR_CODE=''; die "$error\n" };
 my $item=item(profile_baseline_needs_restore=>1);
 is(main::_run_item(0,$item),0,'a failed restore fails job preparation');
 is($item->{profile_baseline_restore_failures},1,'the first refusal is counted');
 ok(!$item->{profile_baseline_restore_failed},'but not yet latched');
 $item->{profile_baseline_needs_restore}=1; $item->{status}='queued';
 main::_run_item(0,$item);
 is($item->{profile_baseline_restore_failed},1,'the second refusal latches');
 my $stopped=item(profile_baseline_needs_restore=>1);
 local *main::_restore_profile_baseline=sub { $::LAST_ERROR_CODE='stopped'; die "Automation stop requested\n" };
 main::_run_item(0,$stopped);
 ok(!$stopped->{profile_baseline_restore_failures} && !$stopped->{profile_baseline_restore_failed},'a stop during the restore counts for nothing');
}

done_testing();
