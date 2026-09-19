# Regression for PR 14 test report P29 (round 2): a Pause whose cleanup fails
# keeps the run latched through the park, Retry cleanup finishes the Pause and
# clears every stale pause field, and a plain park after a good Pause is not
# latched by leftovers.
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


our $meter_down=0;
sub wrap_meter { my $real=\&main::_api; *main::_api=sub { return {status=>'error',message=>'no acknowledgement'} if $meter_down && $_[1] eq '/api/meter/session/stop'; return $real->(@_); }; }

# Failed Pause (meter release fails), then the park main() performs, then Retry cleanup.
{
 fresh('r2-meter');batch_then('none');wrap_meter();
 PGAutomation::with_lock($run_file,sub {$_[0]{pause_park_pending}=JSON::PP::true;$_[0]{stop_cleanup}={verified=>JSON::PP::true,completed_at=>time()};return $_[0];});
 $meter_down=1;
 is(main::_finish('paused'),0,'meter: failed Pause cleanup returns 0');
 my $run=run_json();
 is($run->{status},'interrupted','meter: failed Pause leaves the run interrupted');
 ok(!$run->{viewing_restore_required},'meter: viewing restore itself succeeded in _finish');
 is(scalar @{PGAutomation::restoration_problems($run)},0,'meter: restoration_problems is empty');
 main::_park_interrupted($run->{active_stage}||'stop-cleanup');
 $run=run_json();
 ok($run->{cleanup_required},'meter: latch survives the park');
 ok(main::webui_automation_cleanup_required($run),'meter: webui reports cleanup required, so Resume and Clear are refused');
 is($run->{pending_terminal_status},'paused','meter: stale pending_terminal_status still present while latched');
 ok(-f "$store/execution.json",'meter: claim retained');
 # Retry cleanup: stop path with parking -> _stop_active(1) (skipped here), hazards, _finish('paused')
 $meter_down=0;
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='running';return $_[0];});
 is(main::_finish(($run->{pending_terminal_status}||'') eq 'paused' && $run->{pause_park_pending} ? 'paused' : 'stopped'),1,'meter: Retry cleanup succeeds');
 $run=run_json();
 is($run->{status},'paused','meter: retry of a failed Pause ends paused');
 ok(!exists $run->{cleanup_required} && !exists $run->{cleanup_failure},'meter: latch and cleanup_failure both cleared');
 ok(!exists $run->{pending_terminal_status} && !exists $run->{pause_park_pending},'meter: stale pause fields cleared');
 ok(!main::webui_automation_cleanup_required($run),'meter: Resume no longer blocked');
 ok($run->{pause_context_released},'meter: resume will recreate device state');
}
# Failed Pause because the TV was down during the viewing restore; TV back before park.
{
 fresh('r2-tv');batch_then('none');
 PGAutomation::with_lock($run_file,sub {$_[0]{pause_park_pending}=JSON::PP::true;$_[0]{stop_cleanup}={verified=>JSON::PP::true,completed_at=>time()};return $_[0];});
 $tv_down=1;
 main::_finish('paused');
 ok(run_json()->{viewing_restore_required},'tv: restore still pending after failed Pause');
 $tv_down=0;
 main::_park_interrupted('stop-cleanup');
 my $run=run_json();
 ok(!$run->{viewing_restore_required},'tv: park retry restores the viewing context');
 ok($run->{cleanup_required},'tv: latch still held because cleanup_failure is present (conservative)');
}
# Plain P29 case: stage failure after an earlier successful Pause has no stale cleanup_failure.
{
 fresh('r2-plain');batch_then('none');
 main::_finish('paused');
 ok(!exists run_json()->{cleanup_failure},'plain: successful Pause leaves no cleanup_failure');
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='interrupted';$_[0]{viewing_restore_required}=JSON::PP::true;$_[0]{mode_written_signals}={hdr10=>JSON::PP::true};$modes{hdr10}='hdrFilmMaker';$_[0]{stop_cleanup}={verified=>JSON::PP::true,completed_at=>time()};return $_[0];});
 main::_park_interrupted('post-readings-done');
 ok(!run_json()->{cleanup_required},'plain: park still un-latches when nothing is owed');
}
# A latch set only because the viewing restore was still owed is released
# once the park itself returns the viewing context (nothing else is owed).
{
 fresh('r2-latch-released');batch_then('none');
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='interrupted';$_[0]{viewing_restore_required}=JSON::PP::true;$_[0]{cleanup_required}=JSON::PP::true;
  $_[0]{mode_written_signals}={hdr10=>JSON::PP::true};$_[0]{stop_cleanup}={verified=>JSON::PP::true,completed_at=>time()};return $_[0];});
 $modes{hdr10}='hdrFilmMaker';
 main::_park_interrupted('post-readings-done');
 my $run=run_json();
 ok(!$run->{viewing_restore_required},'latch: the park returns the viewing context');
 ok(!exists $run->{cleanup_required},'latch: and releases a cleanup latch that only the restore held');
 ok(!main::webui_automation_cleanup_required($run),'latch: Resume is no longer blocked');
}
done_testing();
