# Regression for PR 14 test report P3 and P33: the History list and the LG
# Calibration History list stop re-decoding unchanged files, and starting a
# batch no longer holds the request for the TV checks the runner repeats.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

# ---- P3: automation History list
{
 my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 for my $n (1..3) {
  PGAutomation::write_json_atomic(PGAutomation::run_dir("run-$n").'/run.json',{id=>"run-$n",token=>"t$n",status=>'complete',
   queue_name=>"Queue $n",created_at=>$n,items=>[{name=>"Job $n",signal_format=>'sdr',status=>'complete'}]});
 }
 my $reads=0;my $real=\&main::webui_automation_read_run;
 local *main::webui_automation_read_run=sub {$reads++;$real->(@_)};
 my $first=main::webui_automation_list_runs();
 is(scalar(@$first),3,'every run is listed');
 is($reads,3,'the first listing reads each manifest');
 ok(-f PGAutomation::run_dir('run-1').'/listing-cache.json','a summary is kept beside each manifest');
 $reads=0;
 my $second=main::webui_automation_list_runs();
 is($reads,0,'an unchanged store is listed without decoding any manifest');
 is_deeply($second,$first,'and the listing is identical');
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-2').'/run.json',{id=>'run-2',token=>'t2',status=>'failed',
  queue_name=>'Queue 2',created_at=>2,items=>[{name=>'Job 2',signal_format=>'sdr',status=>'failed'}],failure=>{stage=>'x',message=>'boom'}});
 $reads=0;
 my ($changed)=grep {$_->{id} eq 'run-2'} @{main::webui_automation_list_runs()};
 is($reads,1,'only the changed manifest is decoded again');
 is($changed->{status},'failed','and its new state is listed');
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-3').'/listing-cache.json',{key=>'stale',summary=>{id=>'run-3',status=>'bogus'}});
 my ($rebuilt)=grep {$_->{id} eq 'run-3'} @{main::webui_automation_list_runs()};
 is($rebuilt->{status},'complete','a summary for a different manifest version is never used');
 # Round 3: the summary write never creates a run directory (a run deleted
 # while it was being listed must not come back holding only its cache).
 my $gone=PGAutomation::run_dir('run-gone');
 ok(!main::webui_automation_write_listing_cache($gone,{key=>'k',summary=>{id=>'run-gone'}}),'no summary is written for a run that no longer exists');
 ok(!-e $gone,'and its directory is not recreated');
 opendir(my $rd,PGAutomation::run_dir('run-1'));my @tmp=grep {/\.tmp\z/} readdir($rd);closedir($rd);
 is(scalar(@tmp),0,'no temporary summary files are left behind');
 {
  local *Time::HiRes::stat=sub {die "no hires stat\n"};
  like(main::webui_automation_listing_key(PGAutomation::run_dir('run-1').'/run.json'),qr/\A\d+:\d+:\d+\z/,'the manifest key falls back to the core stat when the high-resolution one fails');
 }
}

