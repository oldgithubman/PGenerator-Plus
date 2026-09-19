# Agent BC (6b): delivery-aware LG reconnect gating vs the 16 Sep fix, using
# the helper's real connect-failure text (pgenerator-lg lg_authenticated_session).
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use Test::More;
my $WT="$Bin/..";
use lib ();BEGIN{require FindBin;unshift @INC,"$FindBin::Bin/../usr/share/PGenerator"}
use PGAutomation ();
$ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('reconnect-bc','reconnect-bc-token');local $SIG{__WARN__}=sub{};do "$WT/usr/bin/pgen_automation_runner.pl";die $@ if $@;}
local *main::_refresh_control=sub{};local *main::_heartbeat=sub{};local *main::_log=sub{};local *main::_sleep_controlled=sub{1};
# Exact helper text, as produced by lg_authenticated_session and passed through lg_helper_run unchanged.
my $connect={status=>'error',message=>'Unable to connect to LG WebOS TV at 192.168.50.28 on ws://3000 or wss://3001',ip=>'192.168.50.28',connect_attempts=>2,connect_retried=>1};
my $midway={status=>'error',message=>'LG WebOS TV websocket connection closed during request'};
my $disconnected={status=>'error',message=>'Connect the LG TV before changing panel protection.'};
my (@sent,$forced,$first);
local *main::_ensure_lg_connection=sub {$forced++ if $_[0];1};
sub run_case {
  my ($path,$payload,$fail,$allow_stop)=@_;
  @sent=();$forced=0;$first=$fail;
  local *main::_api_once=sub {push @sent,$_[1];if($first){my $f=$first;undef $first;return {%$f};}return {status=>'ok'};};
  return main::_api('POST',$path,$payload,$allow_stop,0);
}
my @cases=(
 ['restore picture mode during stop (16 Sep)','/api/lg/picture-settings/set',{settings=>{pictureMode=>'filmMaker'}},$connect,1,2],
 ['panel protection re-enable, connect refused','/api/lg/panel-protection',{enable=>JSON::PP::true},$connect,1,2],
 ['panel protection re-enable, daemon says not connected','/api/lg/panel-protection',{enable=>JSON::PP::true},$disconnected,1,2],
 ['panel protection, mid-conversation drop','/api/lg/panel-protection',{enable=>JSON::PP::true},$midway,1,1],
 ['CAL_START, connect refused','/api/lg/calibration-mode',{enabled=>JSON::PP::true},$connect,0,2],
 ['CAL_START, mid-conversation drop','/api/lg/calibration-mode',{enabled=>JSON::PP::true},$midway,0,1],
 ['CAL_END, mid-conversation drop (idempotent)','/api/lg/calibration-mode',{enabled=>JSON::PP::false},$midway,1,2],
 ['DDC white-balance upload, connect refused','/api/lg/picture-settings/set',{settings=>{whiteBalanceRed=>[0,0]}},$connect,0,2],
 ['DDC white-balance upload, mid-conversation drop','/api/lg/picture-settings/set',{settings=>{whiteBalanceRed=>[0,0]}},$midway,0,1],
 ['run end during stop, connect refused','/api/lg/autocal/run/end',{status=>'aborted'},$connect,1,2],
);
for my $c (@cases) {
  my $r=run_case(@{$c}[1..4]);
  is(scalar(grep {$_ eq $c->[1]} @sent),$c->[5],"$c->[0]: sent $c->[5] time(s)");
  is($forced,$c->[5]-1,"$c->[0]: pairing refreshes");
}
done_testing();
