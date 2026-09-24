# History named every run by its queue ("Reference settings", the same for
# each run from that queue) and a run ID. Finding the last good HDR Filmmaker
# calibration took reading run.json and worker states over SSH. The listing
# now carries a digest of each run's jobs, and LG Calibration History entries
# carry the run that produced them. These are the properties that hold.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use JSON::PP ();
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";

my $store=tempdir(CLEANUP=>1);
$ENV{PGEN_AUTOMATION_DIR}=$store;
PGAutomation::ensure_store();
my $hist=tempdir(CLEANUP=>1);
$main::WEBUI_CAL_HIST_1D_DIR=$hist;

sub put {
 my ($path,$text)=@_;
 (my $dir=$path)=~s{/[^/]+\z}{};
 make_path($dir);
 open(my $fh,'>',$path) or die "$path: $!";
 print {$fh} $text;
 close($fh);
}

# --- targeted scalar reads from a worker state ---
{
 my $path="$store/state.json";
 put($path,'{"a":1.5,"b":"hdr10","c":true,"d":null,"e":{"a":2},"f":"q\\"x","n":[{"dup":1},{"dup":2}]}');
 my $got=main::webui_automation_state_scalars($path,qw(b c d f dup missing));
 is($got->{b},'hdr10','a string is read');
 is($got->{c},1,'a JSON true reads as 1');
 ok(!exists $got->{d},'a null is left unknown');
 is($got->{f},'q"x','escapes are undone');
 ok(!exists $got->{dup},'a key seen more than once is nested somewhere and left unknown');
 ok(!exists main::webui_automation_state_scalars($path,'a')->{a},'including a top-level key a nested one shares');
 is_deeply(main::webui_automation_state_scalars("$store/absent.json",'a'),{},'an absent file reads as nothing');
}

# --- one HDR10 job with a 1D and 3D result, as run 20260915-201855 saved it ---
my $t0=1789496337;
my $cal_run={id=>'run-hdr',token=>'t1',status=>'complete',queue_name=>'Reference settings',created_at=>$t0,
 created_at_iso=>'2026-09-15T20:18:57Z',started_at=>$t0,completed_at=>$t0+6600,
 items=>[{name=>'HDR10 Filmmaker',signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',tv_input=>'hdmi2',status=>'complete-with-warnings',
  stages=>{pre_readings=>0,calibration=>1,apply_all=>1,post_readings=>1},calibration=>{delta_e_formula=>'deitp'},
  checkpoints=>[{name=>'item-started',status=>'done',completed_at=>$t0+10},{name=>'greyscale-done',status=>'done'},
   {name=>'volume-done',status=>'done'},{name=>'item-complete',status=>'done',completed_at=>$t0+6500}]}]};
PGAutomation::write_json_atomic(PGAutomation::run_dir('run-hdr').'/run.json',$cal_run);
my $cal=PGAutomation::run_dir('run-hdr').'/items/0/calibration';
put("$cal/grey-state.json",'{"status":"complete","hdr20_1d_dpg_final_de":0.974503979702557,"hdr20_1d_dpg_best_de":"0.9745","delta_e_formula":"deitp",'
 .'"final_1d_lut_uploaded":true,"hdr20_1d_tonemap_peak_luminance":673.974035,"readings":[{"de":4.1},{"de":3.2}]}');
put("$cal/3d-state.json",'{"status":"complete","upload_status":"ok","upload":{"upload_verified":true},"upload_verified":true}');
# An SDR-style job whose white is written in exponent notation.
PGAutomation::write_json_atomic(PGAutomation::run_dir('run-sdr').'/run.json',{id=>'run-sdr',token=>'t4',status=>'complete',queue_name=>'q',created_at=>$t0-100,
 items=>[{name=>'SDR Filmmaker',signal_format=>'sdr',picture_mode=>'filmMaker',status=>'complete'}]});
put(PGAutomation::run_dir('run-sdr').'/items/0/calibration/grey-state.json','{"sdr_1d_dpg_final_de":8.4e-1,"calibrated_white_luminance":1.4087e2}');
put("$cal/20260915_214849_OLED65C1PUB_hdr10_matrix_hdrFilmMaker.bin",'lut');
put(PGAutomation::run_dir('run-hdr').'/items/0/post/greyscale-21.json','{}');

# Archives: one recorded with its run, one written before the 3D worker
# recorded it (inside the job's time window), and two that must not match.
put("$hist/a.json",'{"id":"1dfile:a","picture_mode":"hdrFilmMaker","signal_mode":"hdr10","variant":"","archived_at":'.($t0+3000).',"source_run":"run-hdr","dpg_data":[1,2,3]}');
put("$hist/b.json",'{"id":"1dfile:b","picture_mode":"hdrFilmMaker","signal_mode":"hdr10","variant":"smoothed","archived_at":'.($t0+6400).',"source_run":"","dpg_data":[1]}');
put("$hist/c.json",'{"id":"1dfile:c","picture_mode":"hdrFilmMaker","signal_mode":"hdr10","variant":"smoothed","archived_at":'.($t0+90000).',"source_run":"","dpg_data":[1]}');
put("$hist/d.json",'{"id":"1dfile:d","picture_mode":"filmMaker","signal_mode":"sdr","variant":"","archived_at":'.($t0+3000).',"source_run":"","dpg_data":[1]}');

