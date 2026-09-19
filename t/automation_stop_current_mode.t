use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();

sub fixture {
 $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
 PGAutomation::ensure_store();
 local @ARGV=('stop-current','test-token');
 {
  local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/^Subroutine \w+ redefined at/};
  do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@;
 }
 my $path=PGAutomation::run_dir('stop-current').'/run.json';
 PGAutomation::write_json_atomic($path,{id=>'stop-current',token=>'test-token',status=>'running',items=>[],
  preflight_restore_required=>JSON::PP::true,viewing_restore_required=>JSON::PP::true,
  panel_protection=>{restore_pending=>JSON::PP::true},
  hazard_restore=>{screenSaver=>{value=>'on',category=>'system'}},hazard_restore_pending=>JSON::PP::true});
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',
  {owner=>'automation',run_id=>'stop-current',token=>'test-token',status=>'running'});
 return $path;
}

for my $failure ('','fallback','calibration','panel','meter') {
 my $path=fixture();my (@calls,@messages);
 local *main::_control=sub {{request=>'stop'}};
 local *main::_log=sub {push @messages,$_[0]};
 local *main::_heartbeat=sub {};
 local *main::_ensure_lg_connection=sub {1};
 local *main::_worker_process_alive=sub {0};
 local *main::_api_once=sub {
  my ($method,$route,$payload)=@_;
  push @calls,[$route,$payload];
  die "Stop must not restore settings: $route" if $route=~m{config|picture-settings|reset|upload};
  return {status=>'error',message=>'CAL_END rejected'} if $failure eq 'calibration' && $route=~m{calibration-mode|autocal/run/end};
  return {status=>'error',message=>'CAL_END rejected'} if $failure eq 'fallback' && $route eq '/api/lg/calibration-mode';
  return {status=>'error',message=>'TPC/GSR refused'} if $failure eq 'panel' && $route eq '/api/lg/panel-protection';
  return {status=>'error',message=>'Meter still busy'} if $failure eq 'meter' && $route eq '/api/meter/session/stop';
  return {status=>'ok',calibration_mode=>$failure eq 'calibration'?1:0};
 };
 main::_stop_active();
 main::_restore_run_hazards(main::_run(),[]);
 my $finished=main::_finish('stopped');
 my $run=PGAutomation::read_json_file($path);
 is($run->{stop_restore_policy},'current-mode-only','Stop records the current-mode policy');
 ok(!$run->{viewing_restore_required} && !$run->{preflight_restore_required},'saved modes cannot keep Stop locked');
 is($run->{viewing_restore_outcome},'skipped-on-stop','skipped restoration is never claimed as verified');
 my @exit=grep {$_->[0] eq '/api/lg/calibration-mode'} @calls;
 is(scalar @exit,1,'Stop sends CAL_END once');
 ok(!$exit[0][1]{enabled} && $exit[0][1]{current_picture_mode},'CAL_END targets the current mode');
 my @end=grep {$_->[0] eq '/api/lg/autocal/run/end'} @calls;
 ok($end[0][1]{current_picture_mode},'run-end fallback is restricted to the current mode too');
 my @panel=grep {$_->[0] eq '/api/lg/panel-protection'} @calls;
 is(scalar @panel,1,'Stop attempts panel protection restoration');
 ok($panel[0][1]{enable},'both protections are re-enabled, never disabled');
 for my $step (1..4) {ok(grep(/Stop $step\/4/,@messages),"cleanup step $step is visible");}
 if ($failure eq '' || $failure eq 'fallback') {
  ok($finished,'verified Stop finishes');
  is($run->{status},'stopped','run is stopped');
  ok(!-e PGAutomation::base_dir().'/execution.json','execution is released');
  like($run->{worker_status}{message},qr/Stopped.*TPC\/GSR.*no readback/,'final message describes the actual protection evidence');
 } else {
  ok(!$finished,"$failure failure cannot claim a clean stop");
  ok($run->{cleanup_required},"$failure failure remains retryable");
  ok(-e PGAutomation::base_dir().'/execution.json',"$failure failure keeps ownership");
 }
}

