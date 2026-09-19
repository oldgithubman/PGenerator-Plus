use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use Test::More;
require "$Bin/../usr/share/PGenerator/lg.pm";
my (@calls,$entry,$exit,$upload,$throw);
sub restore {
 @calls=();
 return main::lg_decode_json(main::_lg_cal_hist_restore_1d([(0)x3072],'filmMaker','sdr',$_[0]||{}));
}
{
 no warnings 'redefine';
 local *main::webui_lg_calibration_mode=sub {
  my $body=main::lg_decode_json($_[0]);push @calls,$body->{enabled}?'enter':'exit';
  return main::lg_encode_json({status=>($body->{enabled}?$entry:$exit)?'ok':'error',calibration_mode=>$body->{enabled}?($entry?1:0):($exit?0:1),message=>'TV response'});
 };
 local *main::webui_lg_1d_dpg_upload=sub {push @calls,'upload';die "Upload threw\n" if $throw;return main::lg_encode_json({status=>$upload?'ok':'error',message=>'Upload result'});};
 ($entry,$exit,$upload,$throw)=(1,1,1,0);
 is(restore()->{status},'ok','acknowledged entry, upload and exit succeed');
 is_deeply(\@calls,[qw(enter upload exit)],'restore uses ordered bookends');
 $entry=0;
 is(restore()->{status},'error','entry rejection is an error');
 is_deeply(\@calls,[qw(enter exit)],'no upload after rejected entry; exit still attempted');
 $entry=1;$throw=1;
 like(restore()->{message},qr/Upload threw/,'upload exception retained');
 is_deeply(\@calls,[qw(enter upload exit)],'upload exception cannot skip exit');
 $throw=0;$exit=0;
 is(restore()->{error_code},'calibration-exit-unconfirmed','successful upload with failed exit is not overall success');
 $exit=1;$upload=0;
 is(restore()->{status},'error','exit success cannot hide upload failure');
 is(restore({signal_mode=>'hdr10'})->{status},'error','cross-signal override refused');
 is_deeply(\@calls,[],'invalid restore has no TV effects');
 is(restore({picture_mode=>'cinema'})->{status},'error','cross-mode override refused');
}
done_testing();
