use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();

# The runner is guarded by caller(), so it can be loaded with a fake run id and
# token without starting a run. Its subs then run against an isolated store.
local $ENV{PGEN_AUTOMATION_DIR} = tempdir(CLEANUP => 1);
PGAutomation::ensure_store();
my $run_id = 'runner-load-test';
make_path(PGAutomation::run_dir($run_id) . '/items');
{
 local @ARGV = ($run_id, 'token-for-load-test');
 local $SIG{__WARN__} = sub {};
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die "runner failed to load: $@" if $@;
}
ok(defined(&main::_main), 'runner subs are loaded');
{
 no warnings qw(redefine once);
 my $live={status=>'ok',current_input=>'hdmi1',generation_profile=>{capability_profile_hash=>'profile-a'}};
 my $writes=0;
 local *main::_api=sub {die 'unexpected write' if $_[0] ne 'POST' || $_[1] ne '/api/lg/picture-settings'; return $live};
 local *main::_log_action=sub {};
 local *main::_begin_run=sub {$writes++;return {status=>'ok'}};
 my $item={capability_profile=>{hash=>'profile-a'},tv_input=>'hdmi1',signal_format=>'sdr',picture_mode=>'filmMaker'};
 ok(main::_verify_live_capability_profile($item),'matching fresh compatibility signature permits AutoCal');
 $live->{current_input}='hdmi2';
 ok(!main::_verify_live_capability_profile($item),'input change blocks AutoCal even when TV identity matches');
 $live->{current_input}='hdmi1';
 $live->{generation_profile}{capability_profile_hash}='profile-b';
 ok(!main::_reset_for_calibration(0,$item),'changed identity blocks calibration reset');
 is($writes,0,'identity mismatch is detected before opening a calibration session');
 delete $live->{generation_profile};
 ok(!main::_verify_live_capability_profile($item),'missing live signature cannot waive a saved compatibility signature');
 ok(!main::_verify_live_capability_profile({stages=>{calibration=>1}}),'calibration cannot bypass admission with no frozen signature');
}
ok(!defined(&main::_shell_quote), 'unused and incorrect _shell_quote is gone');
{
 no warnings qw(redefine once);
 local *main::_log=sub {};
 my $reply={status=>'ok',verification_state=>'acknowledged_unverified'};
 local *main::_api=sub {$reply};
 my $item={hazard_restore=>{autoPowerOff=>{value=>'off',category=>'power'}}};
 is(scalar @{main::_restore_hazards($item)},1,'acknowledged-only hazard restoration is a cleanup failure');
 delete $reply->{verification_state};
 is(scalar @{main::_restore_hazards($item)},1,'missing hazard verification cannot be treated as restored');
 $reply->{verification_state}='verified';
 is(scalar @{main::_restore_hazards($item)},0,'verified hazard restoration succeeds');
}
ok(!defined(&main::_quality_value), 'dead duplicate _quality_value is gone (PGAutomation::quality_summary is the live path)');

ok(main::_ping_ok({ok=>1}), 'daemon ping {ok:1} is healthy');
ok(!main::_ping_ok({status=>'error', error_code=>'daemon-unreachable', _transport_error=>1}), 'an error response is not a healthy ping');
ok(!main::_ping_ok(undef), 'missing ping is not healthy');

