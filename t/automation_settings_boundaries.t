use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use JSON::PP ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('boundary-test','test-token'); do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@;}
my (@reads,@writes,@checks,@logs,$mode,$accepted,$state);
local *main::_log=sub {push @logs,$_[0]};
local *main::_sleep_controlled=sub {1};
local *main::_append_setting_check=sub {push @checks,$_[2];1};
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 return $mode if $path eq '/api/lg/status';
 if($path eq '/api/lg/picture-settings/set') {
  push @writes,$payload;
  return $accepted ? {status=>'ok'} : {status=>'error',message=>'TV rejected control'};
 }
 die "Unexpected $path" unless $path eq '/api/lg/picture-settings';
 die 'Unexpected extra read' unless @reads;
 return shift @reads;
};
sub response {
 my ($values,$extra)=@_;
 return {status=>'ok',picture_settings=>{pictureMode=>'dolbyVisionCinemaBright',smoothGradation=>'off',brightness=>50,%{$values||{}}},%{$extra||{}}};
}
sub evidence {
 return {verified=>1,calibration_mode=>1,values=>{
  pictureMode=>{matched=>1,expected=>'dolbyVisionCinemaBright'},
  smoothGradation=>{matched=>1,expected=>'off'},brightness=>{matched=>1,expected=>50}}};
}
sub item {
 return {signal_format=>'dv',picture_mode=>'dolbyVisionCinemaBright',settings=>{smoothGradation=>'off',brightness=>50},stages=>{calibration=>1},checkpoints=>[
  {name=>'greyscale-done',status=>'done',verified=>1,evidence=>{verified=>1}},
  {name=>'greyscale-settings-verified',status=>'done',verified=>1,evidence=>evidence()},
  {name=>'volume-done',status=>'done',verified=>1,evidence=>{verified=>1}},
 ]};
}
sub reset_fixture {
 @reads=();@writes=();@checks=();@logs=();$accepted=1;$mode={status=>'ok',calibration_mode=>0};
 $::LAST_ERROR='';$::LAST_ERROR_CODE='';
}
reset_fixture();@reads=(response());
ok(main::_calibration_settings_boundary(0,item(),'c6'),'healthy boundary succeeds');
is(scalar @writes,0,'healthy check never writes');
is(scalar @reads,0,'healthy check needs only one read');

reset_fixture();@reads=(response({smoothGradation=>'low'}),response());
ok(main::_calibration_settings_boundary(0,item(),'c6'),'transient mismatch clears on confirmation');
is(scalar @writes,0,'transient mismatch does not trigger repair or recalibration');

reset_fixture();@reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'low'}),response(),response());
my $i=item();my $r=main::_calibration_settings_boundary(0,$i,'c8',evidence());
is($r->{recovery},'exit-only-restored','fresh pre-exit proof permits targeted processing repair');
is_deeply([map {$_->{settings}} @writes],[{smoothGradation=>'off'}],'only the mismatched setting is written');
ok(!$writes[0]{keep_calibration_mode},'exit repair cannot reopen calibration mode');
ok(!exists($i->{settings_recovery}),'proven exit-only repair does not request recalibration');
like(join('\n',@logs),qr/calibration results retained/,'retained result has an explicit explanation');

for my $point (qw(c6 c7 c8)) {
 reset_fixture();$mode->{calibration_mode}=1 if $point ne 'c8';
 @reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'low'}),response(),response());
 $i=item();
 ok(!main::_calibration_settings_boundary(0,$i,$point),'unproven change pauses instead of restarting automatically');
 is($i->{settings_recovery}{resume_from},$point eq 'c6'?'greyscale-done':'volume-done',"$point identifies the affected stage");
 is(scalar @writes,1,'one targeted repair only');
 is($writes[0]{keep_calibration_mode}?1:0,$point eq 'c8'?0:1,'repair preserves the existing calibration context');
 like($::LAST_ERROR,qr/no automatic recalibration.*Resume will/i,'pause explains the action of Resume');
}

reset_fixture();@reads=(response({brightness=>55}),response({brightness=>55}),response(),response());
$i=item();ok(!main::_calibration_settings_boundary(0,$i,'c8',evidence()),'luminance-affecting change cannot use processing-only exception');
is($i->{settings_recovery}{resume_from},'greyscale-done','uncertain luminance change requires review of the 1D stage too');

