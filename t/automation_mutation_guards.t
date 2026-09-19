# Guards for PR 14 mutations that changed no observable test result (P22).
# Each block pins one production hunk through behaviour a caller can see.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
use PGAutomationLaunch ();
require "$Bin/../usr/share/PGenerator/lg.pm";
my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
my $id='mutation-guards';
{local @ARGV=($id,'guard-token');local $SIG{__WARN__}=sub {};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my $dir=PGAutomation::run_dir($id);
PGAutomation::write_json_atomic("$dir/run.json",{id=>$id,token=>'guard-token',status=>'running',items=>[{}]});
PGAutomation::write_json_atomic("$dir/control.json",{request=>'none'});
PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$id,token=>'guard-token',status=>'running'});
local *main::_log=sub {};local *main::_log_action=sub {};local *main::_sleep_controlled=sub {1};

# F3-a / F3-g / F3-h: once a worker attempt is over, its identity is cleared,
# so the next status read is not held to a stale attempt id.
my $stamped;
sub launch {
 local *main::_api=sub {my ($m,$p,$payload)=@_;$stamped=$payload->{automation_worker_id} if $m eq 'POST';return {status=>'started'};};
 return main::_start_worker('/api/meter/lg-autocal','/api/meter/lg-autocal/status',{});
}
sub unstamped_complete {
 local *main::_api=sub {my ($m,$p)=@_;return {status=>'ok'} if $p eq '/api/lg/status';return {status=>'complete'};};
 return main::_wait_worker('/api/meter/lg-autocal/status','guard',{})->{status}||'';
}
{
 launch();ok($stamped,'a launched worker gets an attempt id');
 is(unstamped_complete(),'error','while the attempt is active an unstamped result is refused');
 main::_clear_active_worker();
 is(unstamped_complete(),'complete','_clear_active_worker clears the attempt id, not only the worker kind (F3-a)');
}
{
 my $item={};
 ok(main::_stage(0,$item,'guard-stage',sub {launch();1}),'a stage that launched a worker completes');
 is(unstamped_complete(),'complete','a finished stage leaves no attempt id behind (F3-g)');
}
{
 local *main::_series_selection=sub {('greyscale-21')};
 local *main::_series_payload=sub {{}};
 local *main::_snapshot_series=sub {{}};
 local *main::_api=sub {
  my ($m,$p,$payload)=@_;
  return {status=>'ok'} if $p eq '/api/lg/status';
  if($m eq 'POST' && $p eq '/api/meter/series'){$stamped=$payload->{automation_worker_id};return {status=>'started'};}
  return {status=>'complete',automation_worker_id=>$stamped};
 };
 ok(main::_run_series(0,{},'pre'),'a series sweep completes');
 is(unstamped_complete(),'complete','a completed sweep clears its attempt id (F3-h)');
}

# F3-n: worker evidence from a different attempt is never archived.
{
 launch();
 my $calibration=PGAutomation::item_dir($id,0).'/calibration';
 ok(!main::_copy_worker_files(0,'grey',{status=>'complete',automation_worker_id=>'another-attempt'}),'a foreign attempt result is refused');
 ok(!-f "$calibration/grey-state.json",'and nothing is written as this job evidence (F3-n)');
 like($::LAST_ERROR,qr/different attempt/,'the refusal is explained');
 ok(main::_copy_worker_files(0,'grey',{status=>'complete',automation_worker_id=>$stamped}),'this attempt own result is archived');
 ok(-f "$calibration/grey-state.json",'as the job grey state');
 main::_clear_active_worker();
}

# F1-e: a limited mode read is never reported as independently verified.
{
 my $limited_reply={status=>'ok',current_input=>'hdmi1',picture_settings=>{pictureMode=>'expert1'},virtual_picture_settings=>JSON::PP::true,
  lg_generation=>{picture_mode_read_forbidden=>JSON::PP::true},
  generation_profile=>{capability_profile_hash=>'a'x64,capability_profile_id=>'x',capability_library_valid=>1,capability_platform_profile_applied=>1}};
 local *main::_api=sub {$limited_reply};
 my $read=main::_preflight_read_mode('sdr',1);
 ok($read->{mode_readback_unavailable},'a read-forbidden TV takes the limited path');
 ok(!$read->{verified},'and its mode read is not marked verified (F1-e)');
 is($read->{picture_mode},'','and no echoed selector is kept as a mode');
 my %readable=%$limited_reply;delete @readable{qw(virtual_picture_settings lg_generation)};
 local *main::_api=sub { return {%readable}; };
 ok(main::_preflight_read_mode('sdr',1)->{verified},'a readable TV read is verified');
}

