
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
do "$Bin/../usr/bin/meter_lg_autocal.pl"; die $@ if $@;

# Near black, an i1Display Pro sensor can return zero counts: the reading's Y is
# valid, but one primary projects to a linear value <= 0 (LG C1 SDR 2%: blue,
# B/Y -0.15 on every such read). The per-channel gain must then push that
# channel up rather than hold it at 1.0 -- a held channel never rises into the
# meter's range, so the anchor deadlocks. Readings below are committed SDR 2%
# reads from runs on 2026-08-22 and 2026-09-23.
my ($wx,$wy)=(0.3127,0.329);
my %blue_starved=(
 'Aug 22 sdr26_2%' => [{X=>0.00477,Y=>0.00625,Z=>0.00006},0.0108],
 'Sep 23 sdr26_2%' => [{X=>0.00513,Y=>0.00589,Z=>0.00006},0.0110],
);

for my $fn (qw(lg_autocal_26_sdr26_dpg_gain lg_autocal_26_hdr20_dpg_gain)) {
 my $gain=\&{"main::$fn"};
 for my $case (sort keys %blue_starved) {
  my ($reading,$tY)=@{$blue_starved{$case}};
  my @g=$gain->({%$reading},$tY,$wx,$wy,2);
  cmp_ok($g[2],'>',1.0,"$fn: $case raises the unmeasurable blue channel");
  is($g[2],2.0,"$fn: $case blue gets the ceiling gain so the damp bounds the move");
  cmp_ok($g[0],'>',1.0,"$fn: $case red still gets its measured ratio");
  cmp_ok($g[1],'>',1.0,"$fn: $case green still gets its measured ratio");
  cmp_ok($g[$_],'<=',2.0,"$fn: $case channel $_ stays within the ceiling") for 0..2;
 }

 # Aug 11 converged read: every channel measurable, so behavior is unchanged
 # (plain target/measured ratio, well inside the clamps).
 my @n=$gain->({X=>0.01223,Y=>0.01290,Z=>0.01311},0.0128,$wx,$wy,2);
 for my $ch (0..2) {
  cmp_ok(abs($n[$ch]-1.0),'<',0.1,"$fn: neutral measurable read keeps a near-unity gain on channel $ch");
 }

 # A genuinely dark but neutral patch at its own target must not run away.
 my $dY=0.0005;
 my @d=$gain->({X=>$wx/$wy*$dY,Y=>$dY,Z=>(1-$wx-$wy)/$wy*$dY},$dY,$wx,$wy,2);
 cmp_ok(abs($d[$_]-1.0),'<',0.01,"$fn: dark neutral patch on target stays at unity on channel $_") for 0..2;

 # No usable luminance: nothing to reason from, so no move at all.
 is_deeply([$gain->({X=>0.001,Y=>0,Z=>0.001},0.011,$wx,$wy,2)],[1,1,1],"$fn: Y of zero leaves every channel at 1.0");
 is_deeply([$gain->({X=>0.001,Y=>-0.0001,Z=>0.001},0.011,$wx,$wy,2)],[1,1,1],"$fn: negative Y leaves every channel at 1.0");
 is_deeply([$gain->({},0.011,$wx,$wy,2)],[1,1,1],"$fn: missing reading leaves every channel at 1.0");

 # A channel whose *target* is not positive has nothing to be raised toward.
 # Target chromaticity on the blue-free spectral locus projects to a
 # non-positive blue in both BT.709 and Display-P3.
 my @t=$gain->({%{$blue_starved{'Sep 23 sdr26_2%'}[0]}},0.0110,0.45,0.54,2);
 is($t[2],1.0,"$fn: unmeasurable channel with a non-positive target is left at 1.0");
}

# The ceiling gain is bounded per iteration by the existing SDR damp (the
# ~1.25 step Aug 11's 2% anchor took on blue).
is(main::lg_autocal_26_sdr26_dpg_damp(2.0,0.8,0.5),1.25,'SDR damp caps the ceiling gain at 1.25 per iteration');

# Pin the call sites: the fix only matters while the solvers still route body
# anchors through these functions.
my $src=do { local $/; open(my $fh,'<',"$Bin/../usr/bin/meter_lg_autocal.pl") or die $!; <$fh> };
like($src,qr/\(\$rg,\$gg,\$bg\)=lg_autocal_26_sdr26_dpg_gain\(\$reading,/,'SDR26 greyscale solver calls lg_autocal_26_sdr26_dpg_gain');
like($src,qr/\(\$rg,\$gg,\$bg\)=lg_autocal_26_hdr20_dpg_gain\(\$reading,/,'HDR20 greyscale solver calls lg_autocal_26_hdr20_dpg_gain');

done_testing();
