# A readiness pass ("Check Readiness") finishes with status "complete" exactly
# like a real calibration, and History showed the two identically. Three checks
# in a row therefore looked like a batch that kept running and producing
# nothing, while the queue had in fact never been asked to calibrate.
#
# The manifest already records preflight_only; the History listing did not
# carry it. These are the properties that keep the two distinguishable.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use JSON::PP ();
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";

my $store=tempdir(CLEANUP=>1);
$ENV{PGEN_AUTOMATION_DIR}=$store;
PGAutomation::ensure_store();

# Write the flag the way the readiness endpoint does -- JSON::PP::true, not a
# plain 1. A real manifest decodes back to a blessed JSON::PP::Boolean, so a
# fixture using a bare integer would never exercise the shape production
# actually stores, and a change that mishandled the object would still pass.
PGAutomation::write_json_atomic(PGAutomation::run_dir('run-check').'/run.json',{
 id=>'run-check',token=>'t1',status=>'complete',queue_name=>'TV calibration queue',
 created_at=>1,preflight_only=>JSON::PP::true,items=>[{name=>'SDR Filmmaker',signal_format=>'sdr'}]});
PGAutomation::write_json_atomic(PGAutomation::run_dir('run-false').'/run.json',{
 id=>'run-false',token=>'t3',status=>'complete',queue_name=>'TV calibration queue',
 created_at=>3,preflight_only=>JSON::PP::false,items=>[{name=>'SDR Filmmaker',signal_format=>'sdr'}]});
PGAutomation::write_json_atomic(PGAutomation::run_dir('run-cal').'/run.json',{
 id=>'run-cal',token=>'t2',status=>'complete',queue_name=>'TV calibration queue',
 created_at=>2,items=>[{name=>'SDR Filmmaker',signal_format=>'sdr'}]});

my %row=map { ($_->{id}=>$_) } @{main::webui_automation_list_runs()};
is(scalar(keys %row),3,'every run is listed');

# --- the listing must carry the flag at all ---
ok(exists $row{'run-check'}{preflight_only},'the listing row carries preflight_only');
ok($row{'run-check'}{preflight_only},'a readiness pass is marked preflight_only');
ok(!$row{'run-cal'}{preflight_only},'a real calibration is not');
# A JSON false decodes to a blessed JSON::PP::Boolean that is TRUE as a plain
# ref and FALSE in boolean context. Getting this backwards would label every
# calibration a readiness check, which is worse than the bug being fixed.
ok(!$row{'run-false'}{preflight_only},'an explicit JSON false is not mistaken for a readiness pass');
is($row{'run-false'}{preflight_only},0,'and is normalized to 0');
is($row{'run-check'}{preflight_only},1,'a JSON true is normalized to 1');

# --- and carry it as a plain scalar ---
# The row is re-encoded into listing-cache.json. A JSON::PP::Boolean survives
# that round trip as a blessed object, which is not what the History renderer
# tests, so the row stores 0/1.
is(ref($row{'run-check'}{preflight_only}),'','preflight_only is a plain scalar, not a JSON boolean object');
is(ref($row{'run-cal'}{preflight_only}),'','and on the calibration row too');

# --- status alone must never be the discriminator ---
is($row{'run-check'}{status},$row{'run-cal'}{status},
 'both finish with the same status, so status cannot distinguish them');

# --- upgrading an old summary must not re-decode the manifest ---
# The trim path exists so an upgrade does not decode every run (72 of them take
# minutes on the appliance). Adding a row key must not quietly turn the whole
# store back into a rebuild, so this pins the cost as well as the value.
{
 my $dir=PGAutomation::run_dir('run-check');
 my $key=main::webui_automation_listing_key("$dir/run.json");
 PGAutomation::write_json_atomic("$dir/listing-cache.json",{version=>3,key=>$key,
  summary=>{id=>'run-check',queue_name=>'TV calibration queue',status=>'complete',created_at=>1}});
 my $reads=0;my $real=\&main::webui_automation_read_run;
 # Past the digest budget, which bounds the manifests one listing decodes.
 local $main::WEBUI_LISTING_DIGEST_BUDGET=0;
 local *main::webui_automation_read_run=sub {$reads++;$real->(@_)};
 my ($again)=grep { $_->{id} eq 'run-check' } @{main::webui_automation_list_runs()};
 is($reads,0,'a stale pre-v4 summary is trimmed without decoding the manifest');
 ok(exists $again->{preflight_only},'the trimmed row still carries the key, so its shape matches a fresh row');
}
{
 # An old summary cannot know the flag. Defaulting to 0 leaves a historical
 # readiness pass unlabeled -- exactly how it rendered before this change --
 # rather than relabeling it a calibration.
 my $stale=main::webui_automation_listing_upgrade({id=>'run-check',queue_name=>'q',status=>'complete'});
 is(ref($stale),'HASH','the upgrade still trims a summary that predates preflight_only');
 is($stale->{preflight_only},0,'and defaults the flag to 0 rather than guessing');
 my $fresh=main::webui_automation_listing_upgrade({id=>'run-check',queue_name=>'q',status=>'complete',preflight_only=>1});
 is($fresh->{preflight_only},1,'a summary that already carries it keeps the flag');
}

# --- the cache version was bumped, or none of the above reaches an existing Pi ---
cmp_ok($main::WEBUI_LISTING_CACHE_VERSION,'>=',4,'the listing cache version is bumped so existing caches are replaced');

done_testing();
