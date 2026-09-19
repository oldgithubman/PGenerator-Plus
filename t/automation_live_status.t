use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";

# 18 Sep 2026: a six-job batch's manifest reached 712 KB (six copies of a
# 52 KB TV capability catalogue, the same copy again in each job's setup
# evidence, 66 KB of preflight checks). JSON::PP on the appliance decoded it
# for every status poll and the runner re-encoded it every few seconds, so
# the daemon sat at 99% CPU, polls took 6 to 13 s and the page said
# "Connection lost". The runner now publishes a compact status.json that the
# daemon serves instead, heartbeats and progress ticks touch only that file,
# and the catalogues never enter the manifest.
my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
my $run_id='live-status';my $dir=PGAutomation::run_dir($run_id);my $run_file="$dir/run.json";my $status_file="$dir/status.json";
{local @ARGV=($run_id,'live-token');local $SIG{__WARN__}=sub {};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
local *main::_log=sub {};
my $catalogue={settings_capabilities=>{brightness=>{min=>0,max=>100,filler=>'x'x4000}},picture_mode_catalogue=>[map {{id=>"mode$_",label=>'m'x40}} 1..40],
 capability_profile_hash=>'a'x64,capability_profile_id=>'fixture',capability_library_valid=>1,capability_platform_profile_applied=>1};
my $items=[
 {name=>'SDR Filmmaker',signal_format=>'sdr',picture_mode=>'filmMaker',status=>'running',generation_profile=>$catalogue,setting_contracts=>{contrast=>'c'x3000},
  readiness=>{ready=>1,scope=>'queue-preflight',checks=>[{ok=>1,message=>'Meter is idle'},{ok=>0,level=>'warning',message=>'TruMotion: verify Off'}]},
  checkpoints=>[{name=>'tv-setup-verified',status=>'done',verified=>1,completed_at=>1,duration_seconds=>9,evidence=>{panel_protection=>{generation_profile=>$catalogue}}}]},
 {name=>'HDR10 Filmmaker',signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',status=>'queued'}];
PGAutomation::write_json_atomic($run_file,{id=>$run_id,token=>'live-token',launch_attempt=>'a1',status=>'running',items=>$items,queue_revision=>0,active_item=>0,active_stage=>'tv-setup-verified',
 preflight_result=>{ready=>1,message=>'All 2 pending jobs passed live preflight.',jobs=>[{name=>'SDR Filmmaker',status=>'checked'},{name=>'HDR10 Filmmaker',status=>'checked'}],checks=>[map {{ok=>1,message=>"check $_"}} 1..80]},
 readiness=>{checks=>[{ok=>1,message=>'Queue contains items'}]}});
PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$run_id,token=>'live-token',status=>'running',pid=>$$,launch_attempt=>'a1'});
my $status=sub {PGAutomation::read_json_file($status_file)};

ok(main::_update_run(sub {$_[0]{worker_status}={message=>'Applying contrast'};}),'a manifest write succeeds');
my $live=$status->();
ok(ref($live) eq 'HASH','every manifest write publishes status.json');
is($live->{worker_status}{message},'Applying contrast','with the state the manifest just took');
is($live->{status},'running','and the run status');
is($live->{items}[0]{name},'SDR Filmmaker','jobs are listed');
ok(!exists($live->{items}[0]{generation_profile}),'without the TV capability profile');
ok(!exists($live->{items}[0]{setting_contracts}),'or setting contracts');
ok(!exists($live->{items}[0]{checkpoints}[0]{evidence}),'or checkpoint evidence');
is($live->{items}[0]{checkpoints}[0]{name},'tv-setup-verified','while checkpoints themselves are listed');
is(scalar(@{$live->{items}[0]{readiness}{checks}}),1,'only the readiness checks that need a look travel');
ok(!exists($live->{preflight_result}{checks}),'the whole-queue check list stays in the plan');
is($live->{preflight_result}{message},'All 2 pending jobs passed live preflight.','its verdict does not');
cmp_ok(-s $status_file,'<',(-s $run_file)/4,'the live status is a fraction of the manifest');

# Fast path: liveness and progress never rewrite the manifest.
my $raw=PGAutomation::read_raw($run_file);
main::_heartbeat();
is(PGAutomation::read_raw($run_file),$raw,'a routine heartbeat leaves the manifest untouched');
ok($status->()->{heartbeat}>0,'and stamps the live status');
is($status->()->{runner_pid},$$,'with the runner pid the daemon checks for liveness');
main::_update_live(sub {$_[0]{operation_progress}={stage=>'tv-setup-verified',completed=>3,total=>18,unit=>'settings',message=>'Applying gamma (4/18)'};});
is(PGAutomation::read_raw($run_file),$raw,'a progress tick leaves the manifest untouched');
is($status->()->{operation_progress}{message},'Applying gamma (4/18)','and reaches the live status');
is($status->()->{worker_status}{message},'Applying contrast','without losing what the manifest said');
main::_update_run(sub {delete $_[0]{operation_progress};$_[0]{worker_status}={message=>'Settled'};});
ok(!defined($status->()->{operation_progress}),'a manifest write is the latest word, including a deletion');
is($status->()->{worker_status}{message},'Settled','and its values');
main::_heartbeat(1);
is(PGAutomation::read_json_file($run_file)->{runner_pid},$$,'a forced heartbeat (start, resume) still reaches the manifest');
{
 # A manifest write minutes after the last forced heartbeat must not roll the
 # live heartbeat back to it, or the card would say "Updates delayed".
 my $fresh=$status->()->{heartbeat};
 PGAutomation::with_lock($run_file,sub {$_[0]{heartbeat}=$fresh-600;return $_[0];});
 main::_update_run(sub {$_[0]{checkpoint}='pre-readings-done';});
 cmp_ok($status->()->{heartbeat},'>=',$fresh,'a manifest write never rolls the live heartbeat back');
 # The daemon edits the manifest too (queue edit while running). The next
 # tick must republish from it, not from the copy taken before.
 PGAutomation::with_lock($run_file,sub {push @{$_[0]{items}},{name=>'DV Filmmaker',status=>'queued'};$_[0]{queue_revision}=1;return $_[0];});
 main::_update_live(sub {$_[0]{heartbeat}=time();});
 is(scalar(@{$status->()->{items}}),3,'a tick after a daemon edit republishes the edited manifest');
 is($status->()->{queue_revision},1,'with its revision');
 main::_update_run(sub {$_[0]{completed_at}=1234;});
 is($status->()->{completed_at},1234,'the completion time reaches the live status');
}

# Daemon side: the status poll reads the live status, never the manifest.
my $view=main::webui_automation_read_live($run_id);
is($view->{worker_status}{message},'Settled','the daemon serves the live status');
ok(!exists($view->{items}[0]{generation_profile}),'as published');
PGAutomation::with_lock($run_file,sub {$_[0]{status}='paused';return $_[0];});
is(main::webui_automation_read_live($run_id)->{status},'paused','a manifest the daemon wrote later wins until the runner republishes');
main::_update_run(sub {$_[0]{worker_status}={message=>'Resumed'};});
my $republished=main::webui_automation_read_live($run_id);
is($republished->{status},'paused','the republished status carries the manifest state');
is($republished->{worker_status}{message},'Resumed','and the runner\'s latest word');
my $copy=PGAutomation::read_json_cached($status_file);$copy->{worker_status}{message}='mutated';
is(PGAutomation::read_json_cached($status_file)->{worker_status}{message},'Resumed','cached reads hand out copies');
main::_update_live(sub {$_[0]{worker_status}={message=>'Fresh'};});
is(PGAutomation::read_json_cached($status_file)->{worker_status}{message},'Fresh','and notice every rewrite');
{
 local $PGAutomation::JSON_CACHE_MAX_BYTES=64;
 is(PGAutomation::read_json_cached($status_file)->{worker_status}{message},'Fresh','a file over the cache limit is still read');
 main::_update_live(sub {$_[0]{worker_status}={message=>'Fresher'};});
 is(PGAutomation::read_json_cached($status_file)->{worker_status}{message},'Fresher','and never served stale');
}
{
 # The cache is bounded by bytes held; the least recently used entries go first.
 local $PGAutomation::JSON_CACHE_BUDGET_BYTES=(-s $status_file)+(-s $run_file)-1;
 my $a=PGAutomation::read_json_cached($run_file);
 my $b=PGAutomation::read_json_cached($status_file);
 ok(ref($a) eq 'HASH' && ref($b) eq 'HASH','both files read under a budget that cannot hold both');
 is(PGAutomation::read_json_cached($status_file)->{worker_status}{message},'Fresher','the most recent stays cached and correct');
 PGAutomation::with_lock($run_file,sub {$_[0]{checkpoint}='budget-check';return $_[0];});
 is(PGAutomation::read_json_cached($run_file)->{checkpoint},'budget-check','an evicted file is re-read from disk when asked again');
 main::_update_live(sub {$_[0]{worker_status}={message=>'Fresher'};});
}
{
 # The job detail the tabs poll every few seconds reads the manifest through the cache.
 my $detail=main::webui_automation_job_detail($run_id,0);
 is($detail->{item}{name},'SDR Filmmaker','job detail still serves the item');
 is($detail->{item}{checkpoints}[0]{name},'tv-setup-verified','with its full checkpoint record');
}
{
 local *main::webui_automation_reap_dead_runner=sub {0};
 my $poll=PGAutomation::decode_json(main::webui_automation_api('/api/automation/runs/current','GET',''));
 is($poll->{run}{worker_status}{message},'Fresher','the status poll reflects the live status');
 ok(!exists($poll->{run}{preflight_result}{checks}),'and carries no check list');
 is(scalar(@{$poll->{run}{items}[0]{readiness}{checks}}),1,'only checks needing a look per job');
 is($poll->{run}{items}[0]{readiness}{checks}[0]{message},'TruMotion: verify Off','the right one');
 ok(!grep({/settings_capabilities|picture_mode_catalogue/} PGAutomation::encode_json($poll)),'no capability catalogue in the poll');
}
my $public=main::webui_automation_public_run(main::webui_automation_read_run($run_id),undef);
ok(!exists($public->{preflight_result}{checks}),'the manifest fallback trims the check list too');
is(scalar(@{$public->{items}[0]{readiness}{checks}}),1,'and the passing checks');

# A daemon-side manifest write absorbs the live fields and retires the live
# status, so its write is the newest word whatever the clock says.
{
 main::_update_live(sub {$_[0]{heartbeat}=time();$_[0]{worker_status}={message=>'Reading 40%'};});
 my $live_heartbeat=$status->()->{heartbeat};
 my ($ok,$written)=main::webui_automation_with_manifest($run_id,sub {my ($run)=@_;$run->{status}='stopping';$run->{stop_requested_at}=time();return $run;});
 ok($ok,'the daemon writes the manifest');
 is($written->{heartbeat},$live_heartbeat,'absorbing the runner\'s latest heartbeat');
 is($written->{worker_status}{message},'Reading 40%','and its progress, so a control reply is current');
 ok(!-e $status_file,'and retires the live status');
 is(main::webui_automation_read_live($run_id)->{status},'stopping','the poll serves the daemon\'s write');
 # Even with a clock that ran backwards (fake-hwclock after a power cut).
 main::_update_live(sub {$_[0]{heartbeat}=time();});
 ok(-e $status_file,'the runner republishes on its next tick');
 utime(time()+3600,time()+3600,$status_file);
 my ($ok2)=main::webui_automation_write_locked($run_file,{%{PGAutomation::read_json_file($run_file)},status=>'interrupted',runner_pid=>0});
 ok($ok2,'boot recovery rewrites the manifest');
 ok(!-e $status_file,'a live status stamped in the future is retired all the same');
 is(main::webui_automation_read_live($run_id)->{status},'interrupted','so a dead run is never reported as running');
 main::_update_live(sub {$_[0]{heartbeat}=time();});
 is($status->()->{status},'interrupted','and the runner\'s next tick republishes from the rewritten manifest');
 # A daemon write that lands inside the instant between the runner's own
 # write and its stat leaves the manifest with the mtime the runner recorded.
 # The retired status file still tells the next tick to re-read.
 my $recorded=PGAutomation::file_mtime($run_file);
 my ($ok3)=main::webui_automation_write_locked($run_file,{%{PGAutomation::read_json_file($run_file)},status=>'stopped'});
 ok($ok3 && !-e $status_file,'the daemon wrote and retired the live status');
 utime($recorded,$recorded,$run_file);
 main::_update_live(sub {$_[0]{heartbeat}=time();});
 is($status->()->{status},'stopped','a tick re-reads the manifest whenever the live status was retired, whatever the mtime says');
 main::_update_live(sub {$_[0]{worker_timing}={recent_point_seconds=>[3,4]};});
 ok(!exists($status->()->{worker_timing}),'only the live keys ride the live status');
 # Dead-runner recovery (the reaper, boot recovery) is a daemon write too.
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='running';$_[0]{runner_pid}=999999;return $_[0];});
 main::_update_live(sub {$_[0]{heartbeat}=time();$_[0]{runner_pid}=999999;});
 utime(time()+3600,time()+3600,$status_file);
 ok(main::webui_automation_recover_run($run_id,'runner-died','The automation runner stopped unexpectedly'),'a dead runner is recovered');
 ok(!-e $status_file,'and its orphaned live status is retired');
 is(main::webui_automation_read_live($run_id)->{status},'interrupted','so the poll reports the recovery, not the orphan');
}

