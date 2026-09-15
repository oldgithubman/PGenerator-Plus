use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use POSIX ();
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
my $run={id=>'activity-test',token=>'private-token',readiness=>{checks=>[{time=>123,ok=>1,message=>'Meter detected'},{ok=>0,level=>'warning',message=>'Readback unavailable',item_number=>1}]}};
my $path=PGAutomation::run_dir($run->{id}).'/runner.log';
PGAutomation::append_line_locked($path,"[2026-09-13T10:00:00] Job 1 | Patch 1 / 26\n[2026-09-13T10:00:01] failed private-token client_key=abc token=xyz\npartial");
my $log=main::webui_automation_activity($run,undef);
is(scalar @{$log->{entries}},4,'saved checks and complete runner lines are returned');
is($log->{entries}[0]{time},123,'check timestamps retained');
is($log->{entries}[1]{level},'warning','unverified controls retain severity and job');
is($log->{entries}[1]{item_number},1,'check job identity retained');
is($log->{entries}[2]{time},main::webui_automation_log_time('2026-09-13T10:00:00'),'legacy runner timestamp resolved on the device');
is($log->{entries}[3]{level},'error','failure highlighted');
unlike(PGAutomation::encode_json($log),qr/private-token|abc|xyz|partial/,'secrets and unfinished lines excluded');
ok(!$log->{truncated},'short log is not truncated');
PGAutomation::append_line_locked($path,"\n".join('',map {"[2026-09-13T10:01:00] line $_ ".('x'x300)."\n"} 1..600));
$log=main::webui_automation_activity($run,undef);
ok($log->{truncated},'large log is explicitly truncated');
ok(scalar(@{$log->{entries}})<=302,'entry count is bounded');
like($log->{entries}[-1]{message},qr/line 600 /,'newest complete output is included');
ok(length(PGAutomation::encode_json($log))<100000,'response stays bounded');
PGAutomation::append_line_locked($path,"[2026-09-13T10:02:00] Delta \xce\x94\n");
$log=main::webui_automation_activity($run,undef);
is($log->{entries}[-1]{message},"Delta \x{394}",'UTF-8 decoded once');
PGAutomation::append_line_locked($path,"[2026-09-13T10:02:01] {\"client-key\":\"hidden value\",\"token\":\"hidden-token\"}\n");
unlike(PGAutomation::encode_json(main::webui_automation_activity($run,undef)),qr/hidden/,'quoted credential fields are redacted too');
is_deeply(main::webui_automation_activity({id=>'../escape'},undef)->{entries},[],'path traversal rejected');
is_deeply(main::webui_automation_activity({id=>'missing'},undef)->{entries},[],'missing runner log is an empty history, not borrowed live data');
$log=main::webui_automation_activity(undef,{checks=>[{ok=>1,message=>'Passed'}],issues=>[{message=>'Old warning'}]});
is($log->{entries}[0]{message},'Passed','startup log uses all checks, not just warnings');
my $events=[{time=>100,level=>'info',message=>'Checking TV settings for SDR',item_number=>0,private=>'not-public'}];
$log=main::webui_automation_activity(undef,{events=>$events});
is($log->{entries}[0]{source},'Startup','in-progress startup milestones reach the activity log before a runner exists');
is($log->{entries}[0]{item_number},0,'startup milestone retains job identity');
ok(!exists $log->{entries}[0]{private},'event output is allowlisted');
$log=main::webui_automation_activity({id=>'missing',startup_events=>$events,readiness=>{checks=>[{message=>'Runner recheck passed',ok=>1}]}},undef);
is($log->{entries}[0]{message},'Checking TV settings for SDR','startup milestones survive runner readiness replacement');
is($log->{entries}[1]{message},'Runner recheck passed','latest readiness checks are still included');
$log=main::webui_automation_activity({id=>'missing',items=>[{}, {readiness=>{checks=>[{time=>200,ok=>0,level=>'error',message=>'Meter disconnected',private=>'secret'}]}}]},undef);
is($log->{entries}[0]{source},'Job check','per-job readiness appears in the persisted activity log');
is($log->{entries}[0]{item_number},1,'job check stays attached to its global queue position');
ok(!exists($log->{entries}[0]{private}),'job-check output is allowlisted');
{
 local $ENV{TZ}='Etc/GMT-2';POSIX::tzset();
 is(main::webui_automation_log_time('2026-09-13T16:17:41'),'2026-09-13T14:17:41Z','legacy Pi-local time is converted to UTC, not browser-local time');
 is(main::webui_automation_log_time('2026-09-13T14:17:41Z'),'2026-09-13T14:17:41Z','new UTC timestamps are not shifted twice');
 is(main::webui_automation_log_time('2026-09-13T16:17:41+02:00'),'2026-09-13T16:17:41+02:00','explicit offsets are preserved');
 is(main::webui_automation_log_time('2026-99-13T16:17:41'),undef,'invalid legacy dates cannot invent an event time');
}
POSIX::tzset();
my @severity=(
 ['Job 1 | 1D LUT | sdr26_2.3% | Attempt 7/12 | dE 0.935; target <=1.00; previous best 1.389; requested target 0.50 (near-black allowance active) | Y 0.1050 cd/m2; luminance error +3.8%','info'],
 ['luminance error -30.0%; dE 4.2; target <=0.50','info'],
 ['LUT upload failed | luminance error +3.8%','error'],
 ['daemon request failed; retrying in 2 seconds','warning'],
 ['LG request reported a connection failure; refreshing the pairing (attempt 1)','warning'],
 ['upload failed after retries','error'],
 ['Unable to read meter; retry manually','error'],
 ['Reconnection failed; reconnect manually','error'],
 ['Stop cleanup FAILED: TV did not acknowledge exit; retry manually','error'],
 ['stage greyscale-done interrupted by stop request for item 0','info'],
 ['Workers cancelled; sending TV calibration exit even if no job is active','info'],
 ['runner parked an interrupted run for resume','warning'],
 ['Force stopping meter worker after cancellation grace period','warning'],
 ['Worker activity gap: earlier detail events expired','warning'],
 ['Apply to All Inputs sent - confirmation unavailable on this TV','info'],
 ['TV settings readback: 2/3 matched; warning: some controls cannot be verified - see setting checks','warning'],
 ['No errors; 0 failures','info'],
 ['unable to copy automation artifact','error'],
 ['Stop cleanup complete: calibration mode off','info'],
);
for my $case (@severity){is(main::webui_automation_log_level($case->[0]),$case->[1],$case->[0]);}
done_testing();
