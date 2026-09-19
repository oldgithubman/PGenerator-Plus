# Regression probe (agent BC): a single transient {"status":"idle"} poll while
# the worker process is alive. a414fab3 added tolerance for exactly this
# ("idle && worker alive -> keep waiting"). With worker identities the guard
# runs first and an idle status never carries an id.
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
{local @ARGV=('idle-run','test-token');local $SIG{__WARN__}=sub{};do "$WT/usr/bin/pgen_automation_runner.pl";die $@ if $@;}
PGAutomation::ensure_store();
PGAutomation::write_json_atomic(PGAutomation::run_dir('idle-run').'/run.json',{id=>'idle-run',token=>'test-token',status=>'running',items=>[{}]});
PGAutomation::write_json_atomic(PGAutomation::run_dir('idle-run').'/control.json',{request=>'none'});
local *main::_log=sub{};local *main::_sleep_controlled=sub{1};
local *main::_worker_process_alive=sub {1};   # worker process is alive
local *main::process_start_ticks=sub {''};
my $id;my @seq;
local *main::_api=sub {
  my ($m,$p,$payload)=@_;
  return {status=>'ok',connected=>1} if $p eq '/api/lg/status';
  if ($m eq 'POST') {$id=$payload->{automation_worker_id};@seq=({status=>'running',current_step=>1,($id?(automation_worker_id=>$id,worker_pid=>$$,worker_start_ticks=>PGAutomation->can('process_start_ticks')?PGAutomation::process_start_ticks($$):''):())},{status=>'idle'},{status=>'complete',($id?(automation_worker_id=>$id):())});return {status=>'started'};}
  return @seq>1?shift @seq:$seq[0];
};
$main::ACTIVE_WORKER='grey';
my $start=main::_start_worker('/api/meter/lg-autocal','/api/meter/lg-autocal/status',{});
my $r=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
diag("result status=".($r->{status}//'undef')." error_code=".($r->{error_code}//''));
is($r->{status},'complete','transient idle poll while the worker is alive does not abort the job');
done_testing();