# A finished run has no runner to publish for it. The first poll decodes its
# manifest once and materialises the live view; later polls read that.
{
 main::webui_automation_retire_live($run_id);
 ok(!-e $status_file,'no live status for the finished run');
 my $view=main::webui_automation_read_live($run_id);
 is($view->{status},'interrupted','the poll still answers from the manifest');
 ok(-e $status_file,'and leaves a materialised live status behind');
 my $materialised=PGAutomation::read_json_file($status_file);
 ok($materialised->{materialised_at}>0,'marked as the daemon\'s copy');
 ok(!exists($materialised->{items}[0]{generation_profile}),'compact like the runner\'s');
 cmp_ok(-s $status_file,'<',(-s $run_file)/4,'and a fraction of the manifest');
 my ($ok4)=main::webui_automation_write_locked($run_file,{%{PGAutomation::read_json_file($run_file)},live_view_cleared_at=>time()});
 ok($ok4 && !-e $status_file,'a later daemon write retires it again');
 is(main::webui_automation_read_live($run_id)->{live_view_cleared_at}>0?1:0,1,'and the next poll sees the write');
 PGAutomation::with_lock($run_file,sub {$_[0]{status}='running';return $_[0];});
 main::webui_automation_retire_live($run_id);
 main::webui_automation_read_live($run_id);
 ok(!-e $status_file,'a run the daemon believes is running is never materialised by the daemon');
}

# The catalogues never enter a job.
my $slim=main::_slim_profile($catalogue);
ok(!exists($slim->{settings_capabilities}) && !exists($slim->{picture_mode_catalogue}),'a job keeps the profile without the catalogues');
is($slim->{capability_profile_hash},'a'x64,'and keeps what identifies the TV');
is($catalogue->{capability_profile_id},'fixture','the caller\'s copy is not changed');
done_testing();
