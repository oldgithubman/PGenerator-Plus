use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{
 local @ARGV=('reconnect-test','reconnect-test-token');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
# 16 Sep 2026: after a fully checked queue, restoring the original picture
# mode hit one "Unable to connect to LG WebOS TV" from the helper. Because the
# restoration and stop paths pass allow_stop, the runner skipped its bounded
# LG reconnect and declared cleanup unverified, parking the run as interrupted.
local *main::_refresh_control=sub {};
local *main::_heartbeat=sub {};
local *main::_log=sub {};
local *main::_sleep_controlled=sub {1};
my $refusal={status=>'error',message=>'Unable to connect to LG WebOS TV at 192.168.50.28 on ws://3000 or wss://3001'};
my (@once,$forced,$checks);
local *main::_ensure_lg_connection=sub { my ($force)=@_; $force ? $forced++ : $checks++; return 1; };
local *main::_api_once=sub {
 my ($method,$path)=@_; push @once,$path;
 return $refusal if $path eq '/api/lg/picture-settings/set' && @once==1;
 return {status=>'ok',picture_settings=>{pictureMode=>'filmMaker'}};
};
for my $allow_stop (0,1) {
 @once=();$forced=0;$checks=0;
 my $reply=main::_api('POST','/api/lg/picture-settings/set',{settings=>{pictureMode=>'filmMaker'}},$allow_stop,0);
 is($reply->{status},'ok',"allow_stop=$allow_stop: one transient TV connect refusal is retried");
 is($forced,1,"allow_stop=$allow_stop: exactly one pairing refresh before the retry");
 is(scalar(grep {$_ eq '/api/lg/picture-settings/set'} @once),2,"allow_stop=$allow_stop: the write is sent again after the refresh");
}
@once=();$forced=0;
local *main::_api_once=sub { push @once,$_[1]; return $refusal; };
my $reply=main::_api('POST','/api/lg/picture-settings/set',{settings=>{pictureMode=>'filmMaker'}},1,0);
is($reply->{status},'error','a TV that stays unreachable still fails the stop path');
is($forced,3,'reconnects during stop are bounded to three refreshes');
is(scalar(@once),4,'no unbounded retry loop while stopping');
like($reply->{message},qr/Unable to connect to LG WebOS TV/,'the original TV error is reported');
@once=();$forced=0;
$reply=main::_api('GET','/api/lg/status',undef,1,0);
is($forced,0,'status and connect requests themselves never trigger a pairing refresh');
done_testing();