# ---- 18 Sep 2026: the History list carries one row per run, not the jobs
# with their checks, warnings and checkpoints (72 runs listed as 588 KB in
# 3.7 s), and a second listing in the same worker decodes nothing.
{
 my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 my @checks=map {{ok=>($_%9?1:0),level=>'warning',name=>"check-$_",message=>"Setting $_ ".('detail 'x8),time=>$_}} 1..60;
 my $items=[map {{name=>"Job $_",signal_format=>($_%2?'hdr10':'sdr'),picture_mode=>'filmMaker',status=>$_==1?'failed':'complete-with-warnings',readiness=>{passed=>3,checks=>\@checks},warnings=>['a','b'],
  checkpoints=>[map {{name=>"c$_",status=>'done',evidence=>{x=>'y'x500}}} 1..12],
  $_==1?(failure=>{stage=>'post-readings-done',message=>'Meter read failed',error_code=>'meter-read',detail=>{big=>'z'x2000}}):()}} 0..5];
 for my $n (1..70) {
  PGAutomation::write_json_atomic(PGAutomation::run_dir(sprintf('run-%02d',$n)).'/run.json',{id=>sprintf('run-%02d',$n),token=>"t$n",status=>'failed',queue_name=>"Queue $n",
   created_at=>$n,created_at_iso=>'2026-09-18T10:00:00Z',completed_at=>$n+100,items=>$items,failure=>{stage=>'post-readings-done',message=>'Meter read failed',error_code=>'meter-read',detail=>{big=>'z'x2000}}});
 }
 my $list=main::webui_automation_list_runs();
 is(scalar(@$list),70,'seventy runs are listed');
 is($list->[0]{queue_name},'Queue 70','newest first');
 is_deeply([sort keys %{$list->[0]}],[qw(completed_at created_at created_at_iso failure id queue_name status)],'a run row holds what the History row renders and nothing of the jobs');
 is_deeply($list->[0]{failure},{stage=>'post-readings-done',message=>'Meter read failed',error_code=>'meter-read'},'the failure keeps its stage, message and code');
 my $public=main::webui_automation_public_run(PGAutomation::read_json_file(PGAutomation::run_dir('run-70').'/run.json'));
 is_deeply($list->[0],{map { ($_=>$public->{$_}) } qw(id queue_name status created_at created_at_iso completed_at failure)},'a row says what the live view says of the run');
 my $bytes=length(PGAutomation::encode_json({status=>'ok',runs=>$list}));
 cmp_ok($bytes,'<',60000,"seventy six-job runs list under 60 KB ($bytes)");
 my $cache=PGAutomation::read_json_file(PGAutomation::run_dir('run-01').'/listing-cache.json');
 is($cache->{version},$main::WEBUI_LISTING_CACHE_VERSION,'the summary beside the manifest carries the format version');
 # The first listing of a store whose summaries exist decodes each once; the
 # next in the same worker decodes nothing.
 my $decoded=0;my $real_read=\&PGAutomation::read_json_file;
 {
  local *PGAutomation::read_json_file=sub {$decoded++;$real_read->(@_)};
  main::webui_automation_list_runs();
  is($decoded,70,'a worker reads each saved summary once');
  $decoded=0;
  my $started=Time::HiRes::time();
  my $again=main::webui_automation_list_runs();
  my $took=Time::HiRes::time()-$started;
  is($decoded,0,'and lists the unchanged store again without decoding a file');
  is_deeply($again,$list,'with the same rows');
  cmp_ok($took,'<',0.3,sprintf('in under 0.3 s (%.3f s)',$took));
 }
 # A summary in the first format for the same manifest is trimmed in place;
 # one for another manifest version is rebuilt from the manifest.
 my $key=main::webui_automation_listing_key(PGAutomation::run_dir('run-01').'/run.json');
 my $old={id=>'run-01',queue_name=>'Queue 1',status=>'failed',created_at=>1,created_at_iso=>'2026-09-18T10:00:00Z',completed_at=>101,failure=>{stage=>'post-readings-done',message=>'Meter read failed',error_code=>'meter-read'},
  items=>[map { main::webui_automation_item_summary($_) } @$items]};
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-01').'/listing-cache.json',{key=>$key,summary=>$old});
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-02').'/listing-cache.json',{key=>'older',summary=>$old});
 my $reads=0;my $real=\&main::webui_automation_read_run;
 {
  local *main::webui_automation_read_run=sub {$reads++;$real->(@_)};
  my %by_id=map {($_->{id}=>$_)} @{main::webui_automation_list_runs()};
  is($reads,1,'only the summary for a changed manifest is rebuilt from the manifest');
  is_deeply($by_id{'run-01'},$list->[-1],'a first-format summary is trimmed in place to the row fields');
  is_deeply($by_id{'run-02'},$list->[-2],'the rebuilt one carries the same');
 }
 is(PGAutomation::read_json_file(PGAutomation::run_dir('run-01').'/listing-cache.json')->{version},$main::WEBUI_LISTING_CACHE_VERSION,'the trimmed summary replaces the old one on disk');
 cmp_ok(-s PGAutomation::run_dir('run-01').'/listing-cache.json','<',2000,'and is a fraction of its size');
 # A first-format summary that does not hold a row is rebuilt from the manifest.
 my $key3=main::webui_automation_listing_key(PGAutomation::run_dir('run-03').'/run.json');
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-03').'/listing-cache.json',{key=>$key3,summary=>{%$old,id=>''}});
 my $key4=main::webui_automation_listing_key(PGAutomation::run_dir('run-04').'/run.json');
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-04').'/listing-cache.json',{key=>$key4,summary=>{%$old,id=>'run-04',failure=>'boom'}});
 $reads=0;
 {
  local *main::webui_automation_read_run=sub {$reads++;$real->(@_)};
  my %by_id=map {($_->{id}=>$_)} @{main::webui_automation_list_runs()};
  is($reads,2,'a first-format summary without a run id, or with a failure that is not a record, is rebuilt from the manifest');
  is_deeply($by_id{'run-03'},$list->[-3],'and lists the run as the manifest says');
  is_deeply($by_id{'run-04'},$list->[-4],'for both');
 }
 ok(!defined(main::webui_automation_listing_upgrade({queue_name=>'No id'})),'no run id, no row');
 ok(!defined(main::webui_automation_listing_upgrade({id=>'x',failure=>['not','a','record']})),'a failure that is not a record, no row');
}