for my $case (qw(gamut-only failed-read unsupported other-drift missing-mode missing-key)) {
 reset_fixture();$i=item();
 my $grey=$i->{checkpoints}[1]{evidence};
 $grey->{verified}='unverifiable';
 $grey->{values}{colorGamut}={expected=>'auto',observed=>'wide',matched=>0,readback_warning=>1};
 $grey->{values}{colorGamut}{read_failed}=1 if $case eq 'failed-read';
 $grey->{values}{colorGamut}{unverifiable}=1 if $case eq 'unsupported';
 $grey->{values}{brightness}{matched}=0 if $case eq 'other-drift';
 delete $grey->{values}{pictureMode} if $case eq 'missing-mode';
 delete $grey->{values}{smoothGradation} if $case eq 'missing-key';
 @reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'low'}),response(),response());
 ok(!main::_calibration_settings_boundary(0,$i,'c7'),"$case still pauses for the unproven processing change");
 is($i->{settings_recovery}{resume_from},$case eq 'gamut-only'?'volume-done':'greyscale-done',"$case retains 1D only when its affected setting was verified and the sole exception was gamut");
}

for my $case (qw(read-error missing-mode flapping write-failure repair-drift missing-upload)) {
 reset_fixture();$i=item();
 if($case eq 'read-error') {
  @reads=(response({}, {status=>'error',message=>'TV socket timeout'}),response({}, {status=>'error',message=>'TV socket timeout'}));
 } elsif($case eq 'missing-mode') {
  $mode={status=>'ok'};@reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'low'}));
 } elsif($case eq 'flapping') {
  @reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'high'}));
 } elsif($case eq 'write-failure') {
  $accepted=0;@reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'low'}));
 } elsif($case eq 'repair-drift') {
  @reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'low'}),response(),response({smoothGradation=>'low'}));
 } else {
  $i->{checkpoints}=[grep {$_->{name} ne 'volume-done'} @{$i->{checkpoints}}];
  @reads=(response({smoothGradation=>'low'}),response({smoothGradation=>'low'}),response(),response());
 }
 ok(!main::_calibration_settings_boundary(0,$i,'c8',evidence()),"$case pauses without claiming success");
 is(scalar @writes,0,"$case performs no blind repair") if $case =~ /^(read-error|missing-mode|flapping)$/;
 like($::LAST_ERROR,qr/TV socket timeout/,'failed read retains the transport cause') if $case eq 'read-error';
}

reset_fixture();@reads=map {response({}, {unsupported_picture_keys=>{smoothGradation=>1}})} 1..2;
ok(!main::_calibration_settings_boundary(0,item(),'c6'),'unsupported controls without matrix permission pause the run');
is(scalar @writes,0,'no writes for unsupported readback');

# DV profile upload closes calibration internally. Only fresh post-measurement
# / pre-upload proof allows processing restoration without remeasuring.
for my $case (qw(fresh no-proof unverified-proof wrong-transition wrong-signal critical-drift unverified-upload)) {
 reset_fixture();$i=item();
 my $proof={%{evidence()},transition=>'dv-profile-upload',calibration_mode=>0};
 $proof=undef if $case eq 'no-proof';
 $proof->{verified}='unverifiable' if $case eq 'unverified-proof';
 $proof->{transition}='other' if $case eq 'wrong-transition';
 $i->{signal_format}='sdr' if $case eq 'wrong-signal';
 $i->{checkpoints}[-1]{evidence}{verified}=0 if $case eq 'unverified-upload';
 my $drift=$case eq 'critical-drift'?{brightness=>55}:{smoothGradation=>'low'};
 @reads=(response($drift),response($drift),response(),response());
 my $result=main::_calibration_settings_boundary(0,$i,'c7',$proof);
 if($case eq 'fresh') {
  is($result->{recovery},'upload-only-restored','fresh proof retains measurements after an upload-only processing change');
  ok(!exists($i->{settings_recovery}),'upload-only restoration never asks for calibration repeat');
  is_deeply($writes[0]{settings},{smoothGradation=>'off'},'restores only the changed processing control');
  like(join('\n',@logs),qr/settings matched after measurement and immediately before upload/,'log explains why measurements are retained');
 } else {
  ok(!$result,"$case cannot use the DV upload exception");
 }
}

