use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Time::HiRes ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";

# 18 Sep 2026: every 2 s status poll answered with 163 KB, of which 78 KB
# was the whole-queue check result (identical for the life of the run) and
# 81 KB the activity feed rebuilt from the runner log. A poll that names the
# check revision and the activity cursor it already holds gets back only
# what changed; a poll without them gets the full reply as before.
my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
local *main::webui_automation_reap_dead_runner=sub {0};
my $id='poll-delta';my $dir=PGAutomation::run_dir($id);
my @checks=map { my $n=$_; {ok=>($n%9?1:0),level=>'warning',name=>"check-$n",message=>"Setting $n verified against the TV ".('detail 'x6),item_number=>$n%6,time=>1000+$n} } 1..362;
my @items=map { my $n=$_; {name=>"Job $n",signal_format=>'sdr',status=>$n==0?'running':'queued',readiness=>{checks=>[grep {$_->{item_number}==$n} @checks]}} } 0..5;
my $write_run=sub {
 my ($run_id,%extra)=@_;
 PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/run.json',{id=>$run_id,token=>'tok',status=>'running',active_item=>0,active_stage=>'greyscale-done',stage_started_at=>time(),
  items=>\@items,startup_events=>[map {{time=>2000+$_,message=>"Startup step $_",level=>'info'}} 1..20],readiness=>{checks=>\@checks},%extra});
 PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$run_id,token=>'tok',status=>'running',pid=>$$});
};
$write_run->($id);
my $preflight={id=>$id,run_id=>$id,status=>'started',intent=>'start',scope=>'queue',started_at=>1000,completed_at=>1500,updated_at=>1500,message=>'All 6 jobs passed',
 checks=>\@checks,issues=>[grep {!$_->{ok}} @checks],items=>[map {{name=>"Job $_",status=>'checked'}} 0..5],total_items=>6};
PGAutomation::write_json_atomic("$store/preflight.json",$preflight);
PGAutomation::append_line_locked("$dir/runner.log",join('',map {"[2026-09-18T10:00:00Z] Job 1 | 1D LUT | patch $_ | dE 0.4 ".('x'x120)."\n"} 1..400));
my $escape=sub { my $v=shift;$v=~s/([^A-Za-z0-9._~-])/sprintf('%%%02X',ord($1))/ge;return $v };
my $poll=sub { PGAutomation::decode_json(main::webui_automation_api('/api/automation/runs/current','GET','',@_)) };
my $query=sub { my ($reply)=@_;return 'preflight_rev='.$escape->($reply->{preflight}{rev}).'&activity_after='.$escape->($reply->{activity}{cursor}) };

my $first=$poll->();
ok(ref($first->{preflight}) eq 'HASH' && $first->{preflight}{rev},'the first poll carries the check list with a revision');
ok($first->{activity}{cursor} && !$first->{activity}{partial},'and the complete activity feed with a cursor');
ok(!exists($first->{preflight_unchanged}) && !exists($first->{activity_reset}),'a poll without a revision or cursor is the reply as before');
cmp_ok(length(PGAutomation::encode_json($first)),'>',100000,'the full reply is over 100 KB');
is(scalar(@{$first->{activity}{entries}}),scalar(grep {!$_->{ok}} @checks)+20+scalar(@checks)+300,'failing job checks, startup events, startup checks and the newest 300 log lines');
is($first->{run}{items}[0]{signal_format},'sdr','a live job row names its signal, which the page uses to explain that job\'s failure');

my $second=$poll->($query->($first));
ok($second->{preflight_unchanged},'a poll naming the revision it holds is told the check list is unchanged');
ok(!exists($second->{preflight}),'and does not receive it again');
ok($second->{activity}{partial},'the activity feed is partial');
is_deeply($second->{activity}{entries},[],'with nothing new');
is($second->{activity}{run_id},$id,'and still names the run');
is($second->{activity}{cursor},$first->{activity}{cursor},'with the same cursor');
ok(!$second->{activity_reset},'and no reset');
is($second->{run}{id},$id,'the run itself still travels');
cmp_ok(length(PGAutomation::encode_json($second)),'<',20000,'a steady-state poll is under 20 KB ('.length(PGAutomation::encode_json($second)).')');

PGAutomation::append_line_locked("$dir/runner.log","[2026-09-18T10:05:00Z] Job 1 | 1D LUT | patch 401\n");
my $third=$poll->($query->($first));
is(scalar(@{$third->{activity}{entries}}),1,'a new line arrives on its own');
is($third->{activity}{entries}[0]{message},'Job 1 | 1D LUT | patch 401','as the page would see it');
my $fresh=$poll->();
my @merged=(@{$first->{activity}{entries}},@{$third->{activity}{entries}});
my $head=$first->{activity}{head};
splice(@merged,$head,scalar(@merged)-$head-300) if(@merged-$head>300);
is_deeply(\@merged,$fresh->{activity}{entries},'the feed the page holds after appending equals a full read');
is($third->{activity}{cursor},$fresh->{activity}{cursor},'and its cursor is the fresh one');