# ---- P3: LG Calibration History list
{
 my $root=tempdir(CLEANUP=>1);
 make_path(map {"$root/$_"} qw(runs luts history/1d history/dv));
 my $save=sub {my ($path,$data)=@_;open my $f,'>',"$root/$path" or die $!;print {$f} main::lg_encode_json($data);close $f;};
 $save->('history/1d/a.json',{picture_mode=>'filmMaker',signal_mode=>'sdr',dpg_data=>[(0)x3072]});
 open my $source,'<',"$Bin/../usr/share/PGenerator/lg.pm" or die $!;
 my $text=do {local $/;<$source>};close $source;
 my ($subs)=$text=~/(sub _lg_cal_hist_fingerprint \{.*?)(?=\nsub webui_lg_calibration_history_download)/s;
 die 'History list source not found' if !$subs;
 eval 'package main; {my $_lg_cal_hist_runs=q{'.$root.'/runs};my $_lg_cal_hist_luts=q{'.$root.'/luts};my $_lg_cal_hist_dir=q{'.$root.'/history};'.$subs.'}';die $@ if $@;
 my $reads=0;my $real=\&main::_lg_cal_hist_read_json_file;
 local *main::_lg_cal_hist_read_json_file=sub {$reads++;$real->(@_)};
 my $first=main::webui_lg_calibration_history_list();
 like($first,qr/"id":"1dfile:a"/,'the archive is listed');
 ok($reads>0,'the first listing decodes the archive');
 $reads=0;
 is(main::webui_lg_calibration_history_list(),$first,'an unchanged archive set returns the same list');
 is($reads,0,'without decoding any archive');
 Time::HiRes::sleep(0.02);
 $save->('history/1d/b.json',{picture_mode=>'expert1',signal_mode=>'sdr',dpg_data=>[(1)x3072]});
 $reads=0;
 my $grown=main::webui_lg_calibration_history_list();
 like($grown,qr/"id":"1dfile:b"/,'a new archive appears');
 is($reads,1,'and only the new archive is decoded (unchanged files come from the per-file memo)');
 # Round 3: a hidden archive name still changes the fingerprint.
 my $before=main::_lg_cal_hist_fingerprint();
 Time::HiRes::sleep(0.02);
 $save->('history/1d/.c.json',{picture_mode=>'expert2',signal_mode=>'sdr',dpg_data=>[(2)x3072]});
 isnt(main::_lg_cal_hist_fingerprint(),$before,'an archive whose name starts with a dot changes the fingerprint');
 $grown=main::webui_lg_calibration_history_list();
 like($grown,qr/"id":"1dfile:\.c"/,'and it is listed straight away');
 # Round 3: a torn cache body under the right fingerprint is never served.
 my $fp=main::_lg_cal_hist_fingerprint();
 open my $torn,'>',"$root/history.list-cache" or die $!;print {$torn} "$fp\n{\"status\":\"ok\",\"items\":[{\"id\":\"x\"}}\n";close $torn;
 is(main::webui_lg_calibration_history_list(),$grown,'a torn cache body is rebuilt, not served');
 # Round 4: the disk cache itself is served (not just the per-file memo).
 my $uncached=0;my $real_uncached=\&main::_lg_cal_hist_list_uncached;
 {
  local *main::_lg_cal_hist_list_uncached=sub {$uncached++;$real_uncached->(@_)};
  main::webui_lg_calibration_history_list();
  $uncached=0;
  main::webui_lg_calibration_history_list();
  is($uncached,0,'an unchanged archive set is answered from the disk cache without rebuilding the list');
  # Accented titles are sent as UTF-8 and still served from the disk cache.
  Time::HiRes::sleep(0.02);
  $save->('luts/cafe.json',{title=>"Caf\x{e9} HDR",picture_mode=>'hdrFilmMaker',signal_mode=>'hdr10'});
  open my $bin,'>',"$root/luts/cafe.bin" or die $!;print {$bin} 'lut';close $bin;
  my $accented=main::webui_lg_calibration_history_list();
  ok(!utf8::is_utf8($accented),'the list body is bytes, ready to send');
  my ($item)=grep {$_->{id} eq '3d:cafe'} @{JSON::PP::decode_json($accented)->{items}};
  is($item->{label},"Caf\x{e9} HDR",'an accented title decodes correctly');
  $uncached=0;
  is(main::webui_lg_calibration_history_list(),$accented,'and the same body comes back');
  is($uncached,0,'from the disk cache');
 }
 # Round 4: the memo keeps only what the list reads, and forgets removed files.
 make_path("$root/runs/run-9");
 $save->('runs/run-9/grey-state.json',{final_1d_lut_uploaded=>JSON::PP::true,hdr20_1d_dpg_data=>[(0.5)x3072],readings=>[map {{ire=>$_,Y=>$_*2}} 1..500],
  picture_mode=>'hdrFilmMaker',signal_mode=>'hdr10',nested=>{deeper=>{deepest=>{gone=>1},kept=>2}}});
 my $lite=main::_lg_cal_hist_read_json_lite("$root/runs/run-9/grey-state.json");
 is(scalar(@{$lite->{hdr20_1d_dpg_data}}),3072,'a 1D curve keeps its length for the list check');
 ok(!grep({defined} @{$lite->{hdr20_1d_dpg_data}}),'but not its values');
 is_deeply($lite->{readings},[],'readings are dropped');
 is($lite->{picture_mode},'hdrFilmMaker','scalars the list shows are kept');
 is($lite->{nested}{deeper}{kept},2,'two levels of nested settings are kept');
 ok(!exists $lite->{nested}{deeper}{deepest},'deeper structures are dropped');
 like(main::webui_lg_calibration_history_list(),qr/"id":"1d:run-9"/,'the run is listed from its trimmed state');
 ok((grep {m{/runs/run-9/grey-state\.json\z}} main::_lg_cal_hist_lite_memo_paths()),'its state is remembered');
 # A non-ASCII picture mode read from a run's stage log is encoded once.
 make_path("$root/runs/run-dv");
 $save->('runs/run-dv/dv-profile-measurements.json',{measurements=>{white_luminance=>700}});
 open my $stages,'>',"$root/runs/run-dv/stages.ndjson" or die $!;
 print {$stages} qq({"stage":"dv_profile_upload","ok":true,"picture_mode":"Caf\xc3\xa9 DV"}\n);close $stages;
 my ($dv)=grep {$_->{id} eq 'dv:run-dv'} @{JSON::PP::decode_json(main::webui_lg_calibration_history_list())->{items}};
 is($dv->{picture_mode},"Caf\x{e9} DV",'a stage-log picture mode with an accent is not double-encoded');
 unlink("$root/runs/run-9/grey-state.json");rmdir("$root/runs/run-9");
 unlike(main::webui_lg_calibration_history_list(),qr/"id":"1d:run-9"/,'a removed run leaves the list');
 ok(!(grep {m{/run-9/}} main::_lg_cal_hist_lite_memo_paths()),'and the memo forgets it');
 $grown=main::webui_lg_calibration_history_list();
 open my $junk,'>',"$root/history.list-cache" or die $!;print {$junk} "0123456789abcdef0123456789abcdef\n{\"status\":\"ok\",\"items\":[]}\n";close $junk;
 is(main::webui_lg_calibration_history_list(),$grown,'a cache for a different fingerprint is ignored');
}

# ---- P33: Run queue does not hold the request for TV conversations
{
 my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 my $tv=0;
 local *main::webui_lg_status_json=sub {$tv++;'{"status":"ok","paired":1,"connected":1}'};
 local *main::webui_lg_calibration_mode=sub {$tv++;'{"status":"ok","calibration_mode":false}'};
 local *main::webui_meter_status=sub {'{"detected":1}'};
 local *main::webui_meter_series_alive=sub {0};local *main::webui_meter_lg_autocal_running=sub {0};
 local *main::webui_meter_lg_3d_autocal_running=sub {0};local *main::webui_meter_lg_dv_profile_running=sub {0};
 local *main::webui_meter_session_alive=sub {0};
 local *main::webui_automation_launch_runner=sub {1};
 my $reply=PGAutomation::decode_json(main::webui_automation_start({queue=>{name=>'Batch',items=>[{name=>'Job',signal_format=>'sdr',picture_mode=>'filmMaker'}]}}));
 is($reply->{status},'started','a valid queue starts');
 is($tv,0,'without any TV conversation in the start request');
 my $events=PGAutomation::read_json_file("$store/preflight.json")->{events}||[];
 ok(!grep({($_->{message}||'')=~/TV connection/} @$events),'and its progress never claims to be checking the TV');
 is($events->[0]{message},'Validating the queue, meter and storage','it names the checks the start request actually makes');
 # Each refusal gets its own store: the started run above holds the claim.
 $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 local *main::webui_meter_status=sub {'{"detected":0}'};
 $reply=PGAutomation::decode_json(main::webui_automation_start({queue=>{name=>'Batch',items=>[{name=>'Job',signal_format=>'sdr',picture_mode=>'filmMaker'}]}}));
 is($reply->{status},'blocked','a missing meter still refuses the start immediately');
 unlike($reply->{message}||'',qr/\bTV\b/,'and the refusal does not blame a TV it never checked');
 ok(!grep({($_->{message}||'')=~/\bTV\b/} @{PGAutomation::read_json_file("$store/preflight.json")->{events}||[]}),'nor does its progress log');
 local *main::webui_meter_status=sub {'{"detected":1}'};
 my $invalid=PGAutomation::decode_json(main::webui_automation_start({queue=>{name=>'Batch',items=>[{name=>'Job',signal_format=>'hlg',picture_mode=>'hdrCinema'}]}}));
 is($invalid->{status},'blocked','an invalid queue still refuses the start immediately');
 is($tv,0,'and neither refusal talks to the TV');
}
# A version-2 row (still carrying the trimmed job list) is upgraded in place
# to the current shape without a manifest read.
{
 local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
 PGAutomation::ensure_store();
 my $dir=PGAutomation::run_dir('run-v2');
 PGAutomation::write_json_atomic("$dir/run.json",{id=>'run-v2',token=>'tv2',status=>'complete',queue_name=>'Version two',created_at=>1,items=>[{name=>'fat job',status=>'complete'}]},0644);
 my $key=main::webui_automation_listing_key("$dir/run.json");
 PGAutomation::write_json_atomic("$dir/listing-cache.json",{version=>2,key=>$key,
  summary=>{id=>'run-v2',queue_name=>'Version two',status=>'complete',created_at=>1,items=>[{name=>'fat job',status=>'complete',settings=>{brightness=>50}}]}},0644);
 my $decoded=0;
 no warnings 'redefine';
 local *main::webui_automation_read_run=sub { $decoded++; return undef; };
 my $runs=main::webui_automation_list_runs();
 my ($row)=grep { ($_->{id}||'') eq 'run-v2' } @$runs;
 ok($row && !exists($row->{items}),'a version-2 row loses its job list on the next listing');
 is($row->{queue_name},'Version two','and keeps the fields the row renders');
 is($decoded,0,'without decoding the manifest');
 my $rewritten=PGAutomation::read_json_file("$dir/listing-cache.json");
 is($rewritten->{version},$main::WEBUI_LISTING_CACHE_VERSION,'and the cache is rewritten at the current version');
}

done_testing();
