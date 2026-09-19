# Regression for PR 14 test report P16, P19 and P29: a restoration that can
# never succeed must not hold the TV forever, and a parked failure must give
# the TV back the way a safe Pause does.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

my ($store,$run_id,$run_file,%config,%modes,$hash,$input,$tv_down,@sets,$set_state,$panel_ok);
sub fresh {
 my ($id)=@_;
 $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 $run_id=$id;$run_file=PGAutomation::run_dir($run_id).'/run.json';
 {local @ARGV=($run_id,'test-token');local $SIG{__WARN__}=sub{};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
 install_mocks();
 %config=(signal_mode=>'sdr',eotf=>'0',primaries=>'0',colorimetry=>'2',color_format=>'0',rgb_quant_range=>'2',max_bpc=>'10',dv_map_mode=>'2');
 %modes=(sdr=>'expert1',hdr10=>'hdrCinema');$hash='a'x64;$input='hdmi1';$tv_down=0;@sets=();$set_state='verified';$panel_ok=1;
 my @items=map {main::webui_automation_normalize_item({id=>"j$_",name=>"J$_",signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',settings=>{},settle_seconds=>0,stages=>{calibration=>1,apply_all=>0}})} 0;
 PGAutomation::write_json_atomic($run_file,{id=>$run_id,token=>'test-token',status=>'running',items=>\@items,queue_revision=>0});
 PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$run_id,token=>'test-token',status=>'running',pid=>0});
 PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'none'});
}
sub tv {return {status=>'ok',current_input=>$input,picture_settings=>{pictureMode=>$modes{$config{signal_mode}}},supported_picture_keys=>['pictureMode'],
 lg_generation=>{picture_mode_read_forbidden=>JSON::PP::false},generation_profile=>{capability_profile_hash=>$hash,capability_profile_id=>'x',capability_library_valid=>1,capability_platform_profile_applied=>1}};}
sub install_mocks {
*main::_api=sub {
 my ($m,$p,$pl)=@_;
 if($p eq '/api/config'){return {%config} if $m eq 'GET';@config{keys %$pl}=values %$pl;return {status=>'ok'};}
 return {ok=>1} if $p eq '/api/ping';
 return {status=>'ok'} if $p eq '/api/pattern' || $p eq '/api/meter/session/stop';
 return {status=>'error',message=>'TV unreachable'} if $tv_down && $p=~m{^/api/lg/};
 return tv() if $p eq '/api/lg/picture-settings';
 if($p eq '/api/lg/picture-settings/set'){
  if(exists $pl->{settings}{pictureMode}){$modes{$config{signal_mode}}=$pl->{settings}{pictureMode};return tv();}
  push @sets,$pl->{settings};
  my ($key)=keys %{$pl->{settings}};
  return {status=>'ok',verification_state=>$set_state,
   setting_verification=>{$key=>{status=>$set_state,expected=>$pl->{settings}{$key}}},
   setting_contracts=>{$key=>{write_decision=>'allowed',allow_unverified_readback=>JSON::PP::true}}};
 }
 return {status=>$panel_ok?'ok':'error'} if $p eq '/api/lg/panel-protection';
 if($p eq '/api/automation/readiness'){
  return {status=>'ok',ready=>1,checks=>[],items=>$pl->{items}} if $pl->{scope} eq 'batch';
  my $it=main::webui_automation_normalize_item($pl->{items}[0]);$it->{tv_input}=$input;$it->{capability_profile}={hash=>$hash,id=>'x'};$it->{generation_profile}=tv()->{generation_profile};
  return {status=>'ok',ready=>1,items=>[$it],checks=>[]};
 }
 die "unexpected $m $p";
};
*main::_sleep_controlled=sub{1};*main::_log=sub{};*main::_log_action=sub{};*main::_ensure_lg_connection=sub{1};
}
sub run_json {PGAutomation::read_json_file($run_file)}
sub batch_then {
 my ($change)=@_;
 ok(main::_preflight_queue()->{ready},"$change: preflight ready and viewing context saved");
 $config{signal_mode}='hdr10';$modes{hdr10}='hdrFilmMaker';
 # A job's mode write is journalled against its signal, as _select_item_picture_mode does.
 PGAutomation::with_lock($run_file,sub {$_[0]{viewing_restore_required}=JSON::PP::true;$_[0]{mode_written_signals}={hdr10=>JSON::PP::true};return $_[0];});
 $hash='b'x64 if $change eq 'firmware';$input='hdmi2' if $change eq 'input';
}

