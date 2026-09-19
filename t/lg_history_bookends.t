use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
require "$Bin/../usr/share/PGenerator/lg.pm";
my $dir=tempdir(CLEANUP=>1);
make_path(map {"$dir/$_"} qw(runs/run-1 luts history/dv history/1d));
sub save {
 my ($path,$data)=@_;open my $f,'>',"$dir/$path" or die $!;
 print {$f} main::lg_encode_json($data);close $f;
}
my $measurements={white_luminance=>700,red_x=>.68};
save('runs/run-1/dv-profile-measurements.json',$measurements);
save('runs/run-1/manifest.json',{config=>{picture_mode=>'dolbyVisionFilmMaker',signal_mode=>'dv'}});
save('history/dv/archived.json',{picture_mode=>'dolbyVisionFilmMaker',measurements=>$measurements});
save('history/1d/archived.json',{picture_mode=>'dolbyVisionFilmMaker',signal_mode=>'dv',dpg_data=>[(0)x3072]});
save('luts/archived.json',{picture_mode=>'hdrFilmMaker',signal_mode=>'hdr10'});
open my $bin,'>',"$dir/luts/archived.bin" or die $!;print {$bin} 'fixture';close $bin;
# Rebind only fixed archive roots for the production dispatch function, not
# its control flow. The helper implementation and JSON readers are unmodified.
open my $source,'<',"$Bin/../usr/share/PGenerator/lg.pm" or die $!;
my $text=do {local $/;<$source>};close $source;
my ($dispatch)=$text=~/(sub webui_lg_calibration_history_reupload\s*\(\@\)\s*\{.*?)(?=\nsub webui_lg_api)/s;
die 'History dispatcher not found' if !$dispatch;
eval 'package main; {my $_lg_cal_hist_runs=q{'.$dir.'/runs};my $_lg_cal_hist_luts=q{'.$dir.'/luts};my $_lg_cal_hist_dir=q{'.$dir.'/history};'.$dispatch.'}';die $@ if $@;
# A DV reupload now refuses unless the display is in Relative DV map mode
# (dv_map_mode 2); set it so the DV bookend cases exercise the restore flow
# rather than the map-mode guard. See t/lg_cal_hist_reupload_dv_map_mode.t.
$main::pgenerator_conf{dv_map_mode}='2';
my (@calls,$entry,$exit,$upload,$entry_throw,$exit_throw,$upload_throw);
local *main::webui_lg_calibration_mode=sub {
 my $body=main::lg_decode_json($_[0]);push @calls,$body->{enabled}?'enter':'exit';
 die "Entry transport exception\n" if $body->{enabled} && $entry_throw;
 die "Exit transport exception\n" if !$body->{enabled} && $exit_throw;
 return main::lg_encode_json($body->{enabled}?$entry:$exit);
};
my $upload_stub=sub {push @calls,'upload';die "Upload transport exception\n" if $upload_throw;return main::lg_encode_json($upload);};
local *main::webui_lg_3d_lut_upload=$upload_stub;
local *main::webui_lg_dv_profile_upload=$upload_stub;
local *main::webui_lg_1d_dpg_upload=$upload_stub;
sub fixture {
 @calls=();($entry_throw,$exit_throw,$upload_throw)=(0,0,0);
 $entry={status=>'ok',calibration_mode=>1};$exit={status=>'ok',calibration_mode=>0};$upload={status=>'ok',message=>'Upload accepted'};
}
sub restore {my ($id,$options)=@_;my $result=eval {main::lg_decode_json(main::webui_lg_calibration_history_reupload(main::lg_encode_json({id=>$id,%{$options||{}}})))};return $result||{status=>'error',message=>$@||'Missing result'};}
for my $id ('3d:archived','dvfile:archived','dv:run-1','1dfile:archived') {
 fixture();is(restore($id)->{status},'ok',"$id succeeds with acknowledged entry/upload/exit");
 is_deeply(\@calls,[qw(enter upload exit)],"$id uses ordered bookends");
 for my $bad ({status=>'error',message=>'CAL_START rejected'}, {status=>'ok'}, {status=>'ok',calibration_mode=>0}) {
  fixture();$entry=$bad;
  is(restore($id)->{status},'error',"$id rejects absent calibration-entry acknowledgement");
  is_deeply(\@calls,[qw(enter exit)],"$id never uploads after failed entry and attempts cleanup");
 }
 fixture();$entry_throw=1;
 like(restore($id)->{message},qr/Entry transport exception/,"$id preserves entry exception");
 is_deeply(\@calls,[qw(enter exit)],"$id does not upload after entry exception");
 fixture();$upload_throw=1;
 like(restore($id)->{message},qr/Upload transport exception/,"$id preserves upload exception");
 is_deeply(\@calls,[qw(enter upload exit)],"$id upload exception cannot skip cleanup");
 fixture();$exit={status=>'error',message=>'CAL_END rejected'};
 my $exit_failed=restore($id);
 is($exit_failed->{error_code},'calibration-exit-unconfirmed',"$id does not report success after failed exit");
 is($exit_failed->{exit_status},'unconfirmed',"$id reports the unconfirmed viewing state after a failed exit");
 ok($exit_failed->{cleanup_required},"$id marks cleanup required after a failed exit");
 fixture();$exit_throw=1;
 is(restore($id)->{error_code},'calibration-exit-unconfirmed',"$id exit exception is visible");
 # F4-h (P22): an exit reply without explicit calibration_mode=false is not proof.
 fixture();$exit={status=>'ok'};
 is(restore($id)->{error_code},'calibration-exit-unconfirmed',"$id an exit without calibration_mode evidence is unconfirmed");
 # Entry and exit both refused: there was never a session to exit, so the
 # entry failure stays the error and the viewing state is reported unconfirmed.
 fixture();$entry={status=>'error',message=>'CAL_START rejected'};$exit={status=>'error',message=>'CAL_END rejected'};
 my $double=restore($id);
 is($double->{error_code},'calibration-entry-unconfirmed',"$id keeps the entry failure when exit also fails");
 is($double->{exit_status},'unconfirmed',"$id reports the unconfirmed viewing state after a double failure");
 unlike($double->{message},qr/Use Exit Calibration/,"$id does not point to Exit Calibration for a session that never started");
 is_deeply(\@calls,[qw(enter exit)],"$id still attempts cleanup after a double failure");
 fixture();$upload={status=>'error',message=>'Upload rejected'};
 is(restore($id)->{status},'error',"$id successful exit does not hide upload failure");
}
# Explicit caller-managed bookends are honoured for every archive kind,
# including 1D archives, which used to ignore them.
for my $id ('dvfile:archived','3d:archived','1dfile:archived') {
 for my $options ({enable_calibration=>0,disable_calibration=>0},{disable_calibration=>0},{enable_calibration=>0}) {
  fixture();is(restore($id,$options)->{status},'ok',"$id successful caller-managed session is preserved");
  my @expected=(($options->{enable_calibration}//1)?'enter':(),'upload',($options->{disable_calibration}//1)?'exit':());
  is_deeply(\@calls,\@expected,"$id only requested successful bookends are executed");
 }
}
# Round 3 (P20b): the 1D upload only tells the helper a session is already
# active when this restore entered it; a caller-managed entry leaves the
# helper to start its own session, as the 3D and DV restores do.
{
 my @bodies;
 local *main::webui_lg_1d_dpg_upload=sub {push @calls,'upload';push @bodies,main::lg_decode_json($_[0]);return main::lg_encode_json($upload);};
 fixture();@bodies=();
 is(restore('1dfile:archived')->{status},'ok','1D restore with its own entry succeeds');
 ok($bodies[0]{calibration_mode_active},'and tells the helper the session it entered is active');
 ok($bodies[0]{keep_calibration_mode},'while keeping that session open for the exit bookend');
 for my $options ({enable_calibration=>0},{enable_calibration=>0,disable_calibration=>0}) {
  fixture();@bodies=();
  is(restore('1dfile:archived',$options)->{status},'ok','1D restore without its own entry succeeds');
  ok(!exists($bodies[0]{calibration_mode_active}),'and never claims a session it did not enter');
 }
}
done_testing();