# Exercise the production measurement -> readback -> mode query -> upload path.
{
 my (@upload,@artifacts);
 my $api=\&main::_api;
 local *main::_api=sub {
  if($_[1] eq '/api/lg/dv-profile/upload') {push @upload,$_[2];return {status=>'ok',dv_profile_uploaded=>JSON::PP::true,calibration_mode=>JSON::PP::false};}
  return $api->(@_);
 };
 local *main::_set_dv_map=sub {1};
 local *main::_start_worker=sub {{status=>'started'}};
 local *main::_wait_worker=sub {{status=>'complete',measurements=>{white_luminance=>1000,black_luminance=>0,red_x=>0.68,red_y=>0.32,green_x=>0.26,green_y=>0.69,blue_x=>0.15,blue_y=>0.06}}};
 local *main::_copy_worker_files=sub {1};
 local *main::_write_artifact=sub {push @artifacts,[@_];1};
 for my $active (0,1) {
  reset_fixture();@upload=();@artifacts=();$mode->{calibration_mode}=$active;@reads=(response());
  my $result=main::_calibration_volume_stage(0,item());
  ok($result->{verified},'profile upload completed');
  is($upload[0]{calibration_mode_active}?1:0,$active,'upload receives observed calibration state, not hard-coded true');
  ok(!$upload[0]{keep_calibration_mode},'DV upload explicitly closes calibration');
  is($result->{settings_before_upload}{transition},'dv-profile-upload','fresh transition proof returned for immediate boundary check');
  ok($result->{settings_before_upload}{values}{smoothGradation}{matched},'proof contains actual pre-upload control readback');
  is(scalar @artifacts,2,'dispatch marker and accepted upload artifact saved');
  like($artifacts[0][0],qr{/calibration/dv-profile-upload-dispatched\.json$},'the dispatch marker is written before the upload');
  like($artifacts[1][0],qr{/calibration/dv-profile-upload\.json$},'the accepted upload artifact after it');
 }
 for my $case (qw(drift read-error missing-mode)) {
  reset_fixture();@upload=();
  @reads=($case eq 'drift'?response({smoothGradation=>'low'}):$case eq 'read-error'?response({}, {status=>'error',message=>'Socket failed'}):response());
  $mode={status=>'ok'} if $case eq 'missing-mode';
  $i=item();ok(!main::_calibration_volume_stage(0,$i),"$case stops before upload");
  is(scalar @upload,0,"$case cannot upload under unconfirmed state");
  is($i->{settings_recovery}{resume_from},'volume-done','pre-upload issue retains 1D but repeats affected profile');
  is($::LAST_ERROR_CODE,$case eq 'drift'?'settings-review-required':'settings-readback-unavailable','reported cause distinguishes real drift from missing readback');
 }
}

# Exercise the real resume invalidation plan with saved artifact verification.
{
 local *main::_resume_calibration_artifacts_ok=sub {1};
 local *main::_apply_signal=sub {1};
 for my $from (qw(greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed)) {
  $i=item();
  $i->{checkpoints}=[map {{name=>$_,status=>'done',verified=>1}} qw(pre-readings-done reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed)];
  $i->{settings_recovery}={resume_from=>$from};
  main::_prepare_resume(0,$i,1);
  ok(main::_checkpoint_exists($i,'pre-readings-done'),"$from retains existing baseline");
  is(main::_checkpoint_exists($i,'greyscale-done'),$from eq 'greyscale-done'?0:1,"$from retains only reusable 1D calibration");
  is(main::_checkpoint_exists($i,'volume-done'),$from =~ /^(volume-settings-verified|session-closed)$/?1:0,"$from retains only reusable volume calibration");
  ok(!main::_checkpoint_exists($i,'session-closed'),'exit will be checked again');
  ok(!exists($i->{settings_recovery}),'acknowledged plan is consumed');
 }
}
{
 local *main::_resume_calibration_artifacts_ok=sub {0};
 $i=item();$i->{settings_recovery}={resume_from=>'volume-done'};
 main::_prepare_resume(0,$i,1);
 ok(!main::_checkpoint_exists($i,'greyscale-done'),'missing 1D artifact prevents unsafe stage reuse');
}