# P16: the TV's identity changed between batch start and finish.
for my $change (qw(firmware input)) {
 fresh("p16-$change");batch_then($change);
 # The real helper refuses a signal switch that carries the saved TV context
 # once the TV changed; restoration must not depend on that switch.
 my $switches=0;my $real_apply=\&main::_apply_signal;
 local *main::_apply_signal=sub {$switches++;return 0 if $hash ne 'a'x64 || $input ne 'hdmi1';$real_apply->(@_)};
 main::_finish('complete');
 is($switches,0,"$change: the change is detected before any signal switch");
 my $run=run_json();
 is($run->{status},'complete-with-warnings',"$change: the batch completes with a warning instead of parking");
 ok(!$run->{viewing_restore_required},"$change: the restoration obligation is discharged");
 is($run->{viewing_restore_outcome},'abandoned-tv-changed',"$change: the outcome says why modes were left alone");
 like(join(' ',@{$run->{warnings}||[]}),$change eq 'input'?qr/TV input changed \(hdmi1 to hdmi2\)/:qr/compatibility profile changed/,"$change: the warning names the change");
 ok(!main::webui_automation_cleanup_required($run),"$change: no cleanup is required");
 ok(!-f "$store/execution.json","$change: the execution claim is released");
 is($modes{hdr10},'hdrFilmMaker',"$change: no picture mode is written to a TV that no longer matches");
 is($config{signal_mode},'sdr',"$change: the generator output is still returned");
}
{
 # A single transient read with a different hash does not abandon restoration.
 fresh('p16-transient');batch_then('none');
 my $reads=0;my $real=\&main::_api;
 local *main::_api=sub {my ($m,$p)=@_;if($p eq '/api/lg/picture-settings' && ++$reads==1){my $r=tv();$r->{generation_profile}{capability_profile_hash}='c'x64;return $r;}return $real->(@_);};
 main::_finish('complete');
 is(run_json()->{viewing_restore_outcome},'verified','a one-off different hash is re-read and restoration proceeds');
 is($modes{hdr10},'hdrCinema','and the original mode is restored');
}
{
 fresh('p16-control');batch_then('none');
 main::_finish('complete');
 my $run=run_json();
 is($run->{status},'complete','control: an unchanged TV completes cleanly');
 is($run->{viewing_restore_outcome},'verified','control: the original viewing context is verified');
 is($modes{hdr10},'hdrCinema','control: the original HDR10 mode is restored');
 is_deeply($run->{mode_written_signals},{},'control: the mode-write journal is cleared once restoration completes');
}

