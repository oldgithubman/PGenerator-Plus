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
# A reminder to look at a TV menu the API does not expose is a note, shown but
# not coloured as a problem; a control that could not be verified stays a warning.
{
 my $notes=main::webui_automation_activity({id=>'notes-test',items=>[{readiness=>{checks=>[
  {ok=>0,level=>'warning',name=>'item-0-manual',message=>'TruMotion: verify Off in the TV menu'},
  {ok=>0,level=>'warning',name=>'item-0-hazard-screenSaver',message=>'LG did not expose screenSaver'},
  {ok=>0,level=>'warning',name=>'item-0-panel-protection',message=>'Panel protection will be switched off'},
  {ok=>0,level=>'warning',name=>'item-0-key-colorGamut',message=>'colorGamut: Requested Auto; LG reported Wide'},
  {ok=>0,level=>'error',name=>'item-0-hazard-autoPowerOff',message=>'autoPowerOff could not be read'}]}}]},undef);
 is_deeply([map {$_->{level}} @{$notes->{entries}}],[qw(note note note warning error)],'menu reminders are notes; unverified controls and errors keep their severity');
}
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
# 18 Sep 2026: the feed carries a cursor. A poll that sends it back gets only
# the lines appended since, and what the page holds after appending them is
# what a full read would return.
{
 my $store=tempdir(CLEANUP=>1);local $ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 my $run={id=>'cursor-test',token=>'private',items=>[{readiness=>{checks=>[{time=>1,ok=>0,level=>'warning',message=>'Look at the TV menu'}]}}],startup_events=>[{time=>2,message=>'Queue accepted'}]};
 my $path=PGAutomation::run_dir($run->{id}).'/runner.log';
 PGAutomation::append_line_locked($path,join('',map {"[2026-09-18T10:00:0${_}Z] line $_\n"} 0..4));
 my $full=main::webui_automation_activity($run,undef);
 is($full->{head},2,'the entries that are not from the log come first and are counted');
 like($full->{cursor},qr/^cursor-test:\d+:2\.[0-9a-f]{16}$/,'the cursor names the run, the log offset and a digest of those entries');
 ok(!$full->{partial},'a feed without a cursor is complete');
 my $same=main::webui_automation_activity($run,undef,$full->{cursor});
 ok($same->{partial},'the same cursor gets a partial feed');
 is_deeply($same->{entries},[],'with nothing new');
 is($same->{cursor},$full->{cursor},'and the same cursor');
 is($same->{head},2,'that still counts the entries the page holds');
 PGAutomation::append_line_locked($path,"[2026-09-18T10:00:05Z] line 5\n[2026-09-18T10:00:06Z] private token=abc six\nunfinished");
 my $more=main::webui_automation_activity($run,undef,$full->{cursor});
 is(scalar(@{$more->{entries}}),2,'only the complete lines appended since are returned');
 is($more->{entries}[0]{message},'line 5','in order');
 is($more->{entries}[0]{time},'2026-09-18T10:00:05Z','with their timestamps');
 unlike(PGAutomation::encode_json($more),qr/private|abc|unfinished/,'redacted and without the unfinished line, like a full read');
 my $fresh=main::webui_automation_activity($run,undef);
 is_deeply([@{$full->{entries}},@{$more->{entries}}],$fresh->{entries},'the held feed plus the partial feed is the full feed');
 is($more->{cursor},$fresh->{cursor},'and ends at the same cursor');
 is_deeply(main::webui_automation_activity($run,undef,$more->{cursor})->{entries},[],'an unfinished line is not served early');
 PGAutomation::append_line_locked($path," done\n");
 is(main::webui_automation_activity($run,undef,$more->{cursor})->{entries}[0]{message},'unfinished done','and is served once, complete');
 # Anything the cursor cannot describe is answered with the full feed.
 push @{$run->{startup_events}},{time=>3,message=>'Job 1 started'};
 my $changed=main::webui_automation_activity($run,undef,$more->{cursor});
 ok(!$changed->{partial},'changed startup entries force a full feed');
 is($changed->{head},3,'with the new head');
 is_deeply($changed->{entries},main::webui_automation_activity($run,undef)->{entries},'identical to a fresh read');
 ok(!main::webui_automation_activity({%$run,id=>'other-run'},undef,$changed->{cursor})->{partial},'a cursor for another run forces a full feed');
 ok(!main::webui_automation_activity($run,undef,'garbage')->{partial},'an unreadable cursor forces a full feed');
 my ($rid,$end,$digest)=split(/:/,$changed->{cursor},3);
 ok(!main::webui_automation_activity($run,undef,join(':',$rid,$end+1,$digest))->{partial},'an offset beyond the log (rotated or rewritten) forces a full feed');
 PGAutomation::append_line_locked($path,join('',map {"[2026-09-18T10:01:00Z] bulk $_ ".('x'x80)."\n"} 1..400));
 my $bulk=main::webui_automation_activity($run,undef,$changed->{cursor});
 ok(!$bulk->{partial},'more new lines than the cap forces a full feed');
 ok($bulk->{truncated},'which says it is truncated');
 is(scalar(@{$bulk->{entries}}),3+300,'and holds the head plus the newest 300 lines');
 like($bulk->{entries}[-1]{message},qr/^bulk 400 /,'ending with the newest');
 PGAutomation::append_line_locked($path,join('',map {"[2026-09-18T10:02:00Z] more $_ ".('x'x240)."\n"} 1..300));
 my $beyond=main::webui_automation_activity($run,undef,$bulk->{cursor});
 ok(!$beyond->{partial} && $beyond->{truncated},'more new output than the window holds forces a full feed too');
 is_deeply($beyond->{entries},main::webui_automation_activity($run,undef)->{entries},'the same one a fresh read gives');
 my $tail=main::webui_automation_activity($run,undef,$beyond->{cursor});
 ok($tail->{partial} && $tail->{truncated},'a partial feed of a log beyond the window is marked truncated too');
 is_deeply($tail->{entries},[],'and carries nothing the page already holds');
 # No run: the feed is the startup checks, and the cursor still describes it.
 my $checks=[{ok=>1,message=>'Passed'}];
 my $pre=main::webui_automation_activity(undef,{checks=>$checks});
 like($pre->{cursor},qr/^:0:1\./,'a feed without a run names no run and no log');
 is_deeply(main::webui_automation_activity(undef,{checks=>$checks},$pre->{cursor})->{entries},[],'and its partial feed is empty');
 ok(!main::webui_automation_activity(undef,{checks=>[{ok=>0,message=>'Failed'}]},$pre->{cursor})->{partial},'until the checks change');
 my $unlogged=main::webui_automation_activity({id=>'no-log-yet',items=>[]},undef);
 ok(main::webui_automation_activity({id=>'no-log-yet',items=>[]},undef,$unlogged->{cursor})->{partial},'a run whose log is not written yet gets a partial feed, not a reset');
 # A cursor names a line boundary. The route answers any origin, so a page
 # walking offsets must never be handed a fragment of a line: a fragment of
 # the run token is not the token, and the redaction would not know it.
 my $probe={id=>'probe',token=>'SUPERSECRETTOKEN',items=>[]};
 my $probe_log=PGAutomation::run_dir('probe').'/runner.log';
 PGAutomation::append_line_locked($probe_log,"[2026-09-18T10:00:00Z] token SUPERSECRETTOKEN ok\n[2026-09-18T10:00:01Z] next line\n");
 my $whole=main::webui_automation_activity($probe,undef);
 is($whole->{entries}[0]{message},'token [redacted] ok','the full feed redacts the token');
 my (undef,$boundary,$probe_digest)=split(/:/,$whole->{cursor},3);
 my $served=0;
 for my $offset (1..$boundary) {
  my $reply=main::webui_automation_activity($probe,undef,join(':',$probe->{id},$offset,$probe_digest));
  my $text=PGAutomation::encode_json($reply);
  $served++ if($reply->{partial});
  ok(0,"offset $offset served part of the token") if($text=~/SECRET|TOKEN/);
  ok(0,"offset $offset served a fragment: $reply->{entries}[0]{message}") if($reply->{partial} && @{$reply->{entries}} && $reply->{entries}[0]{message} ne 'next line');
 }
 my $first_line=length("[2026-09-18T10:00:00Z] token SUPERSECRETTOKEN ok\n");
 is($served,2,'only the two line boundaries (after each line) are served as partial feeds; every other offset gets the full, redacted feed');
 ok(main::webui_automation_activity($probe,undef,join(':',$probe->{id},$first_line,$probe_digest))->{partial},'the boundary after the first line is one of them');
 # The live view keeps only a job's failing checks; the manifest keeps all.
 # The poll reads whichever is newer, so the feed, and the cursor's digest of
 # its head, must come out the same from either.
 my $manifest={id=>'both-views',items=>[{name=>'A',readiness=>{checks=>[{time=>1,ok=>1,message=>'Meter idle'},{time=>2,ok=>0,level=>'warning',message=>'TruMotion: verify Off'}]}}],readiness=>{checks=>[{time=>3,ok=>1,message=>'Queue accepted'}]}};
 my $from_manifest=main::webui_automation_activity($manifest,undef);
 my $from_live=main::webui_automation_activity(PGAutomation::compact_run($manifest),undef);
 is_deeply($from_live->{entries},$from_manifest->{entries},'the feed is the same from the live view and the manifest');
 is($from_live->{cursor},$from_manifest->{cursor},'and so is the cursor');
 ok(main::webui_automation_activity(PGAutomation::compact_run($manifest),undef,$from_manifest->{cursor})->{partial},'so a daemon-side manifest write does not reset the feed');
 is_deeply([map {$_->{message}} grep {$_->{source} eq 'Job check'} @{$from_manifest->{entries}}],['TruMotion: verify Off'],'job checks in the feed are those that need a look');
}
done_testing();
