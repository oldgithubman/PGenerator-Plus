use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";

# A start hands the queue to the runner and the card then follows the run.
# When that run is deleted from History (or never written), the "started"
# preflight record was the only thing left: the card claimed "Launching
# calibration runner" for ever and offered no dismissal, because dismissal is
# only allowed for ready/blocked/failed/interrupted.
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();

my $preflight=PGAutomation::base_dir().'/preflight.json';
my $write=sub {
 my ($state)=@_;
 PGAutomation::write_json_atomic($preflight,$state,0664) or die "cannot write preflight";
 return main::webui_automation_preflight_status();
};
my $now=PGAutomation::now();
my $base={id=>'req-1',status=>'started',intent=>'start',queue_name=>'Test Queue',
 message=>'Runner starting; all queued jobs will be checked before calibration',
 started_at=>$now-5,updated_at=>$now,completed_at=>$now,items=>[],issues=>[]};

my $run_id='20260917-225038-e6bbe0';
make_path(PGAutomation::run_dir($run_id).'/items');
my $live=$write->({%$base,run_id=>$run_id});
is($live->{status},'started','a start whose run exists still reports the launch');
is($live->{error_code}||'','','a live launch carries no error code');

remove_tree(PGAutomation::run_dir($run_id));
my $deleted=$write->({%$base,run_id=>$run_id});
is($deleted->{status},'interrupted','a start whose run was deleted is interrupted, not launching');
is($deleted->{error_code},'preflight-run-missing','the deleted run is named by its own error code');
like($deleted->{message},qr/no longer on the generator/,'the message says the run is gone');
# interrupted is one of the four statuses the dismissal endpoint accepts, so
# the operator can clear the card without an execution unlock.
like($deleted->{status},qr/^(?:ready|blocked|failed|interrupted)$/,'the recovered status is dismissable');

my $fresh=$write->({%$base,updated_at=>$now,completed_at=>$now});
is($fresh->{status},'started','a start with no run id yet is left alone inside the launch window');
my $old=$write->({%$base,updated_at=>$now-200,completed_at=>$now-200});
is($old->{status},'interrupted','a start with no run id and no progress for two minutes is interrupted');

for my $status (qw(ready blocked failed)) {
 my $other=$write->({%$base,status=>$status,run_id=>$run_id});
 is($other->{status},$status,"a $status record is untouched by the missing-run rule");
 is($other->{error_code}||'','',"a $status record keeps its own error code");
}

# The card offers Dismiss for the recovered status, so the endpoint must accept
# it: it used to read the raw file, where the status is still "started".
{
 no warnings 'redefine';
 local *main::webui_automation_read_execution=sub { return undef; };
 $write->({%$base,run_id=>$run_id});
 my $refused=main::webui_automation_dismiss_readiness({request_id=>'nope'});
 like($refused,qr/readiness-changed/,'a dismissal for another attempt is still refused');
 my $json=main::webui_automation_dismiss_readiness({request_id=>'req-1'});
 like($json,qr/"status"\s*:\s*"ok"/,'a start whose run vanished can be dismissed');
 my $marker=PGAutomation::read_json_file(PGAutomation::base_dir().'/preflight-dismissed.json');
 is(($marker||{})->{id},'req-1','the dismissal marker names the dismissed attempt');
 make_path(PGAutomation::run_dir($run_id).'/items');
 $write->({%$base,run_id=>$run_id});
 my $live_json=main::webui_automation_dismiss_readiness({request_id=>'req-1'});
 like($live_json,qr/automation-active/,'a real launch in progress is never dismissable');
 remove_tree(PGAutomation::run_dir($run_id));
}

my $checking=$write->({%$base,status=>'checking',updated_at=>$now-200,completed_at=>undef});
is($checking->{status},'interrupted','the existing stale-checking rule still applies');
is($checking->{error_code},'preflight-stale','stale checking keeps its own error code');

done_testing();
