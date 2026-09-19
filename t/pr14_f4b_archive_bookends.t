# Adversarial F4 part B (agent BC): archive restore bookends through the REAL
# webui_lg_calibration_mode + lg_status_response (helper process output is the
# real lg_calibration_mode_workflow shape dumped by f4a), REAL
# _lg_cal_hist_restore_with_bookends and REAL history dispatcher.
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Test::More;
my $WT="$Bin/..";my $SHAPES="$Bin/fixtures/pr14_helper_shapes.json";
use lib ();
BEGIN { unshift @INC, ("$Bin/.."||'')."/usr/share/PGenerator"; }
require "$WT/usr/share/PGenerator/lg.pm";
open my $sf,'<',$SHAPES or die;my $shapes=JSON::PP::decode_json(do{local $/;<$sf>});close $sf;
my $dir=tempdir(CLEANUP=>1);
make_path(map {"$dir/$_"} qw(runs/run-1 luts history/dv history/1d));
sub save {my ($p,$d)=@_;open my $f,'>',"$dir/$p" or die;print {$f} main::lg_encode_json($d);close $f;}
my $meas={white_luminance=>700};
save('runs/run-1/dv-profile-measurements.json',$meas);
save('runs/run-1/manifest.json',{config=>{picture_mode=>'dolbyVisionFilmMaker',signal_mode=>'dv'}});
save('history/dv/archived.json',{picture_mode=>'dolbyVisionFilmMaker',measurements=>$meas});
save('luts/archived.json',{picture_mode=>'hdrFilmMaker',signal_mode=>'hdr10'});
open my $b,'>',"$dir/luts/archived.bin" or die;print {$b} 'x';close $b;
open my $src,'<',"$WT/usr/share/PGenerator/lg.pm" or die;my $text=do{local $/;<$src>};close $src;
my ($dispatch)=$text=~/(sub webui_lg_calibration_history_reupload\s*\(\@\)\s*\{.*?)(?=\nsub webui_lg_api)/s or die;
eval 'package main; {my $_lg_cal_hist_runs=q{'.$dir.'/runs};my $_lg_cal_hist_luts=q{'.$dir.'/luts};my $_lg_cal_hist_dir=q{'.$dir.'/history};'.$dispatch.'}';die $@ if $@;
# A DV reupload now refuses unless the display is in Relative DV map mode
# (dv_map_mode 2); set it so the DV bookend cases exercise the restore flow
# rather than the map-mode guard. See t/lg_cal_hist_reupload_dv_map_mode.t.
$main::pgenerator_conf{dv_map_mode}='2';
# Real webui_lg_calibration_mode; stub only process/network/file boundaries.
my $clients={client_key=>'k',ip=>'192.0.2.1',clients=>[{client_key=>'k',ip=>'192.0.2.1'}]};
local *main::lg_automation_guard_json=sub {''};
local *main::lg_load_clients=sub {$clients};
local *main::lg_reconcile_pin_pairing=sub {($_[0],undef)};
local *main::lg_clients_disconnected=sub {0};
local *main::lg_target_ip=sub {'192.0.2.1'};
local *main::lg_primary_client=sub {{client_key=>'k',ip=>'192.0.2.1'}};
local *main::lg_update_connect_metadata=sub {$clients};
local *main::lg_save_clients=sub {1};
local *main::lg_calmode_trace=sub {};
local *main::lg_cec_status=sub {{}};
local *main::lg_detect_from_cec=sub {{}};
local *main::lg_boot_id=sub {''};
local *main::lg_autodetect_info=sub {{}};
my (@calls,$enter_shape,$exit_shape,$upload,$upload_die);
local *main::lg_helper_run=sub {
  my ($req)=@_;push @calls,$req->{enable}?'enter':'exit';
  my $s=$req->{enable}?$enter_shape:$exit_shape;die "helper died\n" if !defined $s;
  return JSON::PP::decode_json(JSON::PP::encode_json($s));
};
my $up=sub {push @calls,'upload';die "Upload transport exception\n" if $upload_die;return main::lg_encode_json($upload);};
local *main::webui_lg_3d_lut_upload=$up;local *main::webui_lg_dv_profile_upload=$up;
sub fx {@calls=();$upload_die=0;$upload={status=>'ok',message=>'Upload accepted',uploaded=>JSON::PP::true};}
sub restore {my ($id,$o)=@_;return main::lg_decode_json(main::webui_lg_calibration_history_reupload(main::lg_encode_json({id=>$id,%{$o||{}}})));}
for my $id ('3d:archived','dvfile:archived','dv:run-1') {
  my $dv=$id=~/^dv/;
  # normal enable + upload + disable with REAL helper success shapes
  fx();$enter_shape=$dv?$shapes->{enable_ok}:$shapes->{enable_hdr_ok};$exit_shape=$shapes->{disable_ok};
  my $r=restore($id);
  is($r->{status},'ok',"$id: real enable+upload+disable returns upload success") or diag explain $r;
  is($r->{message},'Upload accepted',"$id: upload result (not exit) is returned");
  ok(!$r->{error_code},"$id: no false calibration-exit-unconfirmed");
  is_deeply(\@calls,[qw(enter upload exit)],"$id: ordered bookends");
  # real webui_lg_calibration_mode enable response feeds !$on->{calibration_mode}
  my $on=main::lg_decode_json(main::webui_lg_calibration_mode('{"enabled":true,"picture_mode":"x","signal_mode":"dv"}'));
  ok($on->{calibration_mode},"$id: real enable success response has truthy calibration_mode");
  my $off=main::lg_decode_json(main::webui_lg_calibration_mode('{"enabled":false,"picture_mode":"x","signal_mode":"dv"}'));
  ok(exists $off->{calibration_mode} && !$off->{calibration_mode},"$id: real disable success response has calibration_mode=false");
  # DV CAL_END error-20 tolerated by helper -> still success
  if ($dv) {fx();$enter_shape=$shapes->{enable_ok};$exit_shape=$shapes->{disable_dv_error20};
    is(restore($id)->{status},'ok',"$id: tolerated DV CAL_END driver rejection is not reported as exit failure");}
  # unacknowledged entry blocks upload
  for my $bad (['error',{%{$shapes->{disable_hdr_error20}},message=>'CAL_START rejected',error_code=>'lg-calibration-start-rejected'}],['helper died',undef]) {
    fx();$enter_shape=$bad->[1];$exit_shape=$shapes->{disable_ok};
    $r=restore($id);
    is($r->{status},'error',"$id: entry $bad->[0] -> error");
    ok(!grep({$_ eq 'upload'} @calls),"$id: entry $bad->[0] never uploads");
    is($calls[-1],'exit',"$id: entry $bad->[0] still attempts exit");
  }
  # upload exception still attempts exit
  fx();$enter_shape=$dv?$shapes->{enable_ok}:$shapes->{enable_hdr_ok};$exit_shape=$shapes->{disable_ok};$upload_die=1;
  $r=restore($id);
  is_deeply(\@calls,[qw(enter upload exit)],"$id: upload exception still exits");
  like($r->{message},qr/Upload transport exception/,"$id: upload exception preserved");
  is($r->{status},'error',"$id: upload exception is an error");
  # exit failure -> calibration-exit-unconfirmed with upload_status
  fx();$enter_shape=$dv?$shapes->{enable_ok}:$shapes->{enable_hdr_ok};$exit_shape=$shapes->{disable_hdr_error20};
  $r=restore($id);
  is($r->{error_code},'calibration-exit-unconfirmed',"$id: exit failure reported");
  is($r->{status},'error',"$id: exit failure is not reported as status ok");
  is($r->{upload_status},'ok',"$id: upload_status retained");
  ok($r->{cleanup_required},"$id: cleanup_required flagged");
  # upload returned JSON without status
  fx();$enter_shape=$dv?$shapes->{enable_ok}:$shapes->{enable_hdr_ok};$exit_shape=$shapes->{disable_ok};$upload={message=>'no status'};
  is(restore($id)->{status},'error',"$id: upload result without status is an error");
}
# caller-held session (disable_calibration=0) but entry failed: must still try exit
for my $id ('3d:archived','dvfile:archived','dv:run-1') {
  fx();$enter_shape={%{$shapes->{disable_hdr_error20}},message=>'CAL_START rejected'};$exit_shape=$shapes->{disable_ok};
  my $r=restore($id,{disable_calibration=>0});
  is_deeply(\@calls,[qw(enter exit)],"$id: failed entry with caller-held exit still attempts cleanup exit");
  fx();$enter_shape=$id=~/^dv/?$shapes->{enable_ok}:$shapes->{enable_hdr_ok};$exit_shape=$shapes->{disable_ok};
  $r=restore($id,{disable_calibration=>0});
  is_deeply(\@calls,[qw(enter upload)],"$id: successful caller-held session is not exited");
  is($r->{status},'ok',"$id: caller-held success ok");
}
# OBSERVATION: entry failure + exit failure overwrites the entry error code
fx();$enter_shape={%{$shapes->{disable_hdr_error20}},message=>'CAL_START rejected'};$exit_shape=$shapes->{disable_hdr_error20};
my $r=restore('3d:archived');
diag("entry+exit failure error_code=".($r->{error_code}//'')." failure_stage=".($r->{failure_stage}//'')." upload_status=".($r->{upload_status}//''));
done_testing();
