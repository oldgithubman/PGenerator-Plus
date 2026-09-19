# Regression for PR 14 test report P28: a stage that dies reports the real
# exception on one line, and an earlier $::LAST_ERROR cannot replace it.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
my $id='stage-message';
{local @ARGV=($id,'stage-token');local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/^Subroutine .* redefined/};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my $dir=PGAutomation::run_dir($id);
sub stage {
 my ($callback)=@_;
 PGAutomation::write_json_atomic("$dir/run.json",{id=>$id,token=>'stage-token',status=>'running',items=>[{}]});
 PGAutomation::write_json_atomic("$dir/control.json",{request=>'none'});
 PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$id,token=>'stage-token',status=>'running'});
 my $item={};
 # Longer than the control-read throttle, so _refresh_control really decodes
 # control.json (which is what used to reset $@).
 main::_stage(0,$item,'post-readings-done',sub { sleep(0.6); $callback->() });
 return ($item->{failure}{message}//'',PGAutomation::read_json_file("$dir/run.json")->{failure}{message}//'');
}
my ($item,$run)=stage(sub { die "LG AutoCal refused the write\nreason: panel busy\r\n\n  detail: retry later at /usr/bin/x.pl line 42.\n" });
like($item,qr/^LG AutoCal refused the write \| reason: panel busy \| detail: retry later/,'the die text reaches the item failure on one line');
is($run,$item,'and the run failure');
unlike($item,qr/Stage post-readings-done failed/,'not the generic stage message');
($item)=stage(sub { $::LAST_ERROR="stale from a recovered read\nsecond line"; die "hash- or arrayref expected\n" });
like($item,qr/^hash- or arrayref expected \(last recorded error: stale from a recovered read \| second line\)$/,'a stale LAST_ERROR is kept as context but never replaces the exception');
($item)=stage(sub { $::LAST_ERROR='TV refused CAL_START'; die "$::LAST_ERROR\n" });
is($item,'TV refused CAL_START','a die carrying LAST_ERROR is not repeated');
($item)=stage(sub { $::LAST_ERROR='Readiness failed: meter missing'; return 0 });
is($item,'Readiness failed: meter missing','a false return still reports LAST_ERROR');
($item)=stage(sub { return 0 });
is($item,'Stage post-readings-done failed','a false return with no error keeps the generic message');
($item)=stage(sub { $::LAST_ERROR='Meter not connected'; die($::LAST_ERROR||'Meter check failed') });
is($item,'Meter not connected','a die without a newline does not show the runner file and line');
like(PGAutomation::read_json_file("$dir/run.json")->{failure}{raw_exception},qr/Meter not connected at \S+ line \d+/,'the raw location is kept in the failure record for diagnosis');
($item)=stage(sub { $::LAST_ERROR="Worker said no\n"; die "Worker said no\n" });
is($item,'Worker said no','a LAST_ERROR with a trailing newline is not repeated');
($item)=stage(sub { $::LAST_ERROR="A\nB"; die "A\nB\n" });
is($item,'A | B','a multi-line LAST_ERROR equal to the exception is not repeated');
done_testing();
