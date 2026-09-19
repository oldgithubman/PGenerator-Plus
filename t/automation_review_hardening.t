use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use Time::HiRes qw(time);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
use PGAutomationLaunch ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";
my ($store,$id,$path,$claim);
sub fixture {
 $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;
 PGAutomation::ensure_store();$id='hardening';$path=PGAutomation::run_dir($id).'/run.json';$claim="$store/execution.json";
 local @ARGV=($id,'private-test-token');
 {local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/^Subroutine .* redefined/};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
 PGAutomation::write_json_atomic($path,{id=>$id,token=>'private-test-token',status=>'running',items=>[],checkpoints=>[{name=>'greyscale-done',status=>'done'}]});
 PGAutomation::write_json_atomic($claim,{owner=>'automation',run_id=>$id,token=>'private-test-token',status=>'running'});
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/control.json',{request=>'none'});
}
fixture();
{
 my $file="$store/atomic.json";my @dirs;my $real=\&PGAutomation::sync_directory;
 local *PGAutomation::sync_directory=sub {push @dirs,$_[0];$real->(@_)};
 ok(PGAutomation::write_json_atomic($file,{test=>1},0664),'checked durable file publication succeeds');
 is_deeply(\@dirs,[$store],'containing directory is synced after publication');
 is((stat($file))[2]&0777,0600,'automation records are private despite requested public mode');
 is((stat($store))[2]&0777,0700,'existing store directory is made private');
 local *PGAutomation::sync_directory=sub {0};
 ok(!PGAutomation::write_json_atomic($file,{test=>2}),'directory sync failure is not reported as durable success');
}
{
 my $dark="$store/dark";mkdir($dark,0700) or die $!;chmod(0300,$dark);
 SKIP: {
  skip 'root ignores directory permissions',2 if $>==0;
  ok(!PGAutomation::write_json_atomic("$dark/x.json",{test=>3}),'unreadable parent fails before publication');
  ok(!-e "$dark/x.json",'nothing is published when the parent cannot be synced');
 }
 chmod(0700,$dark);
}
{
 my $old=PGAutomation::run_dir('legacy');mkdir($old,0755) or die $!;mkdir("$old/items",0755) or die $!;
 PGAutomation::write_atomic("$old/launch.json","{}\n",0664);chmod(0664,"$old/launch.json");chmod(0755,$old,"$old/items");
 unlink("$store/.runs-private");
 ok(PGAutomation::ensure_store(),'store upgrade walks existing runs once');
 is((stat("$old/launch.json"))[2]&0777,0600,'legacy run manifests are made owner-only');
 is((stat("$old/items"))[2]&0777,0700,'legacy run directories are made owner-only');
 ok(-e "$store/.runs-private",'the walk leaves a marker so it stays off the request path');
}
{
 open my $one,'>>',"$store/contention.lock" or die $!;flock($one,LOCK_EX) or die $!;
 open my $two,'>>',"$store/contention.lock" or die $!;
 my $begin=time();ok(!PGAutomation::lock_exclusive($two,0.03),'contended lock has a bounded wait');
 cmp_ok(time()-$begin,'<',1,'contention cannot indefinitely pin an HTTP worker');
 close $two;close $one;
}
{
 PGAutomation::write_atomic($claim,'{corrupt');
 is(PGAutomation::read_state($claim)->{state},'error','corrupt and absent claims are distinct');
 my $guard=PGAutomation::decode_json(main::lg_automation_guard_json('{}'));
 is($guard->{error_code},'automation-state-unreadable','corrupt claim fails closed for device writes');
 is(main::webui_automation_read_execution()->{status},'interrupted','admission sees uncertain ownership as occupied');
 local *main::webui_automation_reap_dead_runner=sub {0};
 local *main::webui_automation_checked_readiness=sub {die 'must not touch equipment'};
 is(PGAutomation::decode_json(main::webui_automation_start({items=>[]}))->{error_code},'automation-active','new start cannot bypass unreadable ownership');
}
fixture();
{
 PGAutomation::write_atomic($path,'bad manifest');
 main::webui_automation_reconcile_execution();
 ok(-f $claim,'unreadable manifest never deletes execution ownership');
 is(PGAutomation::read_json_file($claim)->{status},'interrupted','unknown manifest remains an explicit recovery state');
}
my $item={signal_format=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi1',settings=>{},panel_protection=>{disable=>1},panel_protection_supported=>1};
fixture();
{
 my $calls=0;
 local *main::_log=sub {};
 local *main::_api=sub {$calls++;ok(PGAutomation::read_json_file($path)->{panel_protection}{restore_pending},'restore obligation exists before a disable request reaches the TV');return {status=>'ok'};};
 local *main::_write_artifact=sub {0};
 ok(!main::_panel_protection_disable(0,$item),'failed evidence write cannot claim successful disable');
 is($calls,1,'only the intended disable was issued');
 ok(PGAutomation::read_json_file($path)->{panel_protection}{restore_pending},'failed artifact write does not lose restoration obligation');
}
fixture();
{
 my $calls=0;local *main::_api=sub {$calls++;return {status=>'ok'}};
 local *main::_update_run=sub {undef};
 ok(!eval {main::_panel_protection_disable(0,$item);1},'failed intent journal aborts before mutation');
 is($calls,0,'no TV write after journal failure');
}
fixture();
{
 local *main::_log=sub {};
 local *main::_api=sub {{status=>'error',message=>'One control rejected',controls=>{tpc=>{dispatched=>1},gsr=>{dispatched=>0}}}};
 my $e=main::_panel_protection_disable(0,{%$item});
 is($e->{outcome},'failed','partial compound failure stays a failure');
 ok(PGAutomation::read_json_file($path)->{panel_protection}{restore_pending},'partial dispatch still must be restored');
}
{
 local *main::_log=sub {};
 local *main::_api=sub {{status=>'ok'}};
 ok(!main::_finish('complete'),'outstanding protection debt prevents completion even when meter release succeeds');
 is(PGAutomation::read_json_file($path)->{status},'interrupted','failed finalisation remains recoverable');
 ok(-e $claim,'protection debt retains exclusive ownership');
 ok(main::webui_automation_cleanup_required(PGAutomation::read_json_file($path)),'UI cannot hide outstanding protection debt');
 main::_restore_run_hazards(PGAutomation::read_json_file($path),[]);
 ok(!PGAutomation::read_json_file($path)->{panel_protection}{restore_pending},'successful dispatch clears write-only restoration debt without pretending readback');
 ok(main::_finish('complete'),'genuine restoration retry permits completion');
 ok(!-e $claim,'verified finalisation releases its own claim');
}
fixture();
{
 local *main::_log=sub {};
 local *main::_worker_process_alive=sub {0};
 local *main::_ensure_lg_connection=sub {1};
 my @calls;local *main::_api=sub {push @calls,$_[1];return {status=>'ok',calibration_mode=>0,disconnected=>0};};
 PGAutomation::with_lock($path,sub {$_[0]{panel_protection}={restore_pending=>1};return $_[0];});
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/control.json',{request=>'pause'});
 ok(main::_pause_after_checkpoint(),'Pause reaches safe parking');
 my $run=PGAutomation::read_json_file($path);
 is($run->{status},'paused','safe park retains a resumable paused state');
 ok($run->{pause_context_released},'Resume knows it must recreate temporary device state');
 ok(!$run->{panel_protection}{restore_pending},'pause re-enables temporary panel protection');
 is($run->{checkpoints}[0]{name},'greyscale-done','pause preserves completed calibration checkpoints');
 is(PGAutomation::read_json_file($claim)->{status},'paused','paused claim stays reserved for its run');
 ok(grep($_ eq '/api/lg/calibration-mode',@calls),'pause closes TV calibration mode');
 ok(!grep($_ eq '/api/lg/autocal/run/end',@calls),'pause does not abort the retained LG run');
}
fixture();
{
 local *main::_log=sub {};local *main::_heartbeat=sub {};local *main::_ensure_lg_connection=sub {1};local *main::_sleep_controlled=sub {1};
 my $calls=0;local *main::_api_once=sub {$calls++;return $calls==1?{status=>'error',message=>'LG WebOS TV websocket connection closed after send'}:{status=>'ok'};};
 my $result=main::_api('POST','/api/lg/hdr-calman-reset',{});
 is($calls,1,'unknown delivery on reset is not replayed merely because reconnection is possible');
 is($result->{status},'error','unknown outcome stays actionable');
 $calls=0;local *main::_api_once=sub {$calls++;return $calls==1?{status=>'error',message=>'Unable to connect to LG WebOS TV'}:{status=>'ok'};};
 is(main::_api('POST','/api/lg/hdr-calman-reset',{})->{status},'ok','a known pre-send refusal may reconnect safely');
 is($calls,2,'pre-send refusal is retried once after reconnect');
 ok(!main::_request_not_sent({delivery_state=>'outcome-unknown',message=>'Unable to connect to LG WebOS TV'}),'explicit delivery uncertainty takes precedence over message matching');
}
fixture();
{
 local *main::_log=sub {};local *main::_update_run=sub {{}};
 my $worker_id;local *main::_api=sub {my ($method,$route,$payload)=@_;if($method eq 'POST'){$worker_id=$payload->{automation_worker_id};return {status=>'started'}};return {status=>'complete',automation_worker_id=>'foreign-attempt'};};
 is(main::_start_worker('/worker','/status',{full_autocal_run_id=>$id})->{status},'started','new worker launch receives an attempt identity');
 like($worker_id,qr/^hardening-0-/,'identity includes run and job, not just the batch');
 is(main::_wait_worker('/status','test',{})->{error_code},'worker-identity-mismatch','a foreign terminal result cannot complete this job');
 local *main::_api=sub {{status=>'complete',automation_worker_id=>$worker_id}};
 is(main::_wait_worker('/status','test',{})->{status},'complete','matching terminal result is accepted');
 my $state=PGAutomation::stamp_worker_state({status=>'running'},{automation_worker_id=>$worker_id});
 is($state->{worker_pid},$$,'worker stamps its own PID');
 SKIP: {
  skip 'process birth ticks need Linux /proc',1 if !-r "/proc/$$/stat";
  ok(main::_owned_worker_alive($state),'matching process birth identity is live');
 }
 $state->{worker_start_ticks}='wrong';
 ok(!main::_owned_worker_alive($state),'PID alone cannot impersonate the recorded worker');
 my $statefile="$store/replay.json";
 PGAutomation::write_json_atomic($statefile,{status=>'complete',automation_worker_id=>$worker_id});
 my $body=PGAutomation::encode_json({automation_worker_id=>$worker_id});
 ok(PGAutomation::decode_json(PGAutomation::worker_replay_json($body,$statefile))->{replayed},'lost acknowledgement after completion cannot start the same calibration again');
 is(PGAutomation::worker_replay_json('{"automation_worker_id":"other"}',$statefile),'','different attempts cannot reuse the completion');
}
fixture();
{
 local *main::_log=sub {};
 my $quality_item={signal_format=>'sdr',picture_mode=>'filmMaker',post_series=>['greyscale-21'],stages=>{post_readings=>1},
  target_white=>{x=>.3127,y=>.329},quality=>{enabled=>1,policy=>'enforce',dE_formula=>'de2000',limits=>{'greyscale-21'=>{avg=>1,max=>1}}}};
 my $base=PGAutomation::item_dir($id,0);
 ok(!main::_quality_admits_apply(0,$quality_item),'absent independent quality proof cannot authorise propagation');
 my $reading={X=>100*.3127/.329,Y=>100,Z=>100*(1-.3127-.329)/.329,target_x=>.3127,target_y=>.329,custom_target_nits=>100,series_target_white_y=>100};
 PGAutomation::write_json_atomic("$base/post/greyscale-21.json",{status=>'complete',white_reading=>{Y=>100},steps=>[map {{name=>$_}} 1..21],readings=>[map {{%$reading}} 1..21]});
 ok(main::_quality_stage(0,$quality_item),'quality evidence is durably recorded');
 ok(main::_quality_admits_apply(0,$quality_item),'matching fully measured passing evidence authorises propagation');
 $quality_item->{quality}{limits}{'greyscale-21'}={avg=>'1',max=>'1.0'};
 ok(main::_quality_admits_apply(0,$quality_item),'numeric string round trips preserve quality proof');
 $quality_item->{checkpoints}=[{name=>'volume-done',status=>'done',completed_at=>12345}];
 ok(!main::_quality_admits_apply(0,$quality_item),'a new calibration invalidates an older quality proof');
 delete $quality_item->{checkpoints};
 $quality_item->{quality}{limits}{'greyscale-21'}{max}=0.5;
 ok(!main::_quality_admits_apply(0,$quality_item),'changed limits invalidate older acceptance evidence');
 my $calls=0;local *main::_api=sub {$calls++;{status=>'ok'}};
 ok(!main::_apply_all(0,$quality_item),'enforced gate is checked in the actual Apply to All function');
 is($calls,0,'blocked quality sends no TV mutation');
 $quality_item->{quality}{policy}='audit';
 ok(main::_quality_admits_apply(0,$quality_item),'explicit audit policy preserves previous behaviour');
}
done_testing();
