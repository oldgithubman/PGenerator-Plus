use strict;
use warnings;
no warnings qw(once redefine);
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
 # 18 Sep 2026: the check rows and snapshots are decoded once per file change,
 # not once per poll; an appended row must still appear on the next poll.
 my $again=main::webui_automation_job_detail($id,0);
 is_deeply($again->{checks},$detail->{checks},'an unchanged evidence file is served from the memo');
 is_deeply($again->{snapshots},$detail->{snapshots},'unchanged snapshots are served from the cache');
 open(my $append,'>>',"$dir/settings-checks.ndjson") or die $!;
 print {$append} "\n".PGAutomation::encode_json({key=>'contrast',expected=>80,observed=>80,verified=>1})."\n";
 close($append);
 is(scalar @{main::webui_automation_job_detail($id,0)->{checks}},2,'a newly appended evidence row is seen on the next poll');
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
 {
  # The live view does not say which sweep is running; the worker's state
  # names its type and point count, which is the series key the graphs use.
  $run->{active_stage}='pre-readings-done';PGAutomation::write_json_atomic($path,$run);
  local *main::webui_automation_fresh_worker=sub{return {type=>'colors',points=>30,status=>'running',readings=>[{Y=>5}]}};
  my $sweep=main::webui_automation_job_detail($id,0);
  is($sweep->{live}{key},'colors-30','a live sweep is keyed from the worker state');
  is($sweep->{live}{phase},'pre','in its phase');
  $run->{active_stage}='greyscale-done';PGAutomation::write_json_atomic($path,$run);
 }
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
# 18 Sep 2026: a completed job's detail was 472 KB per poll: the whole
# manifest item (94 KB, mostly checkpoint evidence and setting contracts),
# every check row with its capability profile identity (106 KB) and the
# worker states whole (313 KB, 110 KB of it an anchor history the page never
# reads). The view gets what it renders: identical page, a fifth the bytes.
{
 my $id='job-diet';my $dir=PGAutomation::item_dir($id,0);make_path("$dir/post","$dir/calibration");
 my $fat={name=>'Fat job',status=>'complete',signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',settings=>{brightness=>50},calibration=>{target_gamma=>'st2084'},target_gamma=>'st2084',target_gamut=>'p3d65',
  delta_e_formula=>'deitp',target_white=>{x=>0.3127,y=>0.329},manual_checks=>['TruMotion off'],warnings=>['w1'],stages=>{pre_readings=>1},panel_light=>{key=>'oledLight'},pre_series=>['greyscale-21'],post_series=>['greyscale-21'],
  color_format=>'0',max_bpc=>10,signal_range=>'2',template_notes=>'n',quality=>{ok=>1},
  setting_contracts=>{contrast=>'c'x3000},generation_profile=>{settings_capabilities=>{x=>'y'x4000}},capability_profile=>{hash=>'h'x64},preflight_contract=>{a=>'b'x400},best_available_settings=>{plan=>'p'x600},
  best_available_write_ack=>{x=>1},tv_input=>'HDMI_1',hazards=>{a=>1},hazard_capabilities=>{b=>1},hazard_restore=>{c=>1},device_identity=>{d=>1},supported_picture_keys=>[('k')x40],calibration_settings_recipe=>{e=>1},
  checkpoints=>[map {{name=>"cp$_",status=>'done',verified=>1,completed_at=>1000+$_,duration_seconds=>5,evidence=>{profile=>'e'x5000}}} 1..12],
  readiness=>{passed=>2,checks=>[{ok=>1,message=>'fine'},{ok=>0,level=>'warning',message=>'look'}]}};
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/run.json',{id=>$id,token=>'s',status=>'complete',
  items=>[$fat,{%$fat,name=>'Readiness failed',status=>'failed',failure=>{stage=>'job-readiness',message=>'The TV could not select the picture mode'}},{%$fat,name=>'Real rows'}]});
 my $snapshots=sub {
  my ($dir)=@_;
  make_path("$dir/post","$dir/calibration");
  PGAutomation::write_json_atomic("$dir/post/greyscale-21.json",{type=>'greyscale',points=>21,status=>'complete',steps=>[map {{ire=>$_*5}} 0..20],readings=>[map {{Y=>$_,X=>$_,Z=>$_,ire=>$_*5}} 0..20],
   signal_mode=>'hdr10',target_gamma=>'st2084',report_key=>'greyscale-21',automation_worker_id=>'w',worker_pid=>1,worker_start_ticks=>2,full_autocal_run_id=>$id});
  PGAutomation::write_json_atomic("$dir/calibration/grey-state.json",{status=>'running',readings=>[map {{Y=>$_,ire=>$_*4}} 0..25],steps=>[map {{ire=>$_*4}} 0..25],signal_mode=>'hdr10',target_gamma=>'st2084',
   calibration_target_context=>{signal_mode=>'hdr10'},lg_autocal_26_best_known=>{'10'=>{reading=>{Y=>1}}},current_name=>'Auto Cal 10%',current_ddc_target_ire=>10,current_ire=>10,current_step_ire=>10,patch_ire=>10,current_stimulus=>10,active_stimulus=>10,paired_current_name=>'10%',
   hdr20_1d_dpg_anchor_history=>[map {{pass=>$_,anchors=>[(0.5)x300]}} 1..40],hdr20_1d_dpg_data=>[(0.123456)x3072],activity_events=>[map {{t=>$_,m=>'e'x80}} 1..100],token=>'must-not-leak'});
  PGAutomation::write_json_atomic("$dir/calibration/3d-state.json",{status=>'complete',readings=>[{Y=>1}],steps=>[{name=>'red'}],method=>'matrix',
   automation_processing_checks=>[map {{key=>"k$_",reason=>'r'x200}} 1..300],upload=>{payload=>'u'x50000}});
 };
 $snapshots->($dir);
 open(my $fh,'>>',"$dir/settings-checks.ndjson") or die $!;
 print {$fh} PGAutomation::encode_json({key=>"setting$_",category=>'picture',expected=>50,observed=>50,verified=>JSON::PP::true(),result=>'verified',reason=>'TV readback matches the requested value',error_code=>'',
  checkpoint=>'c1',timestamp=>1789749261.9+$_,operation=>'readback',capability_profile_hash=>'8'x64,capability_profile_id=>'lg/effective/W23O/series/2026.09.18.1'})."\n" for 1..300;
 close($fh);
 my $detail=main::webui_automation_job_detail($id,0);
 my $bytes=length(PGAutomation::encode_json($detail));
 cmp_ok($bytes,'<',100000,"a completed job with 300 check rows and fat worker states is under 100 KB ($bytes)");
 for my $key (qw(setting_contracts generation_profile capability_profile preflight_contract best_available_settings best_available_write_ack tv_input hazards hazard_capabilities hazard_restore device_identity supported_picture_keys calibration_settings_recipe)) {
  ok(!exists $detail->{item}{$key},"item.$key is not sent");
 }
 for my $key (qw(name status signal_format picture_mode settings calibration target_gamma target_gamut delta_e_formula target_white manual_checks warnings stages panel_light pre_series post_series color_format max_bpc signal_range template_notes quality)) {
  ok(exists $detail->{item}{$key},"item.$key is kept");
 }
 is_deeply($detail->{item}{checkpoints}[0],{name=>'cp1',status=>'done',verified=>1,completed_at=>1001,duration_seconds=>5},'checkpoints keep their name, state and times, not their evidence');
 is(scalar(@{$detail->{item}{checkpoints}}),12,'and all of them');
 is_deeply($detail->{item}{readiness},{passed=>3,checks=>[]},'readiness keeps the count of passing checks; the failing ones travel once, as readiness issues');
 # The finished run is now served from its materialised live view, whose
 # readiness holds only the failing checks: the passed count no longer adds
 # the ok checks the manifest still lists. Nothing on the page reads it.
 my $failed_readiness=main::webui_automation_job_detail($id,1)->{item}{readiness};
 is_deeply($failed_readiness->{checks},[{ok=>0,level=>'warning',message=>'look'}],'a job that failed its own readiness stage keeps its failing checks, the one case the view reads them from the item');
 like($failed_readiness->{passed},qr/^\d+$/,'with a count of passing checks');
 is(scalar(@{$detail->{checks}}),300,'every check row is kept: the view lists and counts them all');
 is_deeply([sort keys %{$detail->{checks}[0]}],[qw(category checkpoint error_code expected key observed reason result timestamp verified)],'each row is trimmed to what the view reads');
 my %snap=map {($_->{phase}.'/'.$_->{key}=>$_->{snapshot})} @{$detail->{snapshots}};
 is_deeply([sort keys %snap],['calibration/3d','calibration/grey','post/greyscale-21'],'the saved sweeps and calibration states are all present');
 ok(!exists $snap{'calibration/grey'}{hdr20_1d_dpg_anchor_history} && !exists $snap{'calibration/grey'}{hdr20_1d_dpg_data} && !exists $snap{'calibration/grey'}{activity_events},'the 1D curve, anchor history and worker events stay with the artifact');
 ok(!exists $snap{'calibration/grey'}{token},'and nothing outside the allow list');
 is(scalar(@{$snap{'calibration/grey'}{readings}}),26,'the readings the chart draws are kept');
 is_deeply($snap{'calibration/grey'}{lg_autocal_26_best_known},{'10'=>{reading=>{Y=>1}}},'with the best-known readings the chart overlays');
 is($snap{'calibration/3d'}{method},'matrix','the 3D method that picks the chart is kept');
 ok(!exists $snap{'calibration/3d'}{automation_processing_checks} && !exists $snap{'calibration/3d'}{upload},'processing checks and the upload payload are not');
 is_deeply([sort keys %{$snap{'post/greyscale-21'}}],[qw(points readings signal_mode status steps target_gamma type)],'a series snapshot keeps its chart fields only');
 is_deeply([map {$_->{message}} @{$detail->{readiness_issues}}],[],'readiness issues are still scoped by job number');
 is_deeply([map {$snap{'calibration/grey'}{$_}} qw(current_name current_ddc_target_ire current_ire current_step_ire patch_ire current_stimulus active_stimulus paired_current_name)],['Auto Cal 10%',10,10,10,10,10,10,'10%'],
  'a state saved while running keeps the fields that name the patch in progress, so the chart hides its stale reading');
 # The view is built by selecting from the cached record, never by cloning
 # the item and deleting most of it afterwards.
 my $cloned=0;my $real_clone=\&PGAutomation::clone;
 {
  no warnings 'redefine';
  local *PGAutomation::clone=sub { $cloned++ if(ref($_[0]) eq 'HASH' && (exists $_[0]{setting_contracts} || exists $_[0]{checkpoints})); $real_clone->(@_) };
  main::webui_automation_job_detail($id,0);
 }
 is($cloned,0,'the view item is built from the cached record without cloning the evidence it drops');
 # The job that carried 781 rows on 18 Sep 2026 (its file also held the whole
 # queue's mode checks) measured 222 KB with every row kept; rows shaped like
 # its own are the honest bound, not the short synthetic ones above.
 my $real=PGAutomation::item_dir($id,2);$snapshots->($real);
 my @keys=qw(pictureMode brightness contrast color sharpness colorTemperature gamma colorGamut peakBrightness dynamicContrast superResolution noiseReduction mpegNoiseReduction smoothGradation realCinema truMotionMode blackLevel hdrDynamicToneMapping energySaving screenSaver autoPowerOff);
 my @points=qw(queue-preflight-mode job-start-mode c1 c4-mode c4 c5 c6 c6-confirm c7 c8 c8-stable c9 c10);
 my @reasons=('TV readback matches the requested value','Readback could not be verified for this control in this picture mode; the TV does not expose it through the API',
  'The verified 3D LUT controls gamut; the requested menu value is retained as the pre-calibration setup','TV-reported value differs from the requested value after the write was acknowledged');
 open(my $rows,'>>',"$real/settings-checks.ndjson") or die $!;
 for my $n (1..781) {
  my $verified=$n%7?1:0;
  print {$rows} PGAutomation::encode_json({capability_profile_hash=>'8cd6a98767c8689772609f0114d5e5066eb3954d8a4c6404c893852b03cec3e2',capability_profile_id=>'lg/effective/W23O/series/2026.09.18.1',
   category=>'picture',checkpoint=>$points[$n%@points],error_code=>$verified?'':'readback-mismatch',expected=>$n%3?'auto':50,key=>$keys[$n%@keys],observed=>$verified?($n%3?'auto':50):($n%3?'wide':55),
   operation=>$n%5?'readback':'write',reason=>$reasons[$n%@reasons],result=>$verified?'verified':'mismatch',timestamp=>1789749261.93441+$n*7.3,verified=>$verified?JSON::PP::true():JSON::PP::false()})."\n";
 }
 close($rows);
 my $heavy=main::webui_automation_job_detail($id,2);
 is(scalar(@{$heavy->{checks}}),781,'every one of the 781 rows is kept');
 my ($total,$rows_bytes,$raw)=(length(PGAutomation::encode_json($heavy)),length(PGAutomation::encode_json($heavy->{checks})),-s "$real/settings-checks.ndjson");
 cmp_ok($rows_bytes,'<',$raw*0.8,"the trimmed rows are at least a fifth smaller than the saved lines ($rows_bytes of $raw)");
 cmp_ok($total,'<',250000,"a 781-row job is under 250 KB with every row kept ($total)");
 cmp_ok($total-$rows_bytes,'<',20000,'and everything but the rows is under 20 KB');
}
# 19 Sep 2026: a six-job manifest is 612 KB, so an eleven-job one passes the
# shared cache's per-file ceiling and was decoded and deep-copied on every
# job-detail poll. The poll now reads the live view for the run and the
# job's own record for the job; the manifest only when the record is gone.
{
 my $id='job-record';my $rdir=PGAutomation::run_dir($id);
 my @jobs=map {{name=>"Job $_",status=>$_==0?'running':'queued',signal_format=>'sdr',settings=>{brightness=>50},padding=>'p'x40000}} 0..10;
 # The records are written before the runner claims job 3: the claim, its
 # checkpoints and the apply-to-all outcome reach the manifest only.
 for my $n (0..10) { PGAutomation::write_json_atomic(PGAutomation::item_dir($id,$n).'/item.json',{%{$jobs[$n]},name=>"Record $n"}); }
 $jobs[3]={%{$jobs[3]},status=>'running',checkpoint=>'item-started',checkpoint_status=>'done',checkpoints=>[{name=>'item-started',status=>'done',completed_at=>1,evidence=>{e=>'x'x100}},{name=>'apply-all-done',status=>'done',completed_at=>2}]};
 my $apply_all={outcome=>'sent-unconfirmed',confirmation_unavailable=>JSON::PP::true(),confirmed=>JSON::PP::false(),message=>'Confirmation unavailable',generation_profile=>{big=>'g'x40000}};
 PGAutomation::write_json_atomic(PGAutomation::item_dir($id,$_).'/apply-all.json',$apply_all) for 3,4;
 my $manifest={id=>$id,token=>'rec',status=>'running',active_item=>3,active_stage=>'tv-setup-verified',stage_started_at=>time(),items=>\@jobs,readiness=>{checks=>[{item_number=>0,ok=>0,message=>'Look at job 1'}]}};
 PGAutomation::write_json_atomic("$rdir/run.json",$manifest);
 PGAutomation::write_json_atomic("$rdir/status.json",PGAutomation::compact_run($manifest));
 local $PGAutomation::JSON_CACHE_MAX_BYTES=(-s "$rdir/run.json")-1;
 my %reads;my $real_read=\&PGAutomation::read_json_file;
 no warnings 'redefine';
 local *PGAutomation::read_json_file=sub { my ($p)=@_;$reads{$p=~m{/([^/]+)$} ? $1 : $p}++;$real_read->(@_) };
 my $detail=main::webui_automation_job_detail($id,3);
 is($detail->{item}{name},'Record 3','the job comes from its own record');
 is($detail->{run_status},'running','and the run state from the live view');
 is($detail->{item}{status},'running','as does the job\'s state: a claim the runner wrote to the manifest only, while the record still says queued');
 is($detail->{item}{checkpoint},'item-started','with its checkpoint');
 is_deeply($detail->{item}{checkpoints},[{name=>'item-started',status=>'done',completed_at=>1},{name=>'apply-all-done',status=>'done',completed_at=>2}],'and its checkpoint list, compacted');
 is_deeply($detail->{item}{'apply-all'},{outcome=>'sent-unconfirmed',confirmation_unavailable=>JSON::PP::true(),confirmed=>JSON::PP::false(),message=>'Confirmation unavailable'},'the apply-to-all outcome reaches the view without its capability profile');
 ok(!exists main::webui_automation_job_detail($id,4)->{item}{'apply-all'},'an outcome left by an earlier attempt, with no apply-all-done checkpoint standing, is not shown');
 is_deeply([map {$_->{message}} @{main::webui_automation_job_detail($id,0)->{readiness_issues}}],['Look at job 1'],'run-level readiness issues still reach the job from the live view');
 %reads=();
 main::webui_automation_job_detail($id,3);
 is($reads{'run.json'}||0,0,'a second poll of a manifest over the cache ceiling does not decode it');
 is($reads{'item.json'}||0,0,'nor the record');
 is($reads{'status.json'}||0,0,'nor the live view');
 unlink(PGAutomation::item_dir($id,3).'/item.json');
 %reads=();
 is(main::webui_automation_job_detail($id,3)->{item}{name},'Job 3','a job without a record falls back to the manifest');
 ok($reads{'run.json'},'which is decoded for it');
 ok(!main::webui_automation_job_detail($id,11),'a job the live view does not list is rejected');
}
# The check-row memo is bounded by bytes held as well as by entries.
{
 my $id='memo-budget';
 my @files=map { my $d=PGAutomation::item_dir($id,$_);make_path($d);my $p="$d/settings-checks.ndjson";
  PGAutomation::append_line_locked($p,join('',map { PGAutomation::encode_json({key=>"k$_",expected=>1,observed=>1,verified=>1})."\n" } 1..50));$p } 0..2;
 local $main::WEBUI_JOB_CHECKS_MEMO_BUDGET=(-s $files[0])+(-s $files[1]);
 my $decoded=0;my $real=\&main::webui_automation_job_checks_read;
 no warnings 'redefine';
 local *main::webui_automation_job_checks_read=sub { $decoded++;$real->(@_) };
 main::webui_automation_job_checks_cached($_) for @files[0,1];
 main::webui_automation_job_checks_cached($files[0]);
 main::webui_automation_job_checks_cached($files[2]);
 ok(!exists $main::WEBUI_JOB_CHECKS_MEMO{$files[1]},'over the byte budget the least recently used file leaves the memo');
 ok(exists $main::WEBUI_JOB_CHECKS_MEMO{$files[0]} && exists $main::WEBUI_JOB_CHECKS_MEMO{$files[2]},'the others stay');
 my $held=0;$held+=$main::WEBUI_JOB_CHECKS_MEMO{$_}{bytes} for keys %main::WEBUI_JOB_CHECKS_MEMO;
 cmp_ok($held,'<=',$main::WEBUI_JOB_CHECKS_MEMO_BUDGET,'and the memo stays within its budget');
 $decoded=0;main::webui_automation_job_checks_cached($files[0]);
 is($decoded,0,'a file still in the memo is not decoded again');
 main::webui_automation_job_checks_cached($files[1]);
 is($decoded,1,'an evicted one is');
}
ok(!main::webui_automation_job_detail($id,99),'invalid job rejected');
ok(!main::webui_automation_job_detail('../no',0),'invalid run rejected');
my $tmp="$dir/worker.json";PGAutomation::write_json_atomic($tmp,$worker);
ok(main::webui_automation_fresh_worker($tmp,time()-5),'fresh worker accepted');
ok(!main::webui_automation_fresh_worker($tmp,time()+5),'old worker rejected');
ok(!main::webui_automation_fresh_worker($tmp,0),'unknown stage start rejected');
done_testing();
