#!/usr/bin/perl
# Stop cleanup calls (worker stop/kill, meter session stop, CAL_END, run/end,
# status, idle pattern) are idempotent, so a transport failure must get a
# bounded retry even though a stop request is what started the cleanup.
# Before this guard every cleanup call passed a zero retry window, and
# _sleep_controlled returned at once whenever a stop was pending, so one
# transport error parked the batch as "cleanup required".
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('cleanup-retry-test','test-token'); local $SIG{__WARN__}=sub {}; do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
local *main::_log=sub {};
local *main::_heartbeat=sub {};
local *main::_refresh_control=sub {};
local *main::_ensure_lg_connection=sub { 1 };

my (@calls,@sleeps);
local *main::_api_once=sub { my ($method,$path)=@_; push @calls,$path;
 return {status=>'error',error_code=>'daemon-unreachable',message=>'timeout',_transport_error=>1}; };
# Sleep for real (windows below are 1 s) and report whether the stop was ignored.
local *main::_sleep_controlled=sub { push @sleeps,[@_]; select(undef,undef,undef,$_[0]); return $_[1] ? 1 : 0 };

# A pending stop, exactly as SIGTERM or a control-file stop sets it.
kill 'TERM',$$; select(undef,undef,undef,0.1);

@calls=();@sleeps=();
my $plain=main::_api('POST','/api/pattern',{name=>'gray50'},0,1);
is(($plain->{error_code}||''),'stopped','a non-cleanup call still returns at once under a pending stop');
is(scalar(@calls),0,'and never reaches the daemon');

@calls=();@sleeps=();
my $cleanup=main::_api('POST','/api/pattern',{name=>'gray50'},1,1);
cmp_ok(scalar(@calls),'>=',2,'a cleanup call retries a transport error inside its window');
ok(scalar(@sleeps) && $sleeps[0][1],'the retry sleep is told to ignore the pending stop');
is(($cleanup->{error_code}||''),'daemon-unreachable','and reports the daemon unreachable once the window is spent');

@calls=();@sleeps=();
my $single=main::_api('POST','/api/pattern',{name=>'gray50'},1,0);
is(scalar(@calls),1,'a zero window is still a single attempt');
is(scalar(@sleeps),0,'with no retry sleep');

# One cleanup pass shares a bounded budget: each call may wait up to 30 s,
# never more than the budget that is left.
my $first=main::_cleanup_window();
is($first,30,'the first cleanup call gets the full 30 s window');
cmp_ok(main::_cleanup_window(),'<=',30,'later calls never exceed it');
cmp_ok(main::_cleanup_window(),'>',0,'and still retry while budget remains');

# Source pins: every stop/finish cleanup call goes through the shared budget,
# and CAL_END (the call that releases the TV) keeps its own window even after
# the worker stops have spent that budget.
my $src=do { open(my $f,'<',"$Bin/../usr/bin/pgen_automation_runner.pl") or die $!; local $/; <$f> };
my ($stop_body)=$src=~/(sub _stop_active \{.*?\n\}\n)/s;
my ($finish_body)=$src=~/(sub _finish \{.*?\n\}\n)/s;
ok($stop_body && $finish_body,'found _stop_active and _finish');
my $budgeted=()=($stop_body.$finish_body)=~/_api\([^;]*?,\s*1,\s*_cleanup_window\(\)(?:\s*\|\|\s*\$CLEANUP_RETRY_WINDOW)?\)/g;
cmp_ok($budgeted,'>=',8,'the cleanup calls pass the shared budget as their retry window');
unlike($stop_body.$finish_body,qr/_api\([^;]*?,\s*1,\s*0\)/,'no cleanup call is pinned to a zero window');
like($stop_body,qr/\$CLEANUP_DEADLINE\s*=\s*time\(\)\s*\+\s*\$CLEANUP_RETRY_BUDGET/,'a stop starts a fresh cleanup budget');
like($stop_body,qr/calibration-mode.*?\},\s*1,\s*_cleanup_window\(\)\s*\|\|\s*\$CLEANUP_RETRY_WINDOW\)/s,
     'CAL_END keeps its own window once the shared budget is spent');

done_testing();