# H-not-sent-state: an explicit not-sent delivery state is honoured whatever the text.
ok(main::_request_not_sent({status=>'error',delivery_state=>'not-sent',message=>'Panel protection guard refused'}),'delivery_state not-sent marks a request as never sent');
ok(!main::_request_not_sent({status=>'error',delivery_state=>'outcome-unknown',message=>'Unable to connect to LG WebOS TV at x'}),'outcome-unknown is never treated as not sent');
# H-viewing-first-wins: the original viewing context is kept from the first capture.
{
 my $first={config=>{signal_mode=>'sdr'},original=>{picture_mode=>'expert1'},modes=>{sdr=>{picture_mode=>'expert1'}},order=>['sdr']};
 my $later={config=>{signal_mode=>'sdr'},original=>{picture_mode=>'cinema'},modes=>{sdr=>{picture_mode=>'cinema'},hdr10=>{picture_mode=>'hdrCinema'}},order=>['sdr','hdr10']};
 unlink("$dir/viewing-context.json");
 main::_preflight_save_context($first);
 main::_preflight_save_context($later);
 my $viewing=PGAutomation::read_json_file("$dir/viewing-context.json");
 is($viewing->{modes}{sdr}{picture_mode},'expert1','a later preflight never overwrites the first saved mode for a signal');
 is($viewing->{modes}{hdr10}{picture_mode},'hdrCinema','but adds signals it had not seen');
 is_deeply($viewing->{order},['sdr','hdr10'],'in first-seen order');
}
# H-panel-restore-persist: a panel-protection restore that cannot be recorded keeps ownership.
{
 PGAutomation::with_lock("$dir/run.json",sub {$_[0]{panel_protection}={restore_pending=>JSON::PP::true};return $_[0];});
 local *main::_api=sub {{status=>'ok'}};
 local *main::_update_run=sub {undef};
 ok(!eval {main::_restore_panel_protection(PGAutomation::read_json_file("$dir/run.json"));1},'a restore that cannot be persisted does not report success');
 like($@,qr/Unable to persist panel protection restoration/,'and says ownership is retained');
}

# H-atomic-excl: the temporary file is created exclusively, never through a
# pre-planted symlink.
{
 my $dirw=tempdir(CLEANUP=>1);
 my $victim="$dirw/victim.txt";open my $v,'>',$victim or die $!;print {$v} "original\n";close $v;
 no warnings 'redefine';
 local *PGAutomation::_random_hex=sub {'fixedsuffix'};
 my $target="$dirw/state.json";
 symlink($victim,"$target.tmp.$$.fixedsuffix") or die $!;
 ok(!PGAutomation::write_atomic($target,'{"new":1}'),'a pre-planted temporary symlink makes the write fail');
 open $v,'<',$victim or die $!;my $content=do {local $/;<$v>};close $v;
 is($content,"original\n",'and the symlink target is never written through');
}
# H-delete-sync: a locked delete is made durable by syncing the directory.
{
 my $dirw=tempdir(CLEANUP=>1);my $file="$dirw/claim.json";
 PGAutomation::write_json_atomic($file,{a=>1});
 my @synced;my $real=\&PGAutomation::sync_directory;
 no warnings 'redefine';
 local *PGAutomation::sync_directory=sub {push @synced,$_[0];$real->(@_)};
 PGAutomation::with_lock($file,sub {return {__pg_automation_delete=>1};});
 ok(!-e $file,'the locked delete removes the file');
 ok(grep({$_ eq $dirw} @synced),'and syncs its directory');
}
# H-store-chmod: an existing, more permissive store is tightened.
{
 my $loose=tempdir(CLEANUP=>1);chmod 0755,$loose;
 local $ENV{PGEN_AUTOMATION_DIR}=$loose;
 ok(PGAutomation::ensure_store(),'an existing store is accepted');
 is(sprintf('%o',(stat($loose))[2]&07777),'700','and made owner-only');
}
# H-launch-perm / H-launch-attempt: the launch credential journal is trusted
# only when owner-only and for the exact attempt.
{
 my $launch_store=tempdir(CLEANUP=>1);
 local $ENV{PGEN_AUTOMATION_DIR}=$launch_store;PGAutomation::ensure_store();
 my $file=PGAutomation::run_dir('launch-run').'/launch.json';
 PGAutomation::write_json_atomic($file,{run_id=>'launch-run',attempt=>'attempt-1',token=>'launch-token-123'});
 is(PGAutomationLaunch::read_launch_token('launch-run','attempt-1'),'launch-token-123','an owner-only journal for this attempt yields its token');
 is(PGAutomationLaunch::read_launch_token('launch-run','attempt-2'),'','a different attempt gets nothing (H-launch-attempt)');
 chmod 0644,$file;
 is(PGAutomationLaunch::read_launch_token('launch-run','attempt-1'),'','a group- or world-readable journal is refused (H-launch-perm)');
}
# H-guard-status / H-browser-unreadable: unreadable or invalid ownership fails closed.
{
 my $guard_store=tempdir(CLEANUP=>1);
 local $ENV{PGEN_AUTOMATION_DIR}=$guard_store;PGAutomation::ensure_store();
 PGAutomation::write_json_atomic("$guard_store/execution.json",{owner=>'automation',run_id=>'r',token=>'t',status=>'bogus'});
 like(main::lg_automation_guard_json('{}'),qr/automation-state-unreadable/,'an invalid ownership status blocks device writes (H-guard-status)');
 open my $bad,'>',"$guard_store/execution.json" or die $!;print {$bad} "{not json";close $bad;
 like(main::lg_browser_picture_settings_while_automation('{}'),qr/automation-state-unreadable/,'an unreadable ownership file defers browser reads instead of reading the TV (H-browser-unreadable)');
}
done_testing();