# A readiness pass of the same job: status complete, no calibration.
PGAutomation::write_json_atomic(PGAutomation::run_dir('run-check').'/run.json',{id=>'run-check',token=>'t2',status=>'complete',
 queue_name=>'Reference settings',created_at=>$t0+7000,preflight_only=>JSON::PP::true,
 items=>[{name=>'HDR10 Filmmaker',signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',status=>'complete'}]});
# Three jobs, one never reached.
PGAutomation::write_json_atomic(PGAutomation::run_dir('run-multi').'/run.json',{id=>'run-multi',token=>'t3',status=>'stopped',
 queue_name=>'Reference settings',created_at=>$t0+8000,
 items=>[map {{name=>$_,signal_format=>'sdr',picture_mode=>'filmMaker'}} ('SDR Filmmaker','HDR10 Filmmaker','DV Filmmaker','HLG Cinema')]});

my %row=map { ($_->{id}=>$_) } @{main::webui_automation_list_runs()};
is_deeply($row{'run-hdr'}{digest},{job_count=>1,job_names=>['HDR10 Filmmaker'],status=>'complete-with-warnings',lut_1d=>1,lut_3d=>1,de=>0.974503979702557,formula=>'deitp'},
 'a one-job row carries its name, outcome, both LUTs and the final greyscale dE for its title');
ok($row{'run-check'}{preflight_only},'a readiness pass is still flagged for its title');
is_deeply($row{'run-check'}{digest}{job_names},['HDR10 Filmmaker'],'and names the job it checked');
is($row{'run-multi'}{digest}{job_count},4,'a multi-job row counts every job');
is_deeply($row{'run-multi'}{digest}{job_names},['SDR Filmmaker','HDR10 Filmmaker','DV Filmmaker'],'and names only the first three');
ok(!exists $row{'run-multi'}{digest}{de},'without one dE standing for several jobs');

my $digest=PGAutomation::decode_json(main::webui_automation_api('/api/automation/runs/run-hdr/digest','GET',''));
is($digest->{status},'ok','the digest route answers');
my ($job)=@{$digest->{jobs}};
is_deeply([@$job{qw(name signal picture_mode tv_input status)}],['HDR10 Filmmaker','hdr10','hdrFilmMaker','hdmi2','complete-with-warnings'],'the job says what it targeted and how it ended');
is_deeply($job->{stages},[qw(calibration apply_all post_readings)],'the stages that were asked for, in run order');
is($job->{de},0.974503979702557,'the final committed dE, not the best one seen');
is($job->{formula},'deitp','with its formula');
is($job->{peak_nits},673.974035,'the measured peak');
is($job->{post_readings},1,'post readings are counted from their files');
my %art=map { ($_->{id}=>$_) } @{$job->{artifacts}};
ok($art{'3d:20260915_214849_OLED65C1PUB_hdr10_matrix_hdrFilmMaker'},'the 3D LUT is named as LG Calibration History lists it');
is($art{'1dfile:a'}{inferred},0,'an archive recorded with this run is linked outright');
is($art{'1dfile:b'}{inferred},1,'one without a recorded run is matched inside the job window, and says so');
ok(!$art{'1dfile:c'},'an archive written long after the job is not claimed');
ok(!$art{'1dfile:d'},'nor one for another picture mode');

my ($multi)=grep { $_->{name} eq 'HLG Cinema' } @{main::webui_automation_run_digest('run-multi')->{jobs}};
is($multi->{status},'not-started','a job the run never reached says so');
is_deeply($multi->{stages},[qw(calibration apply_all)],'unset stages take the editor defaults');
my ($sdr)=@{main::webui_automation_run_digest('run-sdr')->{jobs}};
is($sdr->{de},0.84,'an SDR dE in exponent notation is read');
is($sdr->{peak_nits},140.87,'and so is its calibrated white, which stands in for a peak');
ok(!defined(main::webui_automation_run_digest('../etc')),'a run ID that is not a path component is refused');

# Reverse map for LG Calibration History.
my $links=PGAutomation::decode_json(main::webui_automation_api('/api/automation/artifact-links','GET',''))->{links};
is($links->{'1dfile:a'}{run_id},'run-hdr','a recorded archive maps to its run');
is($links->{'1dfile:a'}{job},'HDR10 Filmmaker','and job');
is($links->{'1dfile:b'}{inferred},1,'an inferred one keeps its flag');

# A second listing of an unchanged store reads no worker state or archive.
{
 my $scans=0;my $real=\&main::webui_automation_state_scalars;
 local *main::webui_automation_state_scalars=sub {$scans++;$real->(@_)};
 main::webui_automation_list_runs();
 is($scans,0,'digests come from the listing cache once built');
}

# --- the run ID reaches the archive the 3D worker's smoothing writes ---
# Automation starts the 3D worker with full_autocal_run_id and no run_id, so
# reading run_id alone left every smoothed archive's source_run empty.
{
 open(my $fh,'<',"$Bin/../usr/bin/meter_lg_3d_autocal.pl") or die $!;
 my $text=do { local $/; <$fh> };
 close($fh);
 my @ids=$text=~/archive_run_id\s*=>\s*\(([^)]*)\)/g;
 ok(@ids,'the 3D worker archives with a run ID');
 like($_,qr/full_autocal_run_id/,'and reads the automation run ID first') foreach(@ids);
 open($fh,'<',"$Bin/../usr/share/PGenerator/lg.pm") or die $!;
 $text=do { local $/; <$fh> };
 close($fh);
 like($text,qr/source_run\s*=>\s*\$meta->\{"source_run"\}/,'LG Calibration History lists each archive with its source run');
 like($text,qr/calibration-history-list:2/,'and the list cache is versioned so old lists are rebuilt');
}

done_testing();