# Run the production stage orchestration with hardware workers replaced.
{
 local *main::_resume_calibration_artifacts_ok=sub {1};
 # The saved 1D curve is present whenever the real worker's state file is.
 local *main::_profile_baseline_data_ok=sub {1};
 for my $name (qw(greyscale-done greyscale-settings-verified)) {
  my $item={signal_format=>'hdr10',checkpoints=>[{name=>$name,status=>'done',verified=>1}],failure=>{stage=>'job-readiness'}};
  main::_prepare_resume(0,$item,1);
  ok($item->{profile_baseline_needs_restore},"$name resumes with a fresh profile baseline even after preparation failure");
  ok(main::_checkpoint_exists($item,'greyscale-done')||$name eq 'greyscale-settings-verified','valid saved 1D is retained');
 }
}
{
 my @actions;
 local *main::_ensure_calibration_mode_off=sub {push @actions,'exit';1};
 local *main::_apply_and_verify=sub {push @actions,'settings';is($_[4],1,'baseline settings preserve the restored held session');1};
 local *main::_write_artifact=sub {push @actions,'saved';1};
 for my $signal (qw(hdr10 sdr)) {
  my $item={signal_format=>$signal,picture_mode=>$signal eq 'hdr10'?'hdrCinema':'filmMaker',profile_baseline_needs_restore=>1};
  my $key=$signal eq 'hdr10'?'hdr20_1d_dpg_data':'sdr_1d_dpg_data';
  my $data=[map {$_%1024} 0..3071];
  PGAutomation::write_json_atomic(PGAutomation::item_dir('boundary-test',0).'/calibration/grey-state.json',{status=>'complete',final_1d_lut_upload_verified=>1,$key=>$data});
  local *main::_api=sub {
   my ($method,$path,$body)=@_;
   if($path eq '/api/lg/status'){push @actions,'mode';return {status=>'ok',calibration_mode=>1};}
   if($path eq '/api/lg/3d-lut/reset') {
    push @actions,'unity';ok($body->{keep_calibration_mode}&&!$body->{calibration_mode_active},'unity restore opens and holds its session');
    return {status=>'ok',upload_verified=>1};
   }
   if($path eq '/api/lg/1d-dpg/upload') {
    push @actions,'1d';is_deeply($body->{dpg_data},$data,'profile retry restores the exact saved greyscale curve');
    ok($body->{keep_calibration_mode}&&$body->{calibration_mode_active},'saved curve is staged into that same held session');
    return {status=>'ok',dpg_uploaded=>1};
   }
   die "Unexpected $path";
  };
  @actions=();ok(main::_restore_profile_baseline(0,$item),"$signal profile baseline restored without measurement");
  is_deeply(\@actions,[qw(exit unity 1d settings mode saved)],'restore order is explicit and verified');
  ok(!$item->{profile_baseline_needs_restore},'restore flag cleared only after evidence saved');
  for my $failure (qw(unity 1d settings saved)) {
   local *main::_api=sub {
    my $path=$_[1];
    return {status=>'ok',calibration_mode=>1} if $path eq '/api/lg/status';
    return {status=>'error',message=>'Injected restore failure'} if ($failure eq 'unity' && $path eq '/api/lg/3d-lut/reset') || ($failure eq '1d' && $path eq '/api/lg/1d-dpg/upload');
    return {status=>'ok',upload_verified=>1,dpg_uploaded=>1};
   };
   local *main::_apply_and_verify=sub {$failure ne 'settings'};
   local *main::_write_artifact=sub {$failure ne 'saved'};
   $item->{profile_baseline_needs_restore}=1;
   eval {main::_restore_profile_baseline(0,$item)};
   ok($@,"$signal $failure failure cannot report baseline restored");
   ok($item->{profile_baseline_needs_restore},"$signal $failure retains retry requirement");
  }
 }
 PGAutomation::write_json_atomic(PGAutomation::item_dir('boundary-test',0).'/calibration/grey-state.json',{status=>'complete',final_1d_lut_upload_verified=>1});
 @actions=();eval {main::_restore_profile_baseline(0,{signal_format=>'hdr10'})};
 like($@,qr/1D data is missing/,'missing curve cannot be substituted with identity');
 is(scalar @actions,0,'missing saved data prevents any TV writes');
}

# Run the production stage orchestration with hardware workers replaced.
{
 my @stages;
 local *main::_prepare_job_context=sub {1};
 local *main::_update_item_snapshot=sub {1};
 local *main::_update_run=sub {$_[0]->($state);$state};
 local *main::_copy_worker_files=sub {1};
 local *main::_pause_after_checkpoint=sub {0};
 local *main::_apply_and_verify=sub {1};
 local *main::_reset_for_calibration=sub {push @stages,'reset';1};
 local *main::_ensure_calibration_mode_off=sub {1};
 local *main::_panel_light_stage=sub {PGAutomation::write_json_atomic(PGAutomation::item_dir('boundary-test',0).'/panel-light.json',{verified=>1},0664)};
 local *main::_calibration_greyscale_stage=sub {push @stages,'1d';{verified=>1}};
 local *main::_calibration_volume_stage=sub {push @stages,'volume';{verified=>1}};
 local *main::_close_calibration=sub {push @stages,'exit';(1,{}, {}, {})};
 my $stop_point='';
 local *main::_calibration_settings_boundary=sub {
  push @stages,$_[2];
  if($_[2] eq $stop_point){$::LAST_ERROR='Review required';return 0;}
  return evidence();
 };
 for my $point ('','c6','c7','c8') {
  @stages=();$stop_point=$point;$state={items=>[]};
  $i={signal_format=>'dv',picture_mode=>'dolbyVisionCinemaBright',settings=>{},stages=>{pre_readings=>0,calibration=>1,post_readings=>0,apply_all=>0},settle_seconds=>0};
  main::_run_item(0,$i);
  my @expected=('reset','1d','c6');push @expected,('volume','c7') if $point ne 'c6';push @expected,('exit','c8') if $point ne 'c6' && $point ne 'c7';
  is_deeply(\@stages,\@expected,"$point checks between workers; no automatic full repeat");
  is($i->{status},$point?'interrupted':'complete',"$point has the expected terminal state") or diag(JSON::PP::encode_json($i->{failure}));
 }
}
done_testing();