{
 my $path=fixture();my @calls;
 local *main::_control=sub {{request=>'stop'}};
 local *main::_log=sub {};
 local *main::_heartbeat=sub {};
 local *main::_ensure_lg_connection=sub {1};
 local *main::_worker_process_alive=sub {0};
 local *main::_api_once=sub {
  push @calls,$_[1];
  die 'Stop tried to restore modes' if $_[1]=~m{config|picture-settings};
  return {status=>'ok',calibration_mode=>0};
 };
 ok(main::_finish('complete'),'Stop at normal finish completes safety cleanup');
 is(PGAutomation::read_json_file($path)->{status},'stopped','Stop cannot be reported as normal batch completion');
 like($calls[0],qr{/stop$},'workers are stopped before final meter release');
 ok(grep($_ eq '/api/lg/panel-protection',@calls),'late Stop still restores TPC/GSR');
}

{
 my $path=fixture();my @writes;
 PGAutomation::write_json_atomic(PGAutomation::run_dir('stop-current').'/viewing-context.json',
  {original=>{},config=>{signal_mode=>'sdr'},order=>['dv'],modes=>{dv=>{signal_format=>'dv'}}});
 local *main::_control=sub {{request=>'none'}};
 local *main::_log=sub {};
 local *main::_heartbeat=sub {};
 local *main::_restore_identity_changed=sub {''};
 local *main::_ensure_lg_connection=sub {1};
 local *main::_api_once=sub {
  my ($method,$route)=@_;
  push @writes,$route if $method eq 'POST';
  # Stop arrives while the first restoration read is already on the wire.
  kill 'TERM',$$;
  return {status=>'ok',signal_mode=>'sdr'};
 };
 ok(main::_restore_preflight_context('viewing'),'Stop during restoration abandons the mode tour');
 is_deeply(\@writes,[],'no mode/signal write follows the in-flight read');
 is(PGAutomation::read_json_file($path)->{viewing_restore_outcome},'skipped-on-stop','mid-restoration cancellation is recorded honestly');
}

{
 # The daemon must not reintroduce the job's stale mode after the runner
 # explicitly requests CAL_END on the currently displayed mode.
 require "$Bin/../usr/share/PGenerator/lg.pm";
 my @requests;
 local *main::lg_automation_guard_json=sub {''};
 local *main::lg_load_clients=sub {{}};
 local *main::lg_reconcile_pin_pairing=sub {($_[0],undef)};
 local *main::lg_clients_disconnected=sub {0};
 local *main::lg_target_ip=sub {'192.0.2.1'};
 local *main::lg_primary_client=sub {{client_key=>'fixture'}};
 local *main::lg_helper_run=sub {push @requests,$_[0];{status=>'ok'}};
 local *main::lg_update_connect_metadata=sub {{}};
 local *main::lg_save_clients=sub {};
 local *main::lg_calmode_trace=sub {};
 local *main::lg_status_response=sub {{status=>$_[0]}};
 for my $enabled (0,1) {
  main::webui_lg_calibration_mode(PGAutomation::encode_json({enabled=>$enabled,
   current_picture_mode=>JSON::PP::true,picture_mode=>'hdrCinema',signal_mode=>'hdr10'}));
 }
 is($requests[0]{picture_mode},'','current-mode exit drops the old job picture mode');
 is($requests[0]{signal_mode},'','current-mode exit drops the old job signal');
 ok(!$requests[0]{enable},'current-mode request only closes calibration');
 is($requests[1]{picture_mode},'hdrCinema','CAL_START still requires the requested bank');
 local *main::lg_autocal_worker_running=sub {0};
 local *main::lg_store_calibration_mode_state=sub {};
 main::lg_close_calibration_mode_at_run_end({calibration_mode=>1,calibration_picture_mode=>'hdrCinema'},
  {current_picture_mode=>JSON::PP::true,signal_mode=>'hdr10'});
 is($requests[-1]{picture_mode},'','run-end fallback cannot close the stale saved job bank');
 is($requests[-1]{signal_mode},'','run-end fallback cannot reuse the stale saved signal');
}
done_testing();
