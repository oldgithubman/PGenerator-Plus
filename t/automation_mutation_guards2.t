# More guards for PR 14 mutations that changed no observable test result (P22).
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Handle;
use IO::Socket::INET;
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";
my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
my $id='guards-two';
{local @ARGV=($id,'guard-token');local $SIG{__WARN__}=sub {};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my $dir=PGAutomation::run_dir($id);
sub reset_run {
 PGAutomation::write_json_atomic("$dir/run.json",{id=>$id,token=>'guard-token',status=>'running',items=>[{}],@_});
 PGAutomation::write_json_atomic("$dir/control.json",{request=>'none'});
}
reset_run();
*main::_log=sub {};*main::_log_action=sub {};*main::_sleep_controlled=sub {1};

# H-problems-hazard / H-problems-viewing
ok(@{PGAutomation::restoration_problems({hazard_restore_pending=>1})},'a pending protective restore is a restoration problem');
ok(@{PGAutomation::restoration_problems({viewing_restore_required=>1})},'a pending viewing restore is a restoration problem');

# Job runner with every device stage stubbed: records the stage order.
my (@stages,@points);
sub run_item {
 my ($item,%run)=@_;
 reset_run(%run);
 @stages=();@points=();
 local *main::_prepare_job_context=sub {1};
 local *main::_prepare_resume=sub {1};
 local *main::_restore_profile_baseline=sub {1};
 local *main::_apply_and_verify=sub {push @points,$_[2];1};
 local *main::_panel_protection_disable=sub {push @points,'panel-protection';1};
 local *main::_stage=sub {push @stages,$_[2];1};
 local *main::_skip_stage=sub {push @stages,'skip:'.$_[2];1};
 local *main::_pause_after_checkpoint=sub {0};
 local *main::_checkpoint_record=sub {{}};
 local *main::_update_item_snapshot=sub {1};
 return main::_run_item(0,$item);
}
# H-quality-order: enforced quality applies to all inputs only after After Readings.
{
 my $base={signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>1,apply_all=>1,post_readings=>1}};
 run_item({%$base,quality=>{enabled=>1,policy=>'enforce'}});
 my %at=map {$stages[$_]=>$_} 0..$#stages;
 ok(exists $at{'apply-all-done'} && exists $at{'post-readings-done'} && $at{'apply-all-done'}>$at{'post-readings-done'},'enforced quality runs Apply to All Inputs after After Readings');
 is(scalar(grep {$_ eq 'apply-all-done'} @stages),1,'exactly once');
 run_item({%$base,quality=>{enabled=>1,policy=>'audit'}});
 %at=map {$stages[$_]=>$_} 0..$#stages;
 ok($at{'apply-all-done'}<$at{'post-readings-done'},'audit quality keeps Apply to All Inputs before After Readings');
}
# H-resume-context: resuming a job after a released pause recreates its device state.
{
 run_item({signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>0},checkpoints=>[{name=>'item-started',status=>'done'}]},pause_context_released=>JSON::PP::true);
 ok(grep({$_ eq 'resume-setup'} @points),'resume re-applies the job settings');
 ok(grep({$_ eq 'panel-protection'} @points),'and disables panel protection again');
}
# H-hazard-pending-set: a job that changes a protective setting journals the obligation.
{
 reset_run();
 local *main::_apply_signal=sub {1};
 local *main::_freeze_job_lg_context=sub {{}};
 local *main::_select_item_picture_mode=sub {1};
 # The hazard values come from the whole-queue check's readiness pass, kept on the item.
 eval { main::_prepare_job_context(0,{signal_format=>'sdr',picture_mode=>'filmMaker',hazards=>[{key=>'autoPowerOff',value=>'on',category=>'power',controllable=>1}]}) };
 ok(PGAutomation::read_json_file("$dir/run.json")->{hazard_restore_pending},'hazard_restore_pending is journalled at job start');
}
# H-quality-missing / H-quality-nolimits
{
 my $reading=sub {{name=>$_[0],X=>95.047,Y=>100,Z=>108.883,target_x=>0.3127,target_y=>0.329,custom_target_nits=>100,series_target_white_y=>100}};
 my $item={post_series=>['greyscale-21'],quality=>{enabled=>1,policy=>'audit',limits=>{'greyscale-21'=>{avg=>1,max=>2}}}};
 my $write=sub {PGAutomation::write_json_atomic(PGAutomation::item_dir($id,0).'/post/greyscale-21.json',$_[0]);};
 $write->({status=>'complete',steps=>[{},{}],readings=>[$reading->('a'),$reading->('b')]});
 my $ok=main::_quality_stage(0,$item);
 ok(defined $ok->{series}{'greyscale-21'}{passed},'a complete series with limits is judged');
 $write->({status=>'running',steps=>[{},{}],readings=>[$reading->('a'),$reading->('b')]});
 my $partial=main::_quality_stage(0,$item);
 ok($partial->{series}{'greyscale-21'}{missing_readings}>0,'an incomplete series counts as missing readings');
 ok(!defined $partial->{series}{'greyscale-21'}{passed},'and is not judged passed or failed');
 $write->({status=>'complete',steps=>[{},{}],readings=>[$reading->('a'),$reading->('b')]});
 my $nolimits=main::_quality_stage(0,{%$item,quality=>{enabled=>1,policy=>'enforce',limits=>{}}});
 ok($nolimits->{series}{'greyscale-21'}{missing_readings}>0,'enforced quality without limits cannot pass silently');
}
# H-quality-readiness: enforced quality needs checks enabled and After Readings.
{
 local *main::webui_meter_status=sub {'{"detected":1}'};
 local *main::webui_meter_series_alive=sub {0};local *main::webui_meter_lg_autocal_running=sub {0};
 local *main::webui_meter_lg_3d_autocal_running=sub {0};local *main::webui_meter_lg_dv_profile_running=sub {0};local *main::webui_meter_session_alive=sub {0};
 my $r=main::webui_automation_readiness_data({static_only=>1,items=>[{name=>'Q',signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>1,apply_all=>1,post_readings=>0},quality=>{enabled=>0,policy=>'enforce'}}]});
 ok(!$r->{ready},'enforced quality without checks or After Readings is not ready');
 ok(grep({($_->{name}||'') eq 'item-0-quality-stages' && !$_->{ok}} @{$r->{checks}}),'and names the missing prerequisite');
}
# H-cache-virtual / H-cache-clear-current
{
 my $lgdir=tempdir(CLEANUP=>1);$main::var_dir=$lgdir;mkdir "$lgdir/lg";
 my $response=sub {{status=>'ok',current_input=>'hdmi4',picture_settings=>{pictureMode=>'filmMaker',contrast=>85},
  generation_profile=>{capability_profile_hash=>'a'x64},supported_picture_keys=>['contrast','pictureMode'],@_}};
 my $payload=JSON::PP::encode_json({picture_mode=>'filmMaker',signal_mode=>'sdr',category=>'picture'});
 main::lg_remember_picture_settings(JSON::PP::encode_json($response->()),$payload);
 ok(main::lg_read_picture_settings_cache()->{current},'a coherent live read becomes the current context');
 main::lg_remember_picture_settings(JSON::PP::encode_json($response->(virtual_picture_settings=>JSON::PP::true)),$payload);
 ok(!main::lg_read_picture_settings_cache()->{current},'a virtual response is not cached and clears the current pointer');
}
# H-worker-config-0600: every worker configuration file is written owner-only.
# Each write to a worker configuration path is matched whatever its argument
# list, so a dropped or widened mode fails (a missing mode means 0664).
{
 open my $fh,'<',"$Bin/../usr/share/PGenerator/webui.pm" or die $!;my $source=do {local $/;<$fh>};close $fh;
 my %writes;
 while($source=~/write_atomic\(\s*\$(_meter_\w*config_file)\s*,([^;]*?)\)\s*\)?\s*;/g) {
  my ($file,$args)=($1,$2);
  my @parts=split /\s*,\s*/,$args;
  push @{$writes{$file}},(@parts>=2 ? $parts[-1] : 'default');
 }
 ok(exists $writes{_meter_lg_autocal_config_file},'the LG AutoCal worker configuration write is found');
 ok(exists $writes{_meter_lg_3d_autocal_config_file},'the 3D AutoCal worker configuration write is found');
 is_deeply([grep {$_ ne '0600'} map {@$_} values %writes],[],'every worker configuration write passes mode 0600');
 my @other=$source=~/open\s*\(\s*(?:my\s+)?\$\w+\s*,\s*['"]>{1,2}['"]\s*,\s*\$_meter_\w*config_file/g;
 is(scalar(@other),0,'and none is written by a plain open that ignores the mode');
}
# H-http-listener / H-http-503 call sites: the accept loop uses both helpers,
# and the queue-limit branch never writes a reply itself.
{
 open my $fh,'<',"$Bin/../usr/share/PGenerator/webui.pm" or die $!;my $source=do {local $/;<$fh>};close $fh;
 my ($accept)=$source=~/^(sub webui_http \(\@\) \{.*?^\})/ms;
 ok($accept,'the accept loop is found');
 like($accept,qr/&webui_http_prepare_listener\(\$http_server\);/,'the listener is prepared before accepting');
 my ($shed)=$accept=~/(if\(\$queue->pending\(\) >= \$queue_max\) \{.*?\n   \})/s;
 ok($shed,'the queue-limit branch is found');
 like($shed,qr/&webui_http_shed_request\(\$h\);/,'it replies through the non-blocking helper');
 unlike($shed,qr/\b(?:print|syswrite)\b/,'and never writes the 503 itself');
}
# H-quality-result-name: saved quality results never overwrite the job's quality recipe.
{
 my $run_id='quality-name';
 PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/run.json',{id=>$run_id,token=>'t',status=>'complete',items=>[{name=>'J',quality=>{enabled=>1,policy=>'audit'}}]});
 PGAutomation::write_json_atomic(PGAutomation::item_dir($run_id,0).'/quality.json',{enabled=>1,series=>{'greyscale-21'=>{passed=>1}}});
 my $run=main::webui_automation_run($run_id,0);
 is($run->{items}[0]{quality}{policy},'audit','the job quality recipe is kept');
 ok($run->{items}[0]{quality_result}{series},'the saved result is exposed as quality_result');
}
# H-dv-state-atomic: the DV profile worker publishes its state atomically.
{
 open my $fh,'<',"$Bin/../usr/bin/meter_lg_dv_profile.pl" or die $!;my $source=do {local $/;<$fh>};close $fh;
 my ($sub)=$source=~/^(sub write_state \{.*?^\})/ms;die 'write_state not found' if !$sub;
 my @published;
 local *PGAutomation::write_json_atomic=sub {push @published,$_[0];1};
 eval 'package main; {my $state_file=q{'.$store.'/dv-state.json};my $config={};'.$sub.'} 1' or die $@;
 main::write_state(status=>'running');
 # The state file first, then the automation poller's summary sidecar.
 is_deeply(\@published,["$store/dv-state.json","$store/dv-state.json.summary"],'write_state publishes the state and its summary sidecar through write_json_atomic');
}
# H-http-listener / H-http-503
{
 my $server=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>5,ReuseAddr=>1,Proto=>'tcp');
 SKIP: {
  skip 'loopback listener unavailable',1 if !$server;
  main::webui_http_prepare_listener($server);
  ok(!$server->blocking,'the listener is non-blocking before the accept loop');
 }
 socketpair(my $client,my $peer,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die $!;
 $client->blocking(0);
 my $chunk='x'x65536;1 while defined(syswrite($client,$chunk));
 $client->blocking(1);
 # The reply's own eval swallows a die from the alarm, so record the timeout
 # in a flag instead of relying on the die reaching this eval.
 my $blocked=0;
 my $returned=eval {local $SIG{ALRM}=sub {$blocked=1;die "blocked\n"};alarm 3;main::webui_http_shed_request($client);alarm 0;1};
 alarm 0;
 ok($returned && !$blocked,'an overload reply to a client that never reads cannot block the accept thread');
}
# H-argv-token: the runner command line never carries the run token. The
# launch file's own process check reads /proc (Linux only), so exercise the
# spawn argv and the cmdline matcher directly; both run on any platform.
{
 require PGAutomationLaunch;
 my $dir=File::Temp::tempdir(CLEANUP=>1);
 my $record="$dir/argv.txt";
 my $fake="$dir/fake-runner.pl";
 open(my $fh,'>',$fake) or die $!;
 print {$fh} "open(my \$o,'>','$record.tmp') or die;print {\$o} join(\"\\n\",\@ARGV);close(\$o);rename('$record.tmp','$record');\n";
 close($fh);
 # macOS has no setsid command; a pass-through shim keeps the real shell path.
 open(my $shim,'>',"$dir/setsid") or die $!;print {$shim} "#!/bin/sh\nexec \"\$\@\"\n";close($shim);chmod(0755,"$dir/setsid");
 local $ENV{PATH}="$dir:$ENV{PATH}";
 local $PGAutomationLaunch::PERL_PATH=$^X;
 local $PGAutomationLaunch::RUNNER_PATH=$fake;
 my $token='secret-token-abcdef123';
 my $pid=PGAutomationLaunch::_spawn_runner('run-argv',$token,'attempt-1',"$dir/runner.log");
 ok($pid>1,'the runner spawn reports a process id');
 for (1..100) {last if -f $record;select(undef,undef,undef,0.05);}
 my $argv=do {local(@ARGV,$/)=($record);-f $record ? <> : ''};
 is($argv,"run-argv\n--launch\nattempt-1",'the runner is started with the run id, --launch and the attempt only');
 unlike($argv,qr/\Q$token\E/,'the token never appears on the command line');
 no warnings 'redefine';
 my $cmdline;
 local *PGAutomation::read_raw=sub {$cmdline};
 $cmdline=join("\0",$^X,$fake,'run-argv','--launch','attempt-1');
 ok(PGAutomationLaunch::_live_attempt_pid(4242,'run-argv',$token,'attempt-1'),'a process started with --launch is recognised as the attempt');
 $cmdline=join("\0",$^X,$fake,'run-argv',$token,'attempt-1');
 ok(!PGAutomationLaunch::_live_attempt_pid(4242,'run-argv',$token,'attempt-1'),'a command line carrying the token is not the production launch shape');
}
done_testing();
