use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{
 local @ARGV=('worker-activity-test','worker-activity-test-token');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;
}
my (@lines,@times);
local *main::_log=sub {push @lines,$_[0];push @times,$_[1]};
local *main::_active_item_number=sub {1};
my $last=0;
my $status={activity_events=>[
 {seq=>2,time=>102,message=>'7% | LUT upload accepted'},
 {seq=>1,time=>101,message=>'7% | dE 0.610'},
 {seq=>2,time=>102,message=>'duplicate'},
 {seq=>'bad',message=>'invalid'},
]};
main::_log_worker_events($status,\$last);
is_deeply(\@lines,['Job 2 | 1D LUT | 7% | dE 0.610','Job 2 | 1D LUT | 7% | LUT upload accepted'],'every buffered event is saved in sequence with one-based job identity');
is_deeply(\@times,[101,102],'original worker times survive polling');
main::_log_worker_events($status,\$last);
is(scalar @lines,2,'repeat poll does not duplicate events');
main::_log_worker_events({activity_events=>[{seq=>5,message=>"Point finished\nsecond line"}]},\$last);
like($lines[-2],qr/activity gap/,'buffer overrun is visible, not silently lost');
is($lines[-1],'Job 2 | 1D LUT | Point finished second line','multiline messages cannot forge log entries');
is($last,5,'cursor advances through terminal events');
my $reading={status=>'running',current_name=>'Auto Cal 7%',current_step=>27,total_steps=>37,message=>'Reading 7% sample 1/1'};
my $first=main::_worker_progress($reading);
$reading->{message}='Reading 7% for HDR20 1D DPG (4/8, target dE<=0.50)';
is(main::_worker_progress($reading),$first,'sample and iteration status chatter do not duplicate the point milestone');
$reading->{message}='Upload failed; retrying: TV disconnected';
like(main::_worker_progress($reading),qr/Upload failed; retrying: TV disconnected/,'failure, retry and cause are never filtered');
$reading->{message}='HDR20 1D DPG 7% 4/8 uploaded (max dE=2.1, target<=0.50)';
$reading->{activity_sequence}=5;
is(main::_worker_progress($reading),$first,'structured upload event replaces vague trajectory-max message');
$reading->{current_step}=28;$reading->{current_name}='Auto Cal 6%';
isnt(main::_worker_progress($reading),$first,'next point remains visible');
$reading->{status}='complete';$reading->{message}='Calibration committed';
like(main::_worker_progress($reading),qr/complete.*Calibration committed/,'terminal outcome remains visible');
is(main::_worker_progress({status=>'complete',current_name=>'Auto Cal complete',message=>'Auto Cal complete',current_step=>1,total_steps=>37}),
 'complete | Auto Cal complete','completion neither repeats its message nor shows a reset patch counter');
like(main::_worker_progress({status=>'error',message=>'Meter disconnected',current_step=>7,total_steps=>37}),
 qr/Meter disconnected.*Patch 7 \/ 37/,'failure retains the interrupted patch context');
{
 @lines=();@times=();
 my $first={seq=>1,time=>101,message=>'7% | measured dE 0.61'};
 my $final={seq=>2,time=>102,message=>'7% | Point finished | Best measured dE 0.46'};
 my @responses=(
  {status=>'running',current_name=>'Auto Cal 7%',message=>'Reading 7% sample 1/1',activity_events=>[$first]},
  {status=>'running',current_name=>'Auto Cal 7%',message=>'Reading 7% sample 2/2',activity_events=>[$first]},
  {status=>'complete',message=>'Calibration committed',activity_events=>[$first,$final]},
 );
 local *main::_api=sub {return {status=>'ok'} if $_[1] eq '/api/lg/status';return shift(@responses) || die 'Unexpected extra worker poll'};
 local *main::_refresh_control=sub {};
 local *main::_update_run=sub {1};
 local *main::_sleep_controlled=sub {1};
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is($result->{status},'complete','real worker wait loop completes with buffered events');
 is(scalar(grep {/measured dE 0.61/} @lines),1,'measurement is saved once across repeated polls');
 is(scalar(grep {/Point finished/} @lines),1,'final event is drained before returning terminal status');
 is(scalar(grep {/Auto Cal 7%/} @lines),1,'sample messages collapse into a single point milestone');
}
done_testing();
