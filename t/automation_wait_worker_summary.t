# The wait loop polls the worker's summary view carrying the last activity
# sequence it saw, and reads the full state exactly once when the summary
# reports a terminal status, so callers and the archive still get the whole
# result. A full read that fails or disagrees with the summary leaves the
# terminal summary as the result. Routes without a summary view are polled
# as before.
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{
 local @ARGV=('wait-worker-summary-test','test-token');
 local $SIG{__WARN__}=sub {};
 do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;
}
my (@lines,@paths);
local *main::_log=sub {push @lines,$_[0]};
local *main::_log_action=sub {push @lines,$_[0]};
local *main::_active_item_number=sub {0};
local *main::_refresh_control=sub {};
local *main::_sleep_controlled=sub {1};
local *main::_update_run=sub {my $r={};$_[0]->($r);return $r};
# The runner falls back to the worker's own state file when the daemon cannot
# serve the full state; keep the harness off the appliance paths.
local *main::_worker_state_file_read=sub {undef};

is(main::_worker_status_poll_path('/api/meter/lg-autocal/status',0),'/api/meter/lg-autocal/status?view=summary&after=0','greyscale polls use the summary view');
is(main::_worker_status_poll_path('/api/meter/lg-3d-autocal/status',5),'/api/meter/lg-3d-autocal/status?view=summary&after=5','3D LUT polls use the summary view');
is(main::_worker_status_poll_path('/api/lg/dv-profile/status',17),'/api/lg/dv-profile/status?view=summary&after=17','the poll asks only for events after the last one seen');
is(main::_worker_status_poll_path('/api/meter/lg-autocal/status','bad'),'/api/meter/lg-autocal/status?view=summary&after=0','a malformed cursor falls back to zero');
is(main::_worker_status_poll_path('/api/meter/series/status',3),'/api/meter/series/status','routes without a summary view are polled unchanged');
is(main::_lg_action_path('/api/lg/dv-profile/status?view=summary&after=0'),main::_lg_action_path('/api/lg/dv-profile/status'),'the query does not change LG action detection');
is(main::_lg_retry_window('/api/lg/dv-profile/status?view=summary&after=0'),main::_lg_retry_window('/api/lg/dv-profile/status'),'nor the retry window');

my $summary={status=>'complete',automation_worker_id=>'w1'};
ok(main::_worker_full_status_usable($summary,{status=>'complete',automation_worker_id=>'w1',measurements=>[]}),'a terminal full state for the same worker replaces the summary');
ok(main::_worker_full_status_usable($summary,{status=>'error',error_code=>'meter-read-failed',automation_worker_id=>'w1'}),'the worker\'s own failure is a usable full state');
ok(!main::_worker_full_status_usable($summary,undef),'nothing is not a usable full state');
ok(!main::_worker_full_status_usable($summary,{status=>'error',error_code=>'daemon-unreachable',_transport_error=>1}),'a transport failure is not');
ok(!main::_worker_full_status_usable($summary,{status=>'error',error_code=>'invalid-daemon-response'}),'nor an undecodable reply');
ok(!main::_worker_full_status_usable($summary,{status=>'error',error_code=>'stopped'}),'nor a stop interrupting the request');
ok(!main::_worker_full_status_usable($summary,{status=>'complete',automation_worker_id=>'w2'}),'nor another worker\'s result');
ok(main::_worker_full_status_usable($summary,{status=>'running',automation_worker_id=>'w1'}),'a same-worker state that is not terminal is adopted so polling continues');
ok(!main::_worker_full_status_usable($summary,{status=>'idle'}),'an unstamped read after a stamped summary is not this attempt\'s state');
ok(main::_worker_full_status_usable({status=>'idle'},{status=>'idle'}),'an unstamped read matches an unstamped summary');
ok(main::_worker_state_file_usable($summary,{status=>'complete',automation_worker_id=>'w1',measurements=>{}}),'this attempt\'s finished state file stands in for a failed full read');
ok(main::_worker_state_file_usable($summary,{status=>'error',automation_worker_id=>'w1'}),'including its own failure');
ok(!main::_worker_state_file_usable($summary,undef),'a missing or unreadable state file does not');
ok(!main::_worker_state_file_usable($summary,{status=>'running',automation_worker_id=>'w1'}),'nor a state file still mid-run');
ok(!main::_worker_state_file_usable($summary,{status=>'complete',automation_worker_id=>'w2'}),'nor another attempt\'s state file');
ok(!main::_worker_state_file_usable($summary,{status=>'complete'}),'nor an unstamped state file after a stamped summary');

