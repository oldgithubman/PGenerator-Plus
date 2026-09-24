use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGCalibrationMath qw(calibration_target_context target_luminance_for_context);

do "$Bin/../usr/bin/meter_lg_autocal.pl";
die $@ if $@;
local *main::write_state=sub {};
local *main::log_line=sub {};
local *main::cancelled=sub {0};
local *main::api_json=sub {{status=>'ok'}};
local *main::read_step=sub {return ({Y=>497.613722,X=>473,Z=>542},undef)};

my @labels=(2.3,3,4,5,7,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,99,105,109);
my @codes=(84,92,100,108,124,152,196,240,284,328,372,416,460,504,544,588,632,676,720,764,808,852,896,932,984,1023);
my @rows=(21,30,38,47,64,94,141,188,235,282,329,375,422,469,512,559,606,653,700,747,794,841,888,926,981,1023);
my %fillers=(2=>[82,19],2.7=>[88,26],3.7=>[96,34],6=>[117,57],8=>[134,75],9=>[143,84]);

# Exercise the real ladder builder and its handoff to the anchor solver.
# Only meter/network and the inner optimization loop are replaced.
for my $bits (8,10) {
 for my $dark (0,1) {
  my %seen;
  local $main::LG_AUTOCAL_DARK_DETAIL=$dark;
  local $main::LG_AUTOCAL_DDC_LAYOUT='sdr26';
  my $config={signal_mode=>'sdr',pattern_signal_range=>1,transport_signal_range=>1,
   color_format=>1,max_bpc=>$bits,full_workflow=>1,target_gamma=>'2.2',lg_autocal_26=>1};
  local $main::LG_AUTOCAL_CONFIG=$config;
  local *main::lg_autocal_26_run_sdr_1d_dpg_greyscale_inner=sub {
   my ($cfg,$state,$step,$idx,$label,$budget,$white,$x,$y,$mode,$dpg)=@_;
   $seen{$step->{ire}}={%$step,index=>$idx};
   $state->{sdr_1d_dpg_white_converged}=1;
   return (1,{Y=>$white},$dpg,1,0,1,0);
  };
  my $state={};
  my $error=main::lg_autocal_26_run_sdr_1d_dpg_greyscale($config,$state,497.613722,0.3127,0.329,'filmMaker');
  is($error,undef,"$bits-bit dark=$dark: real SDR ladder completes");
  is(scalar(keys %seen),26+($dark ? 6 : 0),'every base and enabled filler reaches the solver');
  if($bits==10) {
   is_deeply([map {$seen{$_}->{r}} @labels],\@codes,'all historical base codes preserved');
   is_deeply([map {$seen{$_}->{index}} @labels],\@rows,'all 26 base native rows preserved');
   if($dark) {
    for my $label (sort {$a<=>$b} keys %fillers) {
     is_deeply([$seen{$label}->{r},$seen{$label}->{index}],$fillers{$label},"$label% filler uses its code coordinate");
    }
   }
  }
  my ($black,$peak)=$bits==10 ? (64,1023) : (16,255);
  for my $label (sort {$a<=>$b} keys %seen) {
   my $step=$seen{$label};
   my $fraction=($step->{r}-$black)/($peak-$black);
   cmp_ok(abs($step->{target_stimulus}/109-$fraction),'<',1e-12,"$bits-bit $label% target shares the measured-white domain");
   is($step->{index},int(1023*$fraction+0.5),"$bits-bit $label% index comes from actual code");
  }
  for my $gamma ('2.2','2.4','bt1886','srgb','st2084') {
   my $step=$seen{3};
   my $actual=main::lg_autocal_26_sdr26_dpg_compute_target(497.613722,$step,0.001,$gamma);
   my $fraction=($step->{r}-$black)/($peak-$black);
   # The existing SDR26 contract treats the 2.4 selection as BT.1886.
   my $resolved=$gamma eq '2.4' ? 'bt1886' : $gamma;
   my $context=calibration_target_context({caller_policy=>'autocal_1d',signal_mode=>'sdr',target_gamma=>$resolved,sdr_signal_peak=>100});
   my $reference=target_luminance_for_context($context,100*$fraction,497.613722,0.001);
   cmp_ok(abs($actual-$reference),'<',1e-10,"$gamma uses exact normalized code at $bits bits");
  }
  if($bits==10) {
   my $target=main::lg_autocal_26_sdr26_dpg_compute_target(497.613722,$seen{3},0,'2.2');
   cmp_ok(abs($target-0.209237287332),'<',1e-10,'archived 3% case corrects the nominal-label target');
  }
 }
}

for my $endpoint ([64,10,0,0],[1023,10,1023,109],[16,8,0,0],[255,8,1023,109]) {
 my ($code,$bits,$row,$stim)=@$endpoint;
 is_deeply([main::lg_autocal_sdr26_limited_coordinates($code,$bits)],[$row,$stim],"$bits-bit endpoint $code");
}
done_testing();
