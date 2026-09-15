use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
my $path=PGAutomation::base_dir().'/preflight.json';
my $state={id=>'old-check',status=>'blocked',started_at=>1,completed_at=>2,updated_at=>2,
 checks=>[{name=>'lg-paired',ok=>0,message=>'TV disconnected'}],events=>[{message=>'TV disconnected',time=>2}]};
sub save {PGAutomation::write_json_atomic($path,$state)}
sub dismiss {PGAutomation::decode_json(main::webui_automation_api('/api/automation/readiness/dismiss','POST',PGAutomation::encode_json({request_id=>$_[0]||'old-check'})))}
sub current {PGAutomation::decode_json(main::webui_automation_api('/api/automation/runs/current','GET',''))}
save();my $original=PGAutomation::read_raw($path);
is(dismiss('another-check')->{error_code},'readiness-changed','stale dismiss cannot hide another attempt');
is(dismiss()->{status},'ok','completed failed check can be dismissed');
ok(!defined(current()->{preflight}),'banner stays dismissed on a new status request');
ok(!defined(current()->{execution}),'dismissal never claims or releases execution');
is(PGAutomation::read_raw($path),$original,'original evidence retained byte-for-byte');
ok(@{current()->{activity}{entries}},'saved activity remains available');
is(dismiss()->{status},'ok','dismissal is idempotent');
$state->{id}='new-check';save();
is(current()->{preflight}{id},'new-check','new check is never hidden by an earlier dismissal');
$state->{id}='old-check';$state->{started_at}=3;save();
ok(defined(current()->{preflight}),'even a reused request ID with a new start time remains visible');
for my $status(qw(checking started)){
 $state->{status}=$status;save();
 is(dismiss()->{error_code},'automation-active',"cannot dismiss $status check");
}
$state->{status}='blocked';save();
for my $status(qw(starting running paused interrupted stopping completing)){
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',{status=>$status,run_id=>'owned'});
 is(dismiss()->{error_code},'automation-active',"cannot dismiss during $status calibration");
}
done_testing();