my $run_file = PGAutomation::run_dir($run_id) . '/run.json';
PGAutomation::write_atomic($run_file, "not json\n");
{
 local *STDERR; open(STDERR, '>', File::Spec->devnull()) if eval { require File::Spec; 1 };
 ok(!defined(main::_update_run(sub { $_[0]{clobbered} = 1; })), 'an unreadable manifest is refused rather than replaced');
}
is(PGAutomation::read_raw($run_file), "not json\n", 'the unreadable manifest is left untouched');
PGAutomation::write_json_atomic($run_file, {id=>$run_id, token=>'token-for-load-test', status=>'running', items=>[]});
ok(ref(main::_update_run(sub { $_[0]{touched} = 1; })) eq 'HASH', 'a readable manifest updates normally');
is(PGAutomation::read_json_file($run_file)->{touched}, 1, 'update persisted');
my $failure=main::_series_failure_message('greyscale-21',{
 status=>'error',current_step=>2,total_steps=>21,current_name=>'Meter integration mode change failed',debug=>'Instrument initialisation failed',
});
like($failure,qr/greyscale-21 failed at patch 2\/21: Meter integration mode change failed/,'series failure preserves the worker cause and patch');
like($failure,qr/Driver: Instrument initialisation failed/,'driver diagnostics survive in the saved failure');
like(main::_series_failure_message('colors',{status=>'cancelled'}),qr/Worker returned cancelled/,'missing worker message has an honest fallback');
for my $pair (
 ['dolbyVisionCinemaBright','dolbyHdrCinemaBright'],
 ['dolbyVisionCinemaHome','dolby_hdr_cinema_bright'],
 ['dolbyVisionFilmMaker','dolbyHdrCinema'],
 ['dolbyVisionCinemaDark','dolbyHdrCinema'],
 ['dolbyVisionGame','dolbyHdrGame'],
 ['dolbyVisionVivid','dolbyHdrVivid'],
 ['standard','normal'],
) {
 ok(main::_mode_agrees(@$pair),"equivalent modes agree: @$pair");
 ok(main::_mode_agrees(reverse @$pair),'alias comparison is symmetric');
}
ok(!main::_mode_agrees('dolbyVisionCinemaBright','dolbyHdrCinema'),'Cinema Home never matches dark Cinema');
ok(!main::_mode_agrees('filmMaker','dolbyHdrCinema'),'SDR Filmmaker never verifies a Dolby Vision mode');
ok(!main::_mode_agrees('hdrCinemaBright','dolbyHdrCinemaBright'),'HDR10 and Dolby Vision remain distinct');
ok(!main::_mode_agrees('dolbyVisionCinemaBright',''),'missing readback is not verified');
like(main::_settings_failure_message('c1',{values=>{
 pictureMode=>{expected=>'dolbyVisionCinemaBright',observed=>'dolbyHdrCinema',matched=>0},
 brightness=>{expected=>50,observed=>50,matched=>1},
}}),qr/pictureMode: requested dolbyVisionCinemaBright, TV reported dolbyHdrCinema$/,'settings error names the mismatched control and both values');
{
 open my $fh,'<',"$Bin/../usr/bin/pgen_automation_runner.pl" or die $!;local $/;my $source=<$fh>;
 unlike($source,qr/_stage\([^\n]*'warmup-done'/,'runner no longer executes per-job warm-up, even for old run manifests');
}
{
 no warnings 'redefine';
 my @checks;
 local *main::_append_setting_check=sub {push @checks,$_[2];return 1};
 local *main::_api=sub {return {status=>'ok',picture_settings=>{brightness=>50,energySaving=>'off'},unsupported_picture_keys=>{brightness=>1}}};
 main::_read_and_verify_settings(0,{settings=>{brightness=>50}},'c1');
 my ($brightness)=grep {$_->{key} eq 'brightness'} @checks;
 is($brightness->{result},'unverifiable','unsupported readback is not verified even when a value is present');
 like($brightness->{reason},qr/does not support reading/,'unsupported readback saves the actual limitation');
 @checks=();
 local *main::_api=sub {return {status=>'error',message=>'TV read timed out',error_code=>'lg-read-timeout'}};
 main::_read_and_verify_settings(0,{settings=>{brightness=>50}},'c1');
 ($brightness)=grep {$_->{key} eq 'brightness'} @checks;
 is($brightness->{reason},'TV read timed out','read failure preserves driver cause');
 is($brightness->{error_code},'lg-read-timeout','read failure preserves driver code');
 @checks=();
 local *main::_apply_one_setting=sub {return {status=>'error',message=>'TV rejected this setting',error_code=>'rejected'}};
 ok(!main::_apply_and_verify(0,{stages=>{calibration=>0},settings=>{brightness=>50}},'c4'),'failed setting write stops apply stage');
 is($checks[0]{result},'apply-failed','failed write is distinct from readback mismatch');
 is($checks[0]{reason},'TV rejected this setting','write failure saves driver reason');
}
{
 no warnings 'redefine';
 my @logs;
 my @statuses=({status=>'running',current_name=>'White',current_step=>1,total_steps=>2},
               {status=>'running',current_name=>'White',current_step=>1,total_steps=>2},
               {status=>'complete',current_name=>'Gray',current_step=>2,total_steps=>2});
 local *main::_refresh_control=sub {};
 local *main::_api=sub {return {status=>'ok',connected=>1} if $_[1] eq '/api/lg/status';return shift @statuses};
 local *main::_sleep_controlled=sub {1};
 local *main::_update_run=sub {};
 local *main::_log=sub {push @logs,$_[0]};
 is(main::_wait_worker('/fake-status','greyscale',{})->{status},'complete','logging leaves worker completion unchanged');
 is(scalar @logs,2,'only changed worker progress is logged, not identical polls');
 like($logs[0],qr/White.*Patch 1 \/ 2/,'worker log records patch and current name');
 like($logs[1],qr/complete.*Gray/,'terminal worker outcome is retained');
 unlike($logs[1],qr/Patch /,'completion does not retain a potentially reset patch counter');
}
{
 no warnings 'redefine';
 my @logs;
 local *main::_log=sub {push @logs,$_[0]};
 local *main::_active_item_number=sub {1};
 my $last;
 main::_log_wait('TV settings readback',100,\$last,119);
 is(scalar @logs,0,'fast requests do not create waiting noise');
 main::_log_wait('TV settings readback',100,\$last,120);
 like($logs[-1],qr/^Job 2 \| Waiting for TV settings readback \(20 s elapsed\)$/,'slow requests identify job, action and elapsed time');
 main::_log_wait('TV settings readback',100,\$last,149);
 is(scalar @logs,1,'wait notices are rate limited');
 main::_log_wait('TV settings readback',100,\$last,150);
 is(scalar @logs,2,'continued wait is reported after thirty seconds');
 is(main::_api_wait_label('/api/lg/picture-settings/set',{settings=>{pictureMode=>'filmMaker'},automation_token=>'secret'}),'TV to accept picture mode filmMaker','mode waits name the requested picture mode without exposing credentials');
 is(main::_api_wait_label('/api/lg/picture-settings/set',{settings=>{password=>'secret'}}),'TV to apply picture settings','settings wait never dumps arbitrary payloads');
 main::_log_action("one\ntwo");
 is($logs[-1],'Job 2 | one two','one action occupies one log line');
}
{
 no warnings 'redefine';
 my @logs;
 local *main::_log=sub {push @logs,$_[0]};
 local *main::_apply_one_setting=sub {
  like($logs[-1],qr/Selecting SDR picture mode filmMaker/,'picture-mode action is announced before the blocking write') if $_[1] eq 'pictureMode';
  return {status=>'ok'};
 };
 local *main::_sleep_controlled=sub {1};
 local *main::_append_setting_check=sub {1};
 local *main::_api=sub {{status=>'ok',picture_settings=>{pictureMode=>'filmMaker',brightness=>50,energySaving=>'off'}}};
 ok(main::_apply_and_verify(0,{stages=>{calibration=>0},signal_format=>'sdr',picture_mode=>'filmMaker',settle_seconds=>8,settings=>{brightness=>50}},'settings-applied'),'settings application still succeeds with logging');
 like(join("\n",@logs),qr/write accepted; allowing 8 s.*\n.*Applying \d+ queued TV settings.*\n.*Reading back.*\n.*matched/s,'log distinguishes acceptance, settling, application and actual verification');
}
{
 no warnings 'redefine';
 my @logs;
 local *main::_log=sub {push @logs,$_[0]};
 local *main::_api=sub {
  return {status=>'ok'} if $_[1] eq '/api/pattern';
  return {status=>'measuring'} if $_[1] eq '/api/meter/read';
  return {status=>'error',message=>'Instrument disconnected'};
 };
 ok(!defined(main::_read_white({signal_format=>'sdr'})),'failed white read still returns failure');
 like($logs[-1],qr/measurement error: Instrument disconnected/,'white read failure log retains the meter cause');
 local *main::_api=sub {{status=>'ok'}};
 main::_read_white({signal_format=>'sdr'});
 like($logs[-1],qr/no reading/,'empty success response is explicitly visible without claiming a white reading');
}
{
 no warnings 'redefine';
 local *main::_log=sub {};
 local *main::_verify_live_capability_profile=sub {1};
 my @checks;my @writes;
 local *main::_append_setting_check=sub {push @checks,$_[2];1};
 my $identity={model_name=>'OLED65C1PUB',platform_model=>'W21O'};
 my $matrix=PGLGCapabilities::lg_setting_contracts($identity,category=>'picture',signal_mode=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi1',keys=>[qw(brightness noiseReduction)]);
 my $reply={status=>'ok',current_input=>'hdmi1',virtual_picture_settings=>1,
  generation_profile=>{capability_library_valid=>1,capability_platform_profile_applied=>1,picturemode_readable=>0},
  picture_settings=>{brightness=>50,pictureMode=>'filmMaker'},supported_picture_keys=>['brightness'],
  unsupported_picture_keys=>{noiseReduction=>'Some keys are not allowed'},setting_contracts=>$matrix->{contracts}};
 my $item={settings=>{brightness=>50,noiseReduction=>'off'},signal_format=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi1',
  capability_profile=>{hash=>$matrix->{capability_profile_hash}}};
 $item->{best_available_settings}=PGLGCapabilities::lg_best_settings_plan($identity,$item->{settings},$reply,
  category=>'picture',signal_mode=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi1');
 local *main::_api=sub {$reply};
 is_deeply(main::_item_settings($item),{brightness=>50},'shared runner policy excludes manual values from automatic writes');
 is_deeply(main::_three_d_payload($item)->{automation_processing_settings},{},'3D worker cannot reapply manual processing settings');
 is($item->{settings}{noiseReduction},'off','original requested manual value stays in job audit');
 my $check=main::_read_and_verify_settings(0,$item,'c1');
 is($check->{verified},'unverifiable','manual requirements prevent an overall verified claim');
 ok($check->{values}{brightness}{matched},'native brightness can verify despite virtual picture-mode response');
 ok($check->{values}{noiseReduction}{manual_required},'checkpoint preserves manual setting evidence');
 $reply->{picture_settings}{brightness}=49;
 ok(!main::_read_and_verify_settings(0,$item,'c1')->{verified},'virtual mode cannot hide a real native mismatch');
 $reply->{picture_settings}{brightness}=50;
 $item->{settings}{noiseReduction}='low';
 ok(exists(main::_item_settings($item)->{noiseReduction}),'changed requested value invalidates its saved manual exclusion');
 $item->{settings}{noiseReduction}='off';
 $item->{tv_input}='hdmi2';
 ok(exists(main::_item_settings($item)->{noiseReduction}),'changed input invalidates saved manual exclusions');
 $item->{tv_input}='hdmi1';
 delete $reply->{picture_settings}{brightness};
 $reply->{supported_picture_keys}=[];
 $reply->{unsupported_picture_keys}{brightness}='Some keys are not allowed';
 local *main::_apply_one_setting=sub {
  push @writes,$_[1];
  return {status=>'ok',verification_state=>'acknowledged_unverified',setting_contracts=>$matrix->{contracts},
   setting_verification=>{brightness=>{status=>'acknowledged_unverified',expected=>50}}};
 };
 is(main::_apply_and_verify(0,$item,'c1',1),'unverifiable','accepted matrix write-only setting proceeds with honest checkpoint');
 is_deeply(\@writes,['brightness'],'manual setting is never sent to the TV');
 ok($item->{best_available_write_ack}{brightness},'runner stores current per-key acknowledgement');
 $reply->{unsupported_picture_keys}{brightness}='Permission denied: setting unavailable';
 ok(!main::_read_and_verify_settings(0,$item,'c1')->{verified},'accepted write cannot waive a later authentication failure');
 $reply->{unsupported_picture_keys}{brightness}='Some keys are not allowed';
 local *main::_apply_one_setting=sub {{status=>'ok',verification_state=>'acknowledged_unverified'}};
 ok(!main::_apply_and_verify(0,$item,'c1',1),'missing per-key contract cannot reuse previous acknowledgement');
 ok(!exists($item->{best_available_write_ack}{brightness}),'failed new attempt clears previous acknowledgement');
 local *main::_append_setting_check=sub {0};
 ok(!main::_read_and_verify_settings(0,$item,'c1')->{verified},'unpersisted manual evidence fails closed');
}
done_testing();
