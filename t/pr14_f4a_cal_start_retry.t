# Adversarial F4 part A (agent BC): real lg_calibration_mode_workflow and
# lg_calibration_start_with_retry with a REAL lg_generation_info for a C1
# (read-banned) and a G3 (readable). Only websocket I/O is stubbed.
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use Test::More;
use JSON::PP ();
my $WT="$Bin/..";
do "$WT/usr/sbin/pgenerator-lg"; die $@ if $@;
local $main::CALIBRATION_START_RETRY_DELAY=0;
my $ok={type=>'response',payload=>{returnValue=>JSON::PP::true}};
my $driver={type=>'error',error=>'500 Application error',payload=>{returnValue=>JSON::PP::false,errorCode=>20,errorMessage=>'Driver error while executing the command'}};
my $timeout={type=>'error',error=>'timeout'};
my $missing_ack={type=>'response',payload=>{}};
my $perm={type=>'error',payload=>{errorCode=>401,errorText=>'Permission denied'}};
my (@replies,@commands,$reads,$mode,$who);
local *main::diag_log_append=sub {};
local *main::lg_current_picture_mode=sub {$reads++;$mode};
local *main::lg_calibration_request=sub {push @commands,$_[2];return @replies?shift @replies:{type=>'error',error=>'NO MORE REPLIES'}};
local *main::lg_authenticated_session=sub {{status=>'ok',session=>{},
  system_info=>$who eq 'c1'?{modelName=>'OLED65C1PUB'}:{modelName=>'OLED55G36LA'},
  software_info=>$who eq 'c1'?{product_name=>'webOSTV 6.0',major_ver=>'53',minor_ver=>'45.00',model_name=>'HE_DTV_W21O_AFABATPU'}:{product_name=>'webOSTV 23',major_ver=>'33',minor_ver=>'22.65',model_name=>'HE_DTV_W23O_AFABATAA'},
  hello_info=>{}}};
local *main::websocket_close=sub {};
local *main::lg_calibration_profile_guard=sub {undef};
sub fx {@replies=@_;@commands=();$reads=0;}
# Establish which generation each identity resolves to (real classifier).
$who='c1';my $gc1=main::lg_generation_info(main::lg_authenticated_session()->{system_info},main::lg_authenticated_session()->{software_info},{});
$who='g3';my $gg3=main::lg_generation_info(main::lg_authenticated_session()->{system_info},main::lg_authenticated_session()->{software_info},{});
ok($gc1->{picture_mode_read_forbidden},'real classifier: C1 identity is read-banned') or diag explain $gc1;
ok(!$gg3->{picture_mode_read_forbidden},'real classifier: G3 identity is readable');
my %dump;
# ---- read-banned: transient DV error-20 recovers with no reads, bounded at 3
$who='c1';
fx($driver,$driver,$ok);$mode='';
my $r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,1,'dolbyVisionFilmMaker','dv');
is($r->{status},'ok','C1: DV error-20 x2 then ack -> ok');
is($r->{start_attempts},3,'C1: three attempts used');
is($reads,0,'C1: no impossible mode reads on read-banned generation');
ok($r->{start_retry_mode_readback_unavailable},'C1: limitation reported');
$dump{enable_ok}=$r;
fx($driver,$driver,$driver,$ok);
$r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,1,'dolbyVisionFilmMaker','dv');
is($r->{status},'error','C1: persistent rejection fatal');
is(scalar(grep {$_ eq 'CAL_START'} @commands),3,'C1: at most 3 CAL_START sent');
for my $case (['timeout',$timeout],['missing ack',$missing_ack],['permission',$perm]) {
  fx($case->[1],$ok);
  $r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,1,'dolbyVisionFilmMaker','dv');
  is(scalar(@commands),1,"C1: $case->[0] never retried");
  is($r->{status},'error',"C1: $case->[0] is an error");
}
fx($driver,$ok);
$r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,1,'filmMaker','sdr');
is(scalar(@commands),1,'C1: SDR error-20 not retried (DV-only tolerance)');
# ---- readable generation: changed mode stops, empty read stops, match retries
$who='g3';
for my $case (['changed mode','dolbyHdrCinemaBright',1],['empty read','',1],['same mode','dolbyHdrCinema',2]) {
  fx($driver,$ok);$mode=$case->[1];
  $r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,1,'dolbyVisionFilmMaker','dv');
  is(scalar(@commands),$case->[2],"G3: $case->[0] -> $case->[2] CAL_START");
  is($reads,1,"G3: $case->[0] required a fresh mode read");
}
fx($timeout);$mode='dolbyHdrCinema';
$r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,1,'dolbyVisionFilmMaker','dv');
is(scalar(@commands),1,'G3: timeout never retried');
# ---- exit shapes for part B
$who='c1';
fx($ok);$r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,0,'dolbyVisionFilmMaker','dv');
is($r->{status},'ok','disable ok');ok(exists $r->{calibration_mode} && !$r->{calibration_mode},'disable success carries calibration_mode=false');
$dump{disable_ok}=$r;
fx($driver);$r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,0,'dolbyVisionFilmMaker','dv');
$dump{disable_dv_error20}=$r;
diag("DV CAL_END error-20 on C1: status=$r->{status} tolerated=".($r->{cal_end_tolerated}?1:0)." calibration_mode=".(defined $r->{calibration_mode}?($r->{calibration_mode}?1:0):'undef'));
fx($driver);$r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,0,'hdrFilmMaker','hdr10');
$dump{disable_hdr_error20}=$r;
fx($ok);$r=main::lg_calibration_mode_workflow('192.0.2.1','key',1,1,'hdrFilmMaker','hdr10');
$dump{enable_hdr_ok}=$r;
if ($ENV{DUMP}) {open my $f,'>',$ENV{DUMP} or die;print {$f} JSON::PP->new->canonical->allow_blessed->convert_blessed->encode(\%dump);close $f;}
done_testing();