# P19: a protective setting accepted by the TV but not readable back.
{
 fresh('p19-unverified');
 PGAutomation::with_lock($run_file,sub {$_[0]{hazard_restore}={screenSaver=>{value=>'on',category=>'system'}};$_[0]{hazard_restore_pending}=JSON::PP::true;return $_[0];});
 $set_state='acknowledged_unverified';
 main::_restore_run_hazards(run_json(),run_json()->{items});
 main::_finish('complete');
 my $run=run_json();
 is(scalar(@sets),1,'the restore write was sent');
 is($run->{status},'complete-with-warnings','an unreadable restore completes with a warning');
 is_deeply($run->{hazard_restore_failures},[],'it is not recorded as a failure');
 is($run->{hazard_restore_unverified}[0]{key},'screenSaver','it is recorded as unverified');
 like(join(' ',@{$run->{warnings}||[]}),qr/screenSaver was restored to on, but this TV cannot read the setting back/,'the operator is told to confirm it');
 ok(!-f "$store/execution.json",'the execution claim is released');
 # The live card gets the same warning and outcome, not only History.
 my $public=main::webui_automation_public_run($run);
 like(join(' ',@{$public->{warnings}||[]}),qr/cannot read the setting back/,'the live run payload carries the warning');
 is($public->{hazard_restore_unverified}[0]{key},'screenSaver','and the unverified restore');
 is_deeply($public->{hazard_restore_failures},[],'and the (empty) failure list');
 # A later pass that verifies the key retires its warning.
 $set_state='verified';
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='running';return $_[0];});
 main::_restore_run_hazards(run_json(),run_json()->{items});
 unlike(join(' ',@{run_json()->{warnings}||[]}),qr/screenSaver was restored/,'a verified retry retires the cannot-read-back warning');
 is_deeply(run_json()->{hazard_restore_unverified},[],'and clears the unverified list');
}
{
 fresh('p19-unaccepted');
 PGAutomation::with_lock($run_file,sub {$_[0]{hazard_restore}={screenSaver=>{value=>'on',category=>'system'}};$_[0]{hazard_restore_pending}=JSON::PP::true;return $_[0];});
 $set_state='acknowledged_unverified';
 my $real=\&main::_api;
 local *main::_api=sub {my ($m,$p,$pl)=@_;return {status=>'ok',verification_state=>'acknowledged_unverified'} if $p eq '/api/lg/picture-settings/set';return $real->(@_);};
 main::_restore_run_hazards(run_json(),run_json()->{items});
 main::_finish('complete');
 is(run_json()->{status},'interrupted','an unverified reply without the write-acceptance evidence a job start requires is still a failure');
}
{
 fresh('p19-refused');
 PGAutomation::with_lock($run_file,sub {$_[0]{hazard_restore}={screenSaver=>{value=>'on',category=>'system'}};$_[0]{hazard_restore_pending}=JSON::PP::true;return $_[0];});
 $set_state='mismatch';
 main::_restore_run_hazards(run_json(),run_json()->{items});
 main::_finish('complete');
 my $run=run_json();
 is($run->{status},'interrupted','a restore the TV contradicts still requires cleanup');
 ok(-f "$store/execution.json",'and keeps the claim');
 $set_state='verified';
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='running';return $_[0];});
 main::_restore_run_hazards(run_json(),run_json()->{items});
 main::_finish('stopped');
 $run=run_json();
 is($run->{status},'stopped','Retry cleanup succeeds once the TV verifies the restore');
 ok(!-f "$store/execution.json",'and releases the claim');
}

# P29: a resumable stage failure parks the run and gives the TV back.
{
 fresh('p29-park');batch_then('none');
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='interrupted';$_[0]{viewing_restore_outcome}='verified';$_[0]{stop_cleanup}={verified=>JSON::PP::true,completed_at=>time()};return $_[0];});
 main::_park_interrupted('post-readings-done');
 my $run=run_json();
 is($run->{status},'interrupted','the failed batch stays resumable');
 ok(!$run->{viewing_restore_required},'the viewing context is restored at park');
 is($modes{hdr10},'hdrCinema','the original HDR10 mode is back');
 ok(!$run->{cleanup_required} && !main::webui_automation_cleanup_required($run),'no manual Retry cleanup is needed');
 ok($run->{pause_context_released},'resume will recreate the temporary device state');
}
{
 fresh('p29-tv-down');batch_then('none');
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='interrupted';$_[0]{stop_cleanup}={verified=>JSON::PP::true,completed_at=>time()};return $_[0];});
 $tv_down=1;
 main::_park_interrupted('post-readings-done');
 my $run=run_json();
 ok($run->{viewing_restore_required},'an unreachable TV keeps the restoration pending');
 ok($run->{cleanup_required},'and cleanup is still required');
}
{
 fresh('p29-outcome');
 PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/viewing-context.json',{original=>{},config=>{},modes=>{},order=>[]});
 PGAutomation::with_lock($run_file,sub {$_[0]{viewing_restore_outcome}='verified';$_[0]{viewing_context_restored_at}=1;return $_[0];});
 local *main::_apply_signal=sub {0};
 eval { main::_prepare_job_context(0,run_json()->{items}[0]) };
 my $run=run_json();
 ok($run->{viewing_restore_required},'a new job journals the restoration obligation');
 ok(!exists $run->{viewing_restore_outcome},'and drops the stale outcome from an earlier Pause');
}