# The check list comes back when it changes, with a new revision.
$preflight->{message}='Rechecked';$preflight->{updated_at}=1600;
PGAutomation::write_json_atomic("$store/preflight.json",$preflight);
my $changed=$poll->($query->($first));
ok(ref($changed->{preflight}) eq 'HASH' && !$changed->{preflight_unchanged},'a rewritten check list is sent again');
isnt($changed->{preflight}{rev},$first->{preflight}{rev},'with a new revision');
ok($changed->{activity}{partial},'while the activity feed stays partial');

# A check still running is not resent for its elapsed time alone: the page
# advances that itself from the poll the block arrived in. Its progress
# writes resend it.
$preflight->{status}='checking';delete $preflight->{completed_at};$preflight->{started_at}=Time::HiRes::time()-5.5;$preflight->{updated_at}=time();
PGAutomation::write_json_atomic("$store/preflight.json",$preflight);
my $running=$poll->();
my $elapsed=$running->{preflight}{elapsed_seconds};
ok(defined($elapsed) && $elapsed>=5 && $elapsed<=8,'the elapsed time is served with the check') or diag("elapsed_seconds=".($elapsed//'undef'));
Time::HiRes::sleep(0.25);
ok($poll->('preflight_rev='.$running->{preflight}{rev})->{preflight_unchanged},'a check still running is unchanged while only its elapsed time moves');
push @{$preflight->{checks}},{ok=>1,message=>'One more'};$preflight->{updated_at}=Time::HiRes::time();
PGAutomation::write_json_atomic("$store/preflight.json",$preflight);
ok(!$poll->('preflight_rev='.$running->{preflight}{rev})->{preflight_unchanged},'and resent when a check is added');
pop @{$preflight->{checks}};
$preflight->{status}='started';$preflight->{completed_at}=$preflight->{updated_at}=time();
PGAutomation::write_json_atomic("$store/preflight.json",$preflight);
my $settled=$poll->();
ok($poll->('preflight_rev='.$settled->{preflight}{rev})->{preflight_unchanged},'a finished check is unchanged from one poll to the next');
# Every value the page reads is in the revision, however deep.
my $base=main::webui_automation_preflight_rev($settled->{preflight});
is($base,$settled->{preflight}{rev},'the served revision is the one computed from the block');
{ my $copy=PGAutomation::clone($settled->{preflight});$copy->{issues}[0]{stage}='job-readiness';isnt(main::webui_automation_preflight_rev($copy),$base,'a changed issue stage changes the revision'); }
{ my $copy=PGAutomation::clone($settled->{preflight});$copy->{checks}[0]{signal_format}='hdr10';isnt(main::webui_automation_preflight_rev($copy),$base,'a changed check signal format changes the revision'); }
{ my $copy=PGAutomation::clone($settled->{preflight});$copy->{items}[0]{status}='checked-limited';isnt(main::webui_automation_preflight_rev($copy),$base,'a changed job state changes the revision'); }
{ my $copy=PGAutomation::clone($settled->{preflight});$copy->{update_age}=999;$copy->{elapsed_seconds}=999;delete $copy->{rev};is(main::webui_automation_preflight_rev($copy),$base,'the per-request fields do not'); }

# A different run: the feed the page holds is for another run, so it is reset.
my $other='poll-delta-2';
$write_run->($other);
PGAutomation::append_line_locked(PGAutomation::run_dir($other).'/runner.log',"[2026-09-18T11:00:00Z] Job 1 | starting\n");
my $reset=$poll->($query->($settled));
ok($reset->{activity_reset},'a cursor for another run is answered with a reset');
ok(!$reset->{activity}{partial},'and the full feed');
is($reset->{activity}{run_id},$other,'for the run now current');
is($reset->{activity}{entries}[-1]{message},'Job 1 | starting','from its own log');
ok($reset->{preflight_unchanged},'while the check list, which is not per run, is still unchanged');

# The query string is decoded before use.
my $encoded=$poll->('activity_after='.$escape->($reset->{activity}{cursor}).'&preflight_rev='.$settled->{preflight}{rev});
ok($encoded->{activity}{partial},'a percent-encoded cursor is decoded');
is_deeply($encoded->{activity}{entries},[],'and matches');
is(main::webui_automation_query_param('a=1&b=x%3Ay%20z&c','b'),'x:y z','percent escapes are decoded');
is(main::webui_automation_query_param('a=1&b=x%3Ay%20z&c','c'),'','a bare name is an empty value');
is(main::webui_automation_query_param('a=1&b=2','d'),undef,'a missing name is undef');
is(main::webui_automation_query_param('','a'),undef,'as is an empty query');

# History reads the whole feed, never a partial one.
my $history=PGAutomation::decode_json(main::webui_automation_api("/api/automation/runs/$other",'GET','','activity_after='.$escape->($reset->{activity}{cursor})));
ok(!$history->{activity}{partial} && @{$history->{activity}{entries}},'the saved-run endpoint ignores the cursor and returns the full feed');
done_testing();
