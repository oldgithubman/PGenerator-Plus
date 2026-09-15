use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
my $id='job-detail-test';
my $dir=PGAutomation::item_dir($id,0);
make_path("$dir/pre","$dir/calibration");
my $run={id=>$id,token=>'secret',status=>'running',active_item=>0,active_stage=>'greyscale-done',stage_started_at=>time()-5,items=>[{name=>'First',status=>'running',token=>'secret',pre_series=>['greyscale-21']},{name=>'Second',status=>'queued'}]};
my $path=PGAutomation::run_dir($id).'/run.json';
$run->{readiness}={checks=>[{item_number=>0,ok=>0,message=>'TV cannot expose AI Picture'},{item_number=>1,ok=>0,message=>'Other job only'}]};
PGAutomation::write_json_atomic($path,$run);
PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',{owner=>'automation',run_id=>$id,token=>'secret'});
PGAutomation::write_json_atomic("$dir/pre/greyscale-21.json",{readings=>[{Y=>100}]});
PGAutomation::append_line_locked("$dir/settings-checks.ndjson",PGAutomation::encode_json({key=>'brightness',expected=>50,observed=>50,verified=>1})."\n{partial");
my $worker={full_autocal_run_id=>$id,token=>'must-not-leak',readings=>[{Y=>90}],status=>'running',message=>'Retrying invalid measurement',measurement_retry=>{patch=>'5%',attempt=>2,limit=>4},
 color_format=>'1',max_bpc=>10,signal_range=>'1',pattern_signal_range=>'1',transport_signal_range=>'1',dv_map_mode=>'2',
 calibration_target_context=>{signal_mode=>'sdr',target_gamma=>'2.4'},sdr_1d_dpg_peak_ire=>109};
{
 no warnings 'redefine';
 local *main::webui_automation_fresh_worker=sub{return $worker};
 my $detail=main::webui_automation_job_detail($id,0);
 is($detail->{item}{name},'First','selected job returned');
 ok(!exists $detail->{item}{token},'item token removed');
 is(scalar @{$detail->{checks}},1,'complete evidence lines survive an in-progress append');
 is_deeply([map {$_->{message}} @{$detail->{readiness_issues}}],['TV cannot expose AI Picture'],'manual readiness limitations are scoped to selected job');
 is($detail->{snapshots}[0]{phase},'pre','before readings returned');
 is($detail->{live}{snapshot}{readings}[0]{Y},90,'owned worker measurements returned');
 is($detail->{live}{snapshot}{message},'Retrying invalid measurement','live graph detail carries current activity');
 is($detail->{live}{snapshot}{measurement_retry}{attempt},2,'live graph detail carries bounded retry state');
 for my $field (qw(color_format max_bpc signal_range pattern_signal_range transport_signal_range dv_map_mode calibration_target_context sdr_1d_dpg_peak_ire)) {
  is_deeply($detail->{live}{snapshot}{$field},$worker->{$field},"live graph preserves $field");
 }
 ok(!exists $detail->{live}{snapshot}{token},'worker response is allowlisted');
 ok(!main::webui_automation_job_detail($id,1)->{live},'pending job never borrows active worker');
 $worker->{full_autocal_run_id}='another-run';
 ok(!main::webui_automation_job_detail($id,0)->{live},'another run worker rejected');
 $worker->{full_autocal_run_id}=$id;
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',{owner=>'automation',run_id=>$id,token=>'wrong'});
 ok(!main::webui_automation_job_detail($id,0)->{live},'wrong execution owner token rejected');
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',{owner=>'automation',run_id=>$id,token=>'secret'});
 $run->{status}='paused';PGAutomation::write_json_atomic($path,$run);
 ok(!main::webui_automation_job_detail($id,0)->{live},'paused job shows saved data only');
 $run->{status}='running';PGAutomation::write_json_atomic($path,$run);
 local *main::webui_automation_fresh_worker=sub{$run->{active_item}=1;PGAutomation::write_json_atomic($path,$run);return $worker};
 ok(!main::webui_automation_job_detail($id,0)->{live},'job transition during read discards live snapshot');
}
ok(!main::webui_automation_job_detail($id,99),'invalid job rejected');
ok(!main::webui_automation_job_detail('../no',0),'invalid run rejected');
my $tmp="$dir/worker.json";PGAutomation::write_json_atomic($tmp,$worker);
ok(main::webui_automation_fresh_worker($tmp,time()-5),'fresh worker accepted');
ok(!main::webui_automation_fresh_worker($tmp,time()+5),'old worker rejected');
ok(!main::webui_automation_fresh_worker($tmp,0),'unknown stage start rejected');
done_testing();