{
 # P29: a latch _finish set for a failure outside restoration_problems (a
 # failed Pause whose meter release failed) survives the park.
 fresh('p29-latch');
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='interrupted';$_[0]{cleanup_required}=JSON::PP::true;
  $_[0]{cleanup_failure}={completed_at=>time(),message=>'Meter release failed: no acknowledgement'};return $_[0];});
 main::_park_interrupted('pause');
 ok(run_json()->{cleanup_required},'the meter-release cleanup latch is kept');
}

# P22 guards (H-finish-viewing-calend, H-pause-retry).
{
 # Never switch signals for viewing restoration while CAL_END is unconfirmed.
 fresh('guard-calend');batch_then('none');
 PGAutomation::with_lock($run_file,sub {$_[0]{stop_cleanup}={verified=>JSON::PP::false,completed_at=>time(),message=>'TV calibration exit unconfirmed'};return $_[0];});
 main::_finish('stopped');
 my $run=run_json();
 ok(!$run->{viewing_restore_required},'Stop skips viewing restoration even when calibration exit needs retry');
 is($modes{hdr10},'hdrFilmMaker','no picture mode is switched back yet');
 is($run->{status},'interrupted','and cleanup is still required');
}
{
 # Retry cleanup of a failed Pause parks as paused and never aborts the TV run.
 fresh('guard-pause-retry');
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='interrupted';$_[0]{pending_terminal_status}='paused';$_[0]{pause_park_pending}=JSON::PP::true;$_[0]{cleanup_required}=JSON::PP::true;return $_[0];});
 PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'stop'});
 my @paths;my $real=\&main::_api;
 local *PGAutomationLaunch::worker_handshake=sub {1};
 local *main::_worker_process_alive=sub {0};
 local *main::_api=sub {
  my ($m,$p)=@_;push @paths,$p;
  return {status=>'ok'} if $p=~m{/(?:stop|kill)$} || $p eq '/api/lg/autocal/run/end';
  return {status=>'ok',calibration_mode=>JSON::PP::false} if $p eq '/api/lg/calibration-mode';
  return {status=>'ok',calibration_mode=>JSON::PP::false} if $p eq '/api/lg/status';
  return $real->(@_);
 };
 ok(eval {main::_main();1},'the retry runs through the runner main') or diag $@;
 is(run_json()->{status},'paused','a retried Pause cleanup ends paused, not stopped');
 ok(!grep({$_ eq '/api/lg/autocal/run/end'} @paths),'and never aborts the TV calibration run');
}