my $event=sub {my ($seq)=@_;return {seq=>$seq,time=>100+$seq,message=>"event $seq"}};
{
 my @summaries=(
  {status=>'running',current_name=>'Auto Cal 7%',current_step=>1,total_steps=>3,automation_worker_id=>'w1',activity_sequence=>2,activity_events=>[$event->(1),$event->(2)]},
  {status=>'running',current_name=>'Auto Cal 7%',current_step=>2,total_steps=>3,automation_worker_id=>'w1',activity_sequence=>3,activity_events=>[$event->(3)]},
  {status=>'complete',current_name=>'Auto Cal complete',message=>'Auto Cal complete',automation_worker_id=>'w1',activity_sequence=>4,activity_events=>[$event->(4)]},
 );
 my $full={status=>'complete',current_name=>'Auto Cal complete',message=>'Auto Cal complete',automation_worker_id=>'w1',activity_sequence=>4,
  activity_events=>[map {$event->($_)} 1..4],measurements=>[1,2,3],ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_anchor_history=>[1..10]};
 my $full_fetches=0;
 local *main::_api=sub {
  my ($method,$path)=@_;
  return {status=>'ok'} if $path eq '/api/lg/status';
  push @paths,$path;
  if($path eq '/api/meter/lg-autocal/status') {$full_fetches++;return PGAutomation::clone($full)}
  die "unexpected poll path $path" if $path !~ m{^/api/meter/lg-autocal/status\?view=summary&after=\d+$};
  return shift(@summaries) || die 'polled after the terminal summary';
 };
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is($result->{status},'complete','the wait returns the terminal status');
 is_deeply($result->{measurements},[1,2,3],'the returned object is the full state, not the summary');
 ok($result->{ddc_upload_verified},'callers still see the verification flags');
 is($full_fetches,1,'the full state is fetched exactly once');
 is_deeply(\@paths,[
  '/api/meter/lg-autocal/status?view=summary&after=0',
  '/api/meter/lg-autocal/status?view=summary&after=2',
  '/api/meter/lg-autocal/status?view=summary&after=3',
  '/api/meter/lg-autocal/status',
 ],'every poll is a summary carrying the last seen sequence; only the end reads the full state');
 is(scalar(grep {/1D LUT \| event \d/} @lines),4,'each event is saved once across summary polls and the full read');
 is(scalar(grep {/activity gap/} @lines),0,'server-side filtering does not look like a gap');
 is(scalar(grep {/full status could not be read/} @lines),0,'a good full read is not reported as a fallback');
}
{
 @lines=();
 my @summaries=(
  {status=>'running',automation_worker_id=>'w1',activity_sequence=>2,activity_events=>[$event->(1),$event->(2)]},
  {status=>'running',automation_worker_id=>'w1',activity_sequence=>9,activity_events=>[$event->(8),$event->(9)]},
  {status=>'complete',automation_worker_id=>'w1',activity_sequence=>9,activity_events=>[]},
 );
 local *main::_api=sub {
  my ($method,$path)=@_;
  return {status=>'ok'} if $path eq '/api/lg/status';
  return {status=>'complete',automation_worker_id=>'w1',activity_events=>[]} if $path eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'polled after the terminal summary';
 };
 main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is(scalar(grep {/activity gap/} @lines),1,'events that expired before collection are still reported as a gap');
}
# A full read that fails or disagrees with the summary keeps the summary, so a
# finished stage is never turned into a transport failure or an identity
# mismatch by the second request.
for my $case (
 ['daemon unreachable',{status=>'error',error_code=>'daemon-unreachable',_transport_error=>1}],
 ['invalid JSON',{status=>'error',error_code=>'invalid-daemon-response',message=>'The daemon returned invalid JSON'}],
 ['no reply',undef],
 ['another worker',{status=>'complete',automation_worker_id=>'w2'}],
) {
 my ($name,$reply)=@$case;
 @lines=();
 my @summaries=({status=>'complete',automation_worker_id=>'w1',message=>'done',current_name=>'Auto Cal complete'});
 local *main::_api=sub {
  my ($method,$path)=@_;
  return {status=>'ok'} if $path eq '/api/lg/status';
  return $reply if $path eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'polled after the terminal summary';
 };
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is($result->{status},'complete',"$name: the terminal summary stands as the result");
 is($result->{message},'done',"$name: with the summary's own fields");
 is(scalar(grep {/full status could not be read/} @lines),1,"$name: the fallback is logged once");
 ok(scalar(grep {/archived evidence is a projection/} @lines),"$name: the log says the archived evidence is a projection");
}
# When the daemon cannot serve the full state, the worker's own state file is
# adopted if it is this attempt's finished state: it carries the measurements,
# curves and export paths the stage callers and the archive need.
{
 @lines=();
 my @summaries=({status=>'complete',automation_worker_id=>'w1',message=>'done'});
 local *main::_api=sub {
  my ($method,$path)=@_;
  return {status=>'ok'} if $path eq '/api/lg/status';
  return {status=>'error',error_code=>'daemon-unreachable',_transport_error=>1} if $path eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'polled after the terminal summary';
 };
 my @asked;
 local *main::_worker_state_file_read=sub {push @asked,$_[0];return {status=>'complete',automation_worker_id=>'w1',message=>'done',
  measurements=>{white=>[1,2,3]},hdr20_1d_dpg_data=>[1..3072],export=>{cube_path=>'/var/lib/PGenerator/lg/luts/a.cube'}}};
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is($result->{status},'complete','the state file result is adopted');
 is(scalar @{$result->{hdr20_1d_dpg_data}},3072,'with the full curve the archive needs');
 ok(ref $result->{measurements} eq 'HASH' && ref $result->{export} eq 'HASH','and the measurements and export paths the callers gate on');
 is_deeply(\@asked,['/api/meter/lg-autocal/status'],'the state file is read once for this route');
 is(scalar(grep {/using the worker's state file/} @lines),1,'the fallback to the state file is logged once');
 ok(!scalar(grep {/projection/} @lines),'and not reported as a projection');
 for my $saved ([undef,'unreadable'],[{status=>'running',automation_worker_id=>'w1'},'still mid-run'],[{status=>'complete',automation_worker_id=>'w2'},'from another attempt']) {
  @lines=();
  @summaries=({status=>'complete',automation_worker_id=>'w1',message=>'done'});
  local *main::_worker_state_file_read=sub {$saved->[0]};
  my $r=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
  is($r->{message},'done',"a state file that is $saved->[1] leaves the summary standing");
  ok(scalar(grep {/archived evidence is a projection/} @lines),'and the log says the archived evidence is a projection');
 }
}
# A same-worker full read that is not terminal is adopted and polling goes
# on: the daemon's liveness check saw the worker again after the summary
# flipped it, so the stage is not failed while the worker still measures.
{
 @lines=();
 my @summaries=({status=>'error',automation_worker_id=>'w1',current_name=>'Auto Cal process died'},
                {status=>'complete',automation_worker_id=>'w1'});
 my @fulls=({status=>'running',automation_worker_id=>'w1',current_name=>'Auto Cal 7%',current_step=>7,total_steps=>37},
            {status=>'complete',automation_worker_id=>'w1',full=>1});
 my @seen;
 local *main::_api=sub {
  my ($m,$p)=@_;
  return {status=>'ok'} if $p eq '/api/lg/status';
  push @seen,$p;
  return shift(@fulls) || die 'extra full read' if $p eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'extra poll';
 };
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 ok($result->{full},'the wait ends on a later full state');
 is_deeply(\@seen,['/api/meter/lg-autocal/status?view=summary&after=0','/api/meter/lg-autocal/status',
  '/api/meter/lg-autocal/status?view=summary&after=0','/api/meter/lg-autocal/status'],'a running full read is adopted and summary polling resumes');
 is(scalar(grep {/full status could not be read/} @lines),0,'a live worker is not a failed read');
 ok(scalar(grep {/Auto Cal 7%.*Patch 7 \/ 37/} @lines),'the adopted running state is logged as progress');
 ok(!scalar(grep {/process died/} @lines),'the flipped summary never reaches the log as an outcome');
}
{
 # An unstamped idle full read after a stamped terminal summary is not this
 # attempt's state (nothing under usr/ removes a state file mid-run), so the
 # summary stands. The harness runs with no active worker id, so this proves
 # the adoption rule, not the production identity check that follows it.
 my @summaries=({status=>'complete',automation_worker_id=>'w1'});
 my @fulls=({status=>'idle'});
 my @seen;
 local *main::_api=sub {
  my ($m,$p)=@_;
  push(@seen,$p);
  return {status=>'ok'} if $p eq '/api/lg/status';
  return shift(@fulls) || die 'extra full read' if $p eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'extra poll';
 };
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is($result->{status},'complete','the stamped terminal summary stands over an unstamped idle full read');
 ok(!$result->{full},'and the idle read is not adopted');
 is(scalar(grep { $_ eq '/api/meter/lg-autocal/status' } @seen),1,'after one full read');
}
{
 my @summaries=({status=>'idle'},{status=>'running',automation_worker_id=>'w1'},{status=>'complete',automation_worker_id=>'w1'});
 my @seen;
 local *main::_api=sub {
  my ($m,$p)=@_;
  return {status=>'ok'} if $p eq '/api/lg/status';
  push @seen,$p;
  return {status=>'complete',automation_worker_id=>'w1',full=>1} if $p eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'extra poll';
 };
 local *main::_idle_worker_alive=sub {1};
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 ok($result->{full},'the wait ends on the full state');
 is_deeply(\@seen,[('/api/meter/lg-autocal/status?view=summary&after=0')x3,'/api/meter/lg-autocal/status'],'an unstamped idle summary does not cost a full read');
}
{
 my @statuses=({status=>'running',current_step=>1,total_steps=>2},{status=>'complete',current_step=>2,total_steps=>2});
 my @seen;
 local *main::_api=sub {my ($m,$p)=@_;return {status=>'ok'} if $p eq '/api/lg/status';push @seen,$p;return shift(@statuses) || die 'extra poll'};
 is(main::_wait_worker('/api/meter/series/status','series',{})->{status},'complete','series waits complete as before');
 is_deeply(\@seen,['/api/meter/series/status','/api/meter/series/status'],'series polls carry no summary query and fetch nothing extra');
}
{
 my @summaries=({status=>'running',automation_worker_id=>'w1'},{status=>'complete',automation_worker_id=>'w1'});
 my @seen;
 local *main::_api=sub {
  my ($m,$p)=@_;
  return {status=>'ok'} if $p eq '/api/lg/status';
  push @seen,$p;
  return {status=>'complete',automation_worker_id=>'w1',profile=>{}} if $p eq '/api/lg/dv-profile/status';
  return shift(@summaries) || die 'extra poll';
 };
 my $dv=main::_wait_worker('/api/lg/dv-profile/status','Dolby Vision profile',{});
 ok(exists $dv->{profile},'the Dolby Vision wait also ends on the full state');
 is_deeply(\@seen,['/api/lg/dv-profile/status?view=summary&after=0','/api/lg/dv-profile/status?view=summary&after=0','/api/lg/dv-profile/status'],'Dolby Vision polls use the summary view');
}
# The production identity check: _start_worker stamps the attempt id, a
# same-attempt summary is followed to the full state, and a summary from
# another attempt is refused before anything is adopted or archived.
{
 my $attempt='';
 my @summaries;
 local *main::_api=sub {
  my ($m,$p,$payload)=@_;
  return {status=>'ok'} if $p eq '/api/lg/status';
  if($m eq 'POST') { $attempt=$payload->{automation_worker_id}; return {status=>'started'} }
  return {status=>'complete',automation_worker_id=>$attempt,full=>1} if $p eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'extra poll';
 };
 is(main::_start_worker('/api/meter/lg-autocal','/api/meter/lg-autocal/status',{})->{status},'started','the worker launch is accepted');
 like($attempt,qr/^wait-worker-summary-test-0-\S+$/,'the launch stamped this attempt');
 @summaries=({status=>'running',automation_worker_id=>$attempt},{status=>'complete',automation_worker_id=>$attempt});
 ok(main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{})->{full},'a same-attempt summary is followed to the full state');
 @summaries=({status=>'running',automation_worker_id=>'another-attempt'});
 is(main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{})->{error_code},'worker-identity-mismatch','a foreign running summary is refused on its first poll');
 @summaries=({status=>'complete',automation_worker_id=>'another-attempt'});
 is(main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{})->{error_code},'worker-identity-mismatch','a foreign terminal summary is refused even after the full read');
 main::_clear_active_worker();
}
done_testing();
