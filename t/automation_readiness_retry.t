use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{
 local @ARGV=('readiness-retry-test','readiness-retry-token');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
# The whole-queue check's per-job readiness talks to the TV inside the daemon.
# When that conversation is refused, the runner reconnects and asks once more
# instead of blocking the queue.
my (@calls,@actions,$reconnects);
local *main::_log=sub {};
local *main::_log_action=sub {push @actions,$_[0]};
local *main::_ensure_lg_connection=sub {$reconnects++ if $_[0];1};
my $refused={ready=>0,checks=>[{ok=>0,level=>'error',name=>'calibration-mode-off',message=>'Unable to establish normal viewing before baseline measurements: Unable to connect to LG WebOS TV at 192.168.50.28 on ws://3000 or wss://3001'}]};
my $ready={ready=>1,checks=>[{ok=>1,name=>'calibration-mode-off',message=>'TV acknowledged calibration mode off'}]};
my @replies=($refused,$ready);
local *main::_api=sub {push @calls,[$_[1],$_[2]];return shift @replies};
$reconnects=0;
my $payload={scope=>'job',items=>[{name=>'HDR10 Filmmaker'}]};
my $result=main::_readiness_with_reconnect($payload);
ok($result->{ready},'a refused TV connection during readiness is retried after a reconnect');
is(scalar(@calls),2,'readiness is asked exactly twice');
is_deeply([map {$_->[1]} @calls],[$payload,$payload],'with the same job both times');
is($reconnects,1,'the pairing is refreshed before the retry');
ok(grep({/reconnecting and checking again/} @actions),'the retry is announced');
@replies=({ready=>0,checks=>[{ok=>0,level=>'error',name=>'item-0-key-oledLight',message=>'oledLight is not supported by the LG TV'}]});@calls=();$reconnects=0;
$result=main::_readiness_with_reconnect($payload);
ok(!$result->{ready},'a real readiness failure is returned as it is');
like($result->{checks}[0]{message},qr/oledLight is not supported/,'with its cause');
is(scalar(@calls),1,'and is not retried');
is($reconnects,0,'nor does it touch the pairing');
done_testing();