# P14: restoration only switches through signals whose picture mode this run
# actually wrote; a run without the journal keeps walking every saved signal.
for my $journal (1,0) {
 fresh("p14-journal-$journal");batch_then('none');
 # The HDR10 mode was never changed by a job in this scenario.
 $modes{hdr10}='hdrCinema';
 PGAutomation::with_lock($run_file,sub {
  if($journal){$_[0]{mode_written_signals}={};}else{delete $_[0]{mode_written_signals};}
  return $_[0];
 });
 # A walk selects the signal even when the generator is already on it (no
 # config write then), so count the walks, not the config writes.
 my @signals;my $real_apply=\&main::_apply_signal;
 local *main::_apply_signal=sub {push @signals,main::_signal($_[0]);return $real_apply->(@_);};
 main::_finish('complete');
 my %seen=map {$_=>1} @signals;
 if ($journal) {
  ok(!$seen{hdr10},'a signal whose mode was never written is not switched through');
  ok($seen{sdr},'the original output is still restored');
  is_deeply(PGAutomation::read_json_file($run_file)->{mode_written_signals},{},'the journal stays empty after restoration');
 } else {
  ok($seen{hdr10} && $seen{sdr},'a run without the journal still walks every saved signal');
 }
 is(PGAutomation::read_json_file($run_file)->{status},'complete',"journal=$journal: the batch completes");
}
{
 fresh('p14-select');
 PGAutomation::with_lock($run_file,sub {$_[0]{mode_written_signals}={};return $_[0];});
 my $item=main::webui_automation_normalize_item({id=>'j',name=>'J',signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',settings=>{},settle_seconds=>0,stages=>{calibration=>1}});
 $item->{tv_input}='hdmi1';
 local *main::_read_and_verify_settings=sub {{verified=>1}};
 local *main::_append_setting_check=sub {1};
 $config{signal_mode}='hdr10';
 ok(main::_select_item_picture_mode(0,$item,'job-start',{verified=>'1',picture_mode=>'hdrCinema',current_input=>'hdmi1'}),'a mode change is selected');
 ok(PGAutomation::read_json_file($run_file)->{mode_written_signals}{hdr10},'and journalled against its signal before the write');
}

{
 # P14 (round 3): preflight restoration clears only preflight marks.
 fresh('p14-midrun');batch_then('none');
 PGAutomation::with_lock($run_file,sub {$_[0]{mode_written_signals}={hdr10=>{job=>JSON::PP::true},sdr=>{preflight=>JSON::PP::true}};
  $_[0]{preflight_restore_required}=JSON::PP::true;return $_[0];});
 ok(main::_restore_preflight_context('preflight'),'a mid-run preflight restoration completes');
 is_deeply(run_json()->{mode_written_signals},{hdr10=>{job=>JSON::PP::true}},'it keeps the job mark the viewing restoration still needs');
 main::_finish('complete');
 is($modes{hdr10},'hdrCinema','so the finish still restores the job signal');
}

# P23 (legacy): a paused manifest written before hazard_restore_pending existed
# still owes its protective settings, so boot recovery must flag it.
{
 fresh('boot-legacy');
 *main::webui_automation_recover_run=sub {};*main::webui_automation_reconcile_execution=sub {};*main::webui_automation_schedule_restart_cleanup=sub {};
 PGAutomation::write_json_atomic(PGAutomation::run_dir('legacy-paused').'/run.json',{id=>'legacy-paused',token=>'t',status=>'paused',
  hazard_restore=>{autoPowerOff=>{value=>'on',category=>'power'}},items=>[{}]});
 PGAutomation::write_json_atomic(PGAutomation::run_dir('legacy-item-paused').'/run.json',{id=>'legacy-item-paused',token=>'t',status=>'paused',
  items=>[{hazard_restore=>{screenSaver=>{value=>'on',category=>'system'}}}]});
 PGAutomation::write_json_atomic(PGAutomation::run_dir('modern-paused').'/run.json',{id=>'modern-paused',token=>'t',status=>'paused',
  hazard_restore=>{autoPowerOff=>{value=>'on',category=>'power'}},hazard_restore_pending=>JSON::PP::false,items=>[{}]});
 main::webui_automation_boot_recover();
 for my $id (qw(legacy-paused legacy-item-paused)) {
  my $run=PGAutomation::read_json_file(PGAutomation::run_dir($id).'/run.json');
  is($run->{status},'interrupted',"$id: a legacy paused run with protective changes is flagged at boot");
  ok($run->{cleanup_required} && $run->{hazard_restore_pending},"$id: and owes cleanup");
 }
 is(PGAutomation::read_json_file(PGAutomation::run_dir('modern-paused').'/run.json')->{status},'paused','a modern paused run whose protections were restored stays paused');
}
done_testing();
