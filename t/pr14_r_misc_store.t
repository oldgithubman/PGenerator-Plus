# Agent BC misc probes: store permissions/durability helpers and legacy pause.
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;
my $WT;BEGIN{require FindBin;$WT="$FindBin::Bin/.."}
use lib "$WT/usr/share/PGenerator";
use PGAutomation ();
my $base=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}="$base/automation";
ok(PGAutomation::ensure_store(),'store created');
is(sprintf('%o',(stat("$base/automation"))[2]&07777),'700','store dir 0700');
PGAutomation::write_atomic("$base/automation/runs/x/run.json",'{}',0666);
is(sprintf('%o',(stat("$base/automation/runs/x/run.json"))[2]&07777),'600','caller mode 0666 is forced to 0600 inside the store');
is(sprintf('%o',(stat("$base/automation/runs/x"))[2]&07777),'700','new run dir 0700');
my $out=tempdir(CLEANUP=>1);
PGAutomation::write_atomic("$out/meter_series.json",'{}',0666);
is(sprintf('%o',(stat("$out/meter_series.json"))[2]&07777),'666','outside the store the caller mode is kept (worker state files stay world-readable)');
PGAutomation::write_atomic("$out/cfg.json",'{}',0600);
is(sprintf('%o',(stat("$out/cfg.json"))[2]&07777),'600','worker config 0600 (daemon user only)');
# Unnormalised path spelling bypasses the private-store rule
PGAutomation::write_atomic("$base//automation/runs/x/alias.json",'{}',0666);
is(sprintf('%o',(stat("$base/automation/runs/x/alias.json"))[2]&07777),'600','an unnormalised spelling of a store path is still private');
# Directory that is writable+searchable but not readable: rename succeeds, fsync open fails
my $wx=tempdir(CLEANUP=>1);chmod 0300,$wx;
my $r=PGAutomation::write_atomic("$wx/f.json",'{"a":1}',0644);
chmod 0700,$wx;
SKIP: {
 skip 'root ignores directory permissions',2 if $>==0;
 ok(!$r,'a parent that cannot be synced is reported as a failed write (P23)');
 ok(!-f "$wx/f.json",'and nothing was published before that failure');
}
# Legacy (6b929bae) paused manifest with only protective setting changes
my $legacy={status=>'paused',hazard_restore=>{autoPowerOff=>{value=>'on',category=>'power'}},items=>[{}]};
# restoration_problems stays a pure reading of the manifest; boot recovery marks such
# legacy runs as owing their protective settings (t/automation_cleanup_lock.t).
is_deeply(PGAutomation::restoration_problems($legacy),[],'a legacy manifest without the pending flag is not itself a restoration problem');
done_testing();
