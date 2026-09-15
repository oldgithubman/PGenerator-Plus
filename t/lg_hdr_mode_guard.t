use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Test::More;
my $rc=do "$Bin/../usr/sbin/pgenerator-lg";
ok(defined $rc,'LG helper loads') or BAIL_OUT($@);
{
 no warnings 'redefine';
 my ($writes,$closed)=(0,0);
 my $mode='hdr_cinema_bright';
 local *main::lg_authenticated_session=sub {{status=>'ok',session=>{}}};
 local *main::lg_generation_info=sub {{platform_year=>2023,platform_model=>'HE_DTV_W23O_AFABATAA'}};
 local *main::lg_3d_lut_resolve_mode=sub {($_[2],$mode)};
 local *main::websocket_close=sub {$closed++};
 local *main::lg_calibration_request=sub {
  $writes++;
  is($_[2],'CAL_START','supported mode failure never proceeds to reset commands');
  return {type=>'error',error=>'500 Application error',payload=>{returnValue=>JSON::PP::false(),errorCode=>20,errorMessage=>'Driver error while executing the command'}};
 };
 local *main::lg_picture_mode_probe=sub {()};
 local *main::lg_calibration_start_cleanup_if_safe=sub {undef};
 my $home=main::lg_hdr_calman_reset_workflow('test','test-key',1,'hdrCinemaBright');
 is($home->{error_code},'lg-calibration-mode-unsupported','Home gets a specific capability error');
 like($home->{message},qr/No calibration reset was sent/,'error explains TV was not reset');
 is($writes,0,'unsupported Home sends neither CAL_START nor reset/upload commands');
 is($closed,1,'unsupported mode closes its connection');
 $mode='hdr_cinema';
 my $cinema=main::lg_hdr_calman_reset_workflow('test','test-key',1,'hdrCinema');
 is($writes,1,'supported Cinema attempts calibration entry');
 is($cinema->{error_code},'lg-calibration-start-rejected','error 20 is not diagnosed as a proven stuck driver');
 like($cinema->{message},qr/does not establish a stuck session/,'generic rejection preserves uncertainty');
 is($closed,2,'rejected entry closes its connection');
}
done_testing();
