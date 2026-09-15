use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
use JSON::PP ();
do "$Bin/../usr/sbin/pgenerator-lg"; die $@ if $@;
local $main::CALIBRATION_START_RETRY_DELAY=0;
my $ok={type=>'response',payload=>{returnValue=>JSON::PP::true}};
my $driver={type=>'error',error=>'500 Application error',payload=>{
 returnValue=>JSON::PP::false,errorCode=>20,errorMessage=>'Driver error while executing the command'}};
my (@replies,@commands,@request_modes,@logs,$mode,$reads,$closed);
local *main::diag_log_append=sub {push @logs,[@_]};
local *main::lg_current_picture_mode=sub {$reads++;$mode};
local *main::lg_calibration_request=sub {push @commands,$_[2];push @request_modes,$_[5];die 'Unexpected retry' unless @replies;shift @replies};
local *main::lg_authenticated_session=sub {{status=>'ok',session=>{}}};
local *main::lg_generation_info=sub {{platform_year=>2023,platform_model=>'HE_DTV_W23O_AFABATAA'}};
local *main::websocket_close=sub {$closed++};
sub fixture {
 @replies=@_;@commands=();@request_modes=();@logs=();$reads=0;$closed=0;$mode='dolbyHdrCinema';
}
fixture($driver,$ok);
my $r=main::lg_calibration_mode_workflow('test','key',1,1,'dolbyVisionFilmMaker','dv');
is($r->{status},'ok','transient rejection can recover');
is($r->{start_attempts},2,'actual start attempts recorded');
ok(!$r->{cal_start_tolerated},'success requires an acknowledged start, not tolerated rejection');
is($reads,1,'retry requires a fresh TV mode read');
is_deeply(\@commands,['CAL_START','CAL_START'],'no reset, data write or CAL_END used for recovery');
is(scalar @logs,1,'one informative retry entry');
like($r->{message},qr/Accepted on attempt 2/,'successful recovery reported');
is($closed,1,'shared workflow closes session');

fixture($driver,$driver,$driver);
$r=main::lg_calibration_mode_workflow('test','key',1,1,'dolbyVisionFilmMaker','dv');
is($r->{status},'error','persistent rejection is fatal');
is($r->{start_attempts},3,'retry is bounded');
is($r->{error_code},'lg-calibration-start-rejected','failure has a stable error code');
like($r->{message},qr/dolbyVisionFilmMaker.*dolby_cinema_dark.*3 attempt/,'error identifies requested and wire modes and attempts');
is_deeply($r->{raw_response},$driver,'original TV rejection retained');

for my $case (
 ['wrong mode',$driver,'dolbyHdrCinemaBright','dolby_hdr_cinema_dark'],
 ['unreadable mode',$driver,'','dolby_hdr_cinema_dark'],
 ['SDR rejection',$driver,'cinema','cinema'],
 ['HDR rejection',$driver,'hdrCinema','hdr_cinema'],
 ['timeout',{type=>'error',error=>'timeout'},'dolbyHdrCinema','dolby_hdr_cinema_dark'],
 ['ambiguous reply',{type=>'response',payload=>{}},'dolbyHdrCinema','dolby_hdr_cinema_dark'],
 ['permission denial',{type=>'error',payload=>{errorCode=>401,errorText=>'Permission denied'}},'dolbyHdrCinema','dolby_hdr_cinema_dark'],
) {
 fixture($case->[1]);$mode=$case->[2];
 my ($reply,$attempts)=main::lg_calibration_start_with_retry({},$case->[3],1);
 is($attempts,1,"$case->[0] is not retried");
 ok(!main::lg_calibration_start_confirmed($reply),"$case->[0] cannot become success");
}
fixture($ok);
$r=main::lg_calibration_mode_workflow('test','key',1,0,'dolbyVisionFilmMaker','dv');
is($r->{status},'ok','normal exit unchanged');
is_deeply(\@commands,['CAL_END'],'exit not retried');
is($reads,0,'exit adds no TV reads');

# Reproduce the C1 report at the retry boundary: the session already holds
# the wire spelling, while native readback resolves to the internal spelling.
for my $case (
 ['dolby_cinema_dark','dolbyVisionFilmMaker'],
 ['dolby_cinema_dark','dolbyHdrCinema'],
 ['dolby_cinema_bright','dolbyVisionCinemaBright'],
 ['dolby_hdr_cinema_dark','dolbyVisionFilmMaker'],
 ['dolby_hdr_cinema_bright','dolbyVisionCinemaBright'],
) {
 fixture($driver,$ok);$mode=$case->[1];
 my ($reply,$attempts)=main::lg_calibration_start_with_retry({},$case->[0],1);
 is($attempts,2,"$case->[0] retries after equivalent $case->[1] readback");
 ok(main::lg_calibration_start_confirmed($reply),'recovery requires acknowledged CAL_START');
 is_deeply(\@commands,['CAL_START','CAL_START'],'retry never resets, uploads or closes another session');
 is_deeply(\@request_modes,[$case->[0],$case->[0]],'retry preserves the exact opened calibration target');
}
for my $case (
 ['dolby_cinema_dark','dolbyVisionCinemaBright'],
 ['dolby_cinema_bright','dolbyVisionFilmMaker'],
 ['dolby_cinema_dark','dolbyVisionCinema'],
 ['dolby_cinema_dark',''],
 ['dolby_cinema_dark','cinema'],
) {
 fixture($driver);$mode=$case->[1];
 my ($reply,$attempts)=main::lg_calibration_start_with_retry({},$case->[0],1);
 is($attempts,1,"$case->[0] does not retry mismatched or missing '$case->[1]'");
}
fixture($driver,$driver,$driver);$mode='dolbyVisionFilmMaker';
my ($legacy_reply,$legacy_attempts)=main::lg_calibration_start_with_retry({},'dolby_cinema_dark',1);
is($legacy_attempts,3,'legacy rejection is bounded to three attempts');
ok(!main::lg_calibration_start_confirmed($legacy_reply),'persistent legacy rejection is never treated as success');
for my $failure (
 {type=>'error',error=>'timeout'},
 {type=>'error',payload=>{errorCode=>401,errorText=>'Permission denied'}},
 {type=>'response',payload=>{}},
) {
 fixture($failure);$mode='dolbyVisionFilmMaker';
 my ($reply,$attempts)=main::lg_calibration_start_with_retry({},'dolby_cinema_dark',1);
 is($attempts,1,'legacy spelling does not enable timeout, permission or ambiguous-response retries');
}
{
 local *main::lg_generation_info=sub {{model_name=>'OLED65C1PUB',platform_year=>2021,platform_model=>'HE_DTV_W21O_AFABATAA',generation_id=>'lg2021_oled',ddc_only_white_balance=>1}};
 fixture($driver,$ok);$mode='dolbyVisionFilmMaker';
 my $result=main::lg_calibration_mode_workflow('test','key',1,1,'dolbyVisionCinema','dv');
 is($result->{status},'ok','complete 2021 workflow uses the same bounded retry');
 is($result->{start_attempts},2,'C1 workflow recovers on acknowledged second attempt');
 is(main::lg_wire_pic_mode($result->{calibration_picture_mode}),'dolby_cinema_dark','C1 Cinema still opens Cinema Dark, not a different preset');
}
done_testing();
