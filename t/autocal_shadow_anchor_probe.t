#!/usr/bin/perl
# Drives run_hdr20_postcal_shadow_correction in the 3D worker against a
# simulated panel modelled on the G3 HDR10 jobs of 18 and 19 September
# 2026: the panel samples the bound DPG at true indices well below the
# static zone table, averages the correction over a +-3 index window and
# answers lift = baseline * exp(-k * effective_counts). Covers the zone
# probe bracket refinement, the noise-robust dead-anchor guard and the
# early exit of the pass loop.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

my $worker=$ENV{PGEN_AUTOCAL_3D_WORKER} || "$Bin/../usr/bin/meter_lg_3d_autocal.pl";
do $worker;
die "worker failed to load: $@" if($@);

# --- Simulated panel -----------------------------------------------
my @anchor_ire=(5,10,15,20,25,30);
my %default_true_idx=(5=>26,10=>45,15=>52,20=>70,25=>95,30=>116);
my %true_idx=%default_true_idx;
my %job1_baseline=(5=>1.299,10=>1.518,15=>1.199,20=>1.081,25=>1.063,30=>0.978);
# 54 counts take the 5% anchor from 1.30 to about 0.985.
my $K=log(1.30/0.985)/54;
# Identity DPG: value = index * 32 on each channel block.
my @base=map { ($_ % 1024)*32 } (0..3071);
my $tmp=tempdir(CLEANUP=>1);

my %panel;
sub effective_counts {
 my ($ire)=@_;
 my $t=$true_idx{$ire};
 my $sum=0;
 for my $k ($t-3..$t+3) { $sum+=$base[1024+$k]-$panel{bound}->[1024+$k]; }
 return $sum/7;
}
sub panel_lift {
 my ($ire)=@_;
 my $f=defined($panel{sens}{$ire}) ? $panel{sens}{$ire} : 1;
 return $panel{baseline}{$ire}*exp(-$K*$f*effective_counts($ire));
}

*main::write_state=sub { return 1; };
*main::cancelled=sub {
 return (defined($panel{cancel_at_binds}) && $panel{binds} >= $panel{cancel_at_binds}) ? 1 : 0;
};
*main::log_line=sub { push @{$panel{log}}, $_[0]; };
*main::hdr20_postcal_save_matrix=sub { $panel{matrix_saves}++; $panel{matrix_save_args}=[ @_ ]; return 1; };
*main::reading_xyz=sub { my ($reading)=@_; return [0,$reading->{Y},0]; };
*main::api_json=sub {
 my ($method,$path,$payload)=@_;
 if($path eq "/api/lg/1d-dpg/upload") {
  if(!$payload->{keep_calibration_mode}) {
   $panel{bound}=[ @{$payload->{dpg_data}} ];
   $panel{binds}++;
  }
  return { status=>"ok", cal_start_response=>{type=>"response"}, cal_end_response=>{type=>"response"} };
 }
 $panel{reestablish}++ if($path eq "/api/lg/3d-lut/reset");
 return { status=>"ok" };
};
*main::read_step=sub {
 my ($config,$step,$state)=@_;
 my $ire=$step->{ire}+0;
 my $pass=(($state->{current_name}||"") =~ /pass (\d+)/) ? $1 : 0;
 # A stop request during a read comes back as the error string
 # "cancelled" from read_step, not as a die.
 return (undef,"cancelled") if(defined($panel{cancel_read_at_pass}) && $pass == $panel{cancel_read_at_pass});
 if(ref($panel{replay}) eq "HASH") {
  # Recorded job: the lift read on this pass, whatever the DPG holds.
  my $rec=$panel{replay}{$pass};
  my $l=(ref($rec) eq "HASH" && defined($rec->{$ire})) ? $rec->{$ire} : 1;
  $panel{reads}++;
  return ({ Y=>$l*main::hdr20_postcal_target5_for_step($step,$panel{peak}) }, undef);
 }
 my $lift=panel_lift($ire);
 my $noise=$panel{noise};
 $lift+=$noise->{delta} if($noise && $pass == $noise->{pass} && $ire == $noise->{ire});
 $panel{reads}++;
 my $target=main::hdr20_postcal_target5_for_step($step,$panel{peak});
 return ({ Y=>$lift*$target }, undef);
};

my $run_no=0;
sub run_panel {
 my (%opt)=@_;
 %panel=(
  bound=>[ @base ], binds=>0, reads=>0, reestablish=>0, matrix_saves=>0, log=>[], peak=>800,
  sens=>($opt{sens}||{}), noise=>$opt{noise}, cancel_at_binds=>$opt{cancel_at_binds},
  cancel_read_at_pass=>$opt{cancel_read_at_pass},
  baseline=>($opt{baseline}||{ %job1_baseline }), replay=>$opt{replay},
 );
 %true_idx=(ref($opt{true_idx}) eq "HASH") ? %{$opt{true_idx}} : %default_true_idx;
 $run_no++;
 my $matrix_path="$tmp/matrix-$run_no.json";
 if(ref($opt{matrix}) eq "HASH") {
  open(my $fh,">",$matrix_path) or die "cannot write $matrix_path: $!";
  print $fh JSON::PP->new->canonical(1)->encode($opt{matrix});
  close($fh);
 }
 my $config={
  signal_mode=>"hdr10",
  full_workflow=>1,
  picture_mode=>"cinema",
  lg_autocal_hdr20_postcal_shadow_enable=>1,
  lg_autocal_hdr20_postcal_shadow_matrix_path=>$matrix_path,
  postcal_shadow_probe_step=>{ r=>108, g=>108, b=>108, input_max=>1023 },
  pattern_signal_range=>"1",
  full_workflow_dpg_data=>[ @base ],
  full_workflow_peak_luminance=>800,
  postcal_shadow_settle_ms=>100,
  %{$opt{config}||{}},
 };
 my $state={ signal_mode=>"hdr10" };
 my $status=eval { main::run_hdr20_postcal_shadow_correction($config,$state,{}) };
 my $err=$@;
 return ($status,$state,$err);
}
# Static zone scales that reproduce a given zone set (default: the
# stacked pre-fix zones 26/51/53/70/95/116) when the probe is off.
sub stacked_zone_scales {
 my (%zone)=@_;
 %zone=(5=>26,10=>51,15=>53,20=>70,25=>95,30=>116) if(!scalar(keys %zone));
 return join(",",map { sprintf("%d:%.5f",$_,$zone{$_}/($_/100*1023)) } @anchor_ire);
}
sub slope_src_of {
 my ($state,$pass,$idx)=@_;
 my $s=$state->{"postcal_shadow_pass_${pass}_slope_src"};
 return (ref($s) eq "HASH" && defined($s->{$idx})) ? $s->{$idx} : "";
}
sub zones_of {
 my ($status)=@_;
 my @z=split(/,/,$status->{zone_probe}||"");
 my %by_ire;
 for(my $i=0;$i<@anchor_ire;$i++) { $by_ire{$anchor_ire[$i]}=$z[$i]; }
 return %by_ire;
}
sub pass_series {
 my ($state,$idx,$ire)=@_;
 my @out;
 for(my $p=1;$p<=10;$p++) {
  my $c=$state->{"postcal_shadow_pass_${p}_counts"};
  last if(ref($c) ne "HASH");
  push @out, sprintf("%d:%.1f->%.3f",$p,$c->{$idx},$state->{"postcal_shadow_pass_${p}_IRE_${ire}_lift"});
 }
 return join(", ",@out);
}

# (1) The ladder alone puts 10% and 15% in one bracket: neither is
# crushed by the shelf ending at 39, both by the shelf ending at 53. The
# old assignment clamped both priors into that bracket, two indices
# apart. The refined probe must separate them by at least 4.
{
 %panel=(bound=>[ @base ], baseline=>{ %job1_baseline }, sens=>{});
 my %crushed;
 for my $x (39,53) {
  my $shelf=main::hdr20_postcal_monotone_clamp(main::hdr20_postcal_prefix_shelf(\@base,$x,300));
  $panel{bound}=$shelf;
  for my $ire (10,15) { $crushed{$x}{$ire}=(panel_lift($ire) < 0.88*$job1_baseline{$ire}) ? 1 : 0; }
 }
 ok(!$crushed{39}{10} && !$crushed{39}{15}, 'ladder shelf at 39 leaves 10% and 15% untouched');
 ok($crushed{53}{10} && $crushed{53}{15}, 'ladder shelf at 53 crushes both 10% and 15% (one shared bracket)');

 my ($status,$state)=run_panel();
 my %z=zones_of($status);
 diag("zones: ".$status->{zone_probe}."; refinement shelves: ".($state->{postcal_shadow_zone_probe_refine}||"none"));
 ok(($state->{postcal_shadow_zone_probe_refine}||"") ne "", 'shared bracket triggered refinement shelves');
 cmp_ok($z{10}-$z{5}, '>=', 4, '10% anchor sits at least 4 indices above 5%');
 cmp_ok($z{15}-$z{10}, '>=', 4, '15% anchor sits at least 4 indices above 10%');
 ok($z{5} < $z{10} && $z{10} < $z{15} && $z{15} < $z{20} && $z{20} < $z{25} && $z{25} < $z{30}, 'zones ascend with IRE');
 ok(abs($z{10}-$true_idx{10}) <= 3, "10% zone $z{10} within 3 of the true index $true_idx{10}");
 ok(abs($z{15}-$true_idx{15}) <= 3, "15% zone $z{15} within 3 of the true index $true_idx{15}");
 ok(scalar(grep { /zone probe: refinement shelf X=/ } @{$panel{log}}), 'refinement shelves are logged');
 ok(scalar(grep { /zone probe: zones .* refinement shelves / } @{$panel{log}}), 'final zones line names the refinement shelves');

 # (2) The loop converges inside the pass budget.
 diag(sprintf("baseline worst %.3f, best worst %.3f after %d passes (%s)",
  $status->{baseline_worst},$status->{best_worst},$status->{passes},$status->{status}));
 diag("10% anchor by pass: ".pass_series($state,$z{10},10));
 diag("15% anchor by pass: ".pass_series($state,$z{15},15));
 is($status->{status}, 'converged', 'simulated G3 panel converges');
 ok($status->{within_tolerance}, 'best pass is within tolerance');
 cmp_ok($status->{best_worst}, '<=', $status->{tolerance}, 'worst anchor error is inside the 5% tolerance');
 cmp_ok($status->{passes}, '<=', 6, 'converged inside the pass budget');
 ok(!grep({ /^postcal_shadow_dead_anchor_/ } keys %{$state}), 'no anchor was declared dead');
 is($panel{matrix_saves}, 1, 'converged run saves the matrix seed once');
 is($panel{matrix_save_args}[6], 'cinema', 'saved seed records the picture mode');
}

# (3) One noisy read does not freeze a slow anchor. The 10% anchor
# responds at 0.68x (slow, as on the G3), so a +0.15 read after a
# 28-count move flips its two-point secant (the G3 read was about +0.09
# against an expected -0.06). The anchor is held for one pass and
# re-read; the drift over the held move is well above half the peers'
# cumulative median, so it confirms the slope and the anchor moves on.
# The previous guard froze it on the noisy pass.
{
 my ($status,$state)=run_panel(sens=>{10=>0.68}, noise=>{pass=>3, ire=>10, delta=>0.15});
 my %z=zones_of($status);
 my $idx=$z{10};
 diag("noisy run zones: ".$status->{zone_probe});
 diag("10% anchor by pass: ".pass_series($state,$idx,10));
 cmp_ok($state->{postcal_shadow_pass_3_counts}{$idx}-$state->{postcal_shadow_pass_2_counts}{$idx}, '>=', 25, 'noisy pass follows a move of at least 25 counts');
 is(slope_src_of($state,3,$idx), 'hold', 'rejected secant on the noisy pass holds the anchor');
 is($state->{postcal_shadow_pass_4_counts}{$idx}, $state->{postcal_shadow_pass_3_counts}{$idx}, 'held anchor is re-read at the same counts, not inflated');
 is(slope_src_of($state,4,$idx), 'confirmed', 'fresh read confirms the slope over the held move');
 ok(!$state->{"postcal_shadow_dead_anchor_$idx"}, '10% anchor is not declared dead after one noisy read');
 cmp_ok($state->{postcal_shadow_pass_5_counts}{$idx}, '>', $state->{postcal_shadow_pass_4_counts}{$idx}, '10% anchor keeps moving once confirmed');
 is($status->{status}, 'converged', 'noisy run still converges');
 my $confirm_run=0;
 my $confirm_max=0;
 for(my $p=1;$p<=6;$p++) {
  my $s=$state->{"postcal_shadow_pass_${p}_slope_src"};
  last if(ref($s) ne "HASH");
  $confirm_run=(($s->{$idx}||"") eq "confirmed") ? $confirm_run+1 : 0;
  $confirm_max=$confirm_run if($confirm_run > $confirm_max);
 }
 cmp_ok($confirm_max, '<=', 2, 'no anchor runs on a confirmed slope for more than two consecutive passes');
}

# (5) Stacked zones are clearly worse than probed ones. A stronger 10%
# lift (1.70) makes the 10%/15% interaction bite: with the probe off and
# the pre-fix zones 26/51/53/70/95/116 supplied as static scales, the
# same loop cannot bring the 15% anchor inside tolerance.
{
 my %strong=(%job1_baseline, 10=>1.70);
 my ($probed,$probed_state)=run_panel(baseline=>{ %strong });
 my ($stacked,$stacked_state)=run_panel(baseline=>{ %strong }, config=>{
  lg_autocal_hdr20_postcal_shadow_zone_probe=>0,
  lg_autocal_hdr20_postcal_shadow_zone_scales=>stacked_zone_scales(),
 });
 my @stacked_zones=sort { $a <=> $b } keys %{$stacked_state->{postcal_shadow_pass_1_counts}};
 diag(sprintf("strong 10%% lift: probed zones %s worst %.3f (%s); stacked zones %s worst %.3f (%s)",
  $probed->{zone_probe},$probed->{best_worst},$probed->{status},join("/",@stacked_zones),$stacked->{best_worst},$stacked->{status}));
 is(join("/",@stacked_zones), '26/51/53/70/95/116', 'static scales reproduce the stacked pre-fix zones');
 is($panel{matrix_saves}, 0, 'best effort does not persist a seed');
 is($probed->{status}, 'converged', 'probed zones converge with the stronger 10% lift');
 cmp_ok($stacked->{best_worst}, '>', $stacked->{tolerance}, 'stacked zones stay outside tolerance');
 cmp_ok($stacked->{best_worst}, '>', 2*$probed->{best_worst}, 'stacked zones give a clearly worse worst anchor');
}

# (7) The refinement cap is global. Three ladder brackets each hold a
# pair (true indices 30/36, 60/66 and 100/106): the two lowest are
# separated with three shelves, the top pair is left unrefined, named
# in the log and spread through its bracket at one third and two thirds.
{
 my ($status,$state)=run_panel(
  true_idx=>{5=>30,10=>36,15=>60,20=>66,25=>100,30=>106},
  config=>{ lg_autocal_hdr20_postcal_shadow_max_passes=>1 },
 );
 my %z=zones_of($status);
 diag("cap run zones: ".$status->{zone_probe}."; shelves ".$state->{postcal_shadow_zone_probe_refine});
 is(scalar(split(/,/,$state->{postcal_shadow_zone_probe_refine})), 3, 'no more than 3 refinement shelves per probe');
 ok($state->{postcal_shadow_zone_probe_refine_capped}, 'cap reached is recorded');
 ok(scalar(grep { /refinement cap of 3 shelves reached; unrefined shared brackets: 96\.\.116 \(IRE 25\/30\)/ } @{$panel{log}}), 'log names the bracket left unrefined');
 ok(scalar(grep { /zone probe: zones .*\(refinement cap reached\)/ } @{$panel{log}}), 'final zones line says the cap was reached');
 cmp_ok($z{10}-$z{5}, '>=', 4, 'lowest pair separated');
 cmp_ok($z{20}-$z{15}, '>=', 4, 'middle pair separated');
 is("$z{25}/$z{30}", '102/109', 'unrefined pair placed at one third and two thirds of its bracket');
}

# (8) Replay of the two recorded G3 jobs (docs/REFBUGS-logs items 0 and
# 4): the reads of each pass are fed back as recorded, with the probe
# off, the recorded zones and the job's gain of 150. The stacked 10%
# anchor (index 51, then 39) must be held after its rejected pass-4
# secant and parked at its best pass on pass 5, not driven further up.
{
 my %jobs=(
  "items/0 index 51"=>{ zones=>{5=>26,10=>51,15=>53,20=>70,25=>95,30=>116}, watch=>51, lifts=>{
   1=>{5=>1.2988,10=>1.5176,15=>1.1987,20=>1.0807,25=>1.0629,30=>0.9779},
   2=>{5=>1.0627,10=>1.3339,15=>1.0993,20=>1.0708,25=>1.0565,30=>0.9810},
   3=>{5=>0.9855,10=>1.2863,15=>1.0436,20=>1.0448,25=>1.0147,30=>0.9799},
   4=>{5=>1.0027,10=>1.3112,15=>0.9914,20=>1.0136,25=>0.9907,30=>0.9802},
   5=>{5=>0.9936,10=>1.2973,15=>0.9902,20=>1.0130,25=>0.9877,30=>0.9813},
   6=>{5=>1.0042,10=>1.3086,15=>0.9942,20=>1.0150,25=>0.9909,30=>0.9832} } },
  "items/4 index 39"=>{ zones=>{5=>26,10=>39,15=>41,20=>70,25=>95,30=>116}, watch=>39, lifts=>{
   1=>{5=>1.4174,10=>1.5179,15=>1.2108,20=>1.0782,25=>1.0967,30=>1.0010},
   2=>{5=>1.0703,10=>1.2844,15=>1.0909,20=>1.0691,25=>1.0879,30=>1.0053},
   3=>{5=>0.9711,10=>1.2126,15=>0.9874,20=>1.0407,25=>1.0682,30=>1.0057},
   4=>{5=>0.9924,10=>1.2560,15=>0.8835,20=>1.0249,25=>1.0048,30=>1.0045},
   5=>{5=>0.9957,10=>1.2634,15=>0.8837,20=>1.0200,25=>0.9770,30=>1.0007},
   6=>{5=>0.9996,10=>1.2694,15=>0.8833,20=>1.0225,25=>0.9790,30=>0.9992} } },
 );
 for my $name (sort keys %jobs) {
  my $job=$jobs{$name};
  my $idx=$job->{watch};
  my ($status,$state)=run_panel(replay=>$job->{lifts}, config=>{
   lg_autocal_hdr20_postcal_shadow_zone_probe=>0,
   lg_autocal_hdr20_postcal_shadow_zone_scales=>stacked_zone_scales(%{$job->{zones}}),
   lg_autocal_hdr20_postcal_shadow_gain=>150,
  });
  diag("$name replay: ".pass_series($state,$idx,10));
  my $c=sub { $state->{"postcal_shadow_pass_$_[0]_counts"}{$idx} };
  ok(abs($c->(2)-77.6) < 1 && abs($c->(4)-197.6) < 1, "$name: replay reproduces the recorded counts up to pass 4");
  is(slope_src_of($state,4,$idx), 'hold', "$name: rejected pass-4 secant holds the anchor");
  is($c->(5), $c->(4), "$name: pass 5 re-reads at the held counts, not 60 higher");
  is(slope_src_of($state,5,$idx), 'dead', "$name: flat drift over the held move declares it dead on pass 5");
  ok($state->{"postcal_shadow_dead_anchor_$idx"}, "$name: dead flag recorded");
  ok(abs($c->(6)-$c->(3)) < 0.01, "$name: parked at its best pass (pass-3 counts), not its last value");
 }
}

# (9) A stop during a pass-loop anchor read returns the string
# "cancelled" from read_step. The loop must raise it as a cancel, not
# finalise a best effort: no matrix save, no re-establish.
{
 my ($status,$state,$err)=run_panel(cancel_read_at_pass=>2);
 is($err, "cancelled\n", 'cancelled read on pass 2 propagates as cancelled');
 ok(!defined($status), 'cancelled run returns no status');
 is($panel{matrix_saves}, 0, 'cancelled run does not save the matrix seed');
 is($panel{reestablish}, 0, 'cancelled run does not re-establish the held session');
 ok(!exists($state->{postcal_shadow_pass_2_worst}), 'pass 2 never completed');
}

# (10) A live but slow anchor is not parked by the confirm gate. The
# 10% anchor at 0.3x sensitivity takes a +0.15 read after a 60-count
# move; its drift over the held move is negative but weaker than half
# the peers' cumulative median, so it falls through to the median-slope
# update instead of being declared dead, and ends closer to target than
# the parked value would have been.
{
 my ($status,$state)=run_panel(sens=>{10=>0.30}, noise=>{pass=>3, ire=>10, delta=>0.15});
 my %z=zones_of($status);
 my $idx=$z{10};
 diag("slow anchor run: ".pass_series($state,$idx,10).sprintf(" (best worst %.3f, %s)",$status->{best_worst},$status->{status}));
 is(slope_src_of($state,3,$idx), 'hold', 'noisy read after the big move holds the slow anchor');
 is(slope_src_of($state,4,$idx), 'median', 'weak but live drift falls through to the median-slope update');
 ok(!$state->{"postcal_shadow_dead_anchor_$idx"}, 'slow anchor is not declared dead');
 my $parked_err=abs($state->{postcal_shadow_pass_4_IRE_10_lift}-1);
 cmp_ok($status->{best_worst}, '<', $parked_err, sprintf('best worst %.3f beats the %.3f it would have been parked at',$status->{best_worst},$parked_err));
}

# (11) Ten-pass replays of the confirm streak. The 10% anchor's reads
# alternate a noisy rise with a real drop, so it cycles hold/confirmed
# twice; on the third confirm the streak is exhausted and it degrades
# to the median slope when the peers move (valid secants every pass) or
# waits when they are silent (no peer slope at all), keeping the streak.
{
 my %ten=(1=>1.50,2=>1.30,3=>1.35,4=>1.20,5=>1.25,6=>1.10,7=>1.15,8=>0.90,9=>0.92,10=>0.95);
 for my $peers ("moving","silent") {
  my %lifts;
  for my $p (1..10) {
   $lifts{$p}={ 10=>$ten{$p} };
   for my $ire (5,15,20,25,30) { $lifts{$p}{$ire}=($peers eq "moving") ? 1.30-0.02*($p-1) : 1.0; }
  }
  my ($status,$state)=run_panel(replay=>\%lifts, config=>{
   lg_autocal_hdr20_postcal_shadow_zone_probe=>0,
   lg_autocal_hdr20_postcal_shadow_max_passes=>10,
  });
  my $idx=51;
  diag("$peers peers: ".pass_series($state,$idx,10));
  my @src=map { slope_src_of($state,$_,$idx) } (3..8);
  is(join("/",@src), "hold/confirmed/hold/confirmed/hold/".($peers eq "moving" ? "median" : "wait"), "$peers peers: streak sequence over passes 3-8");
  ok(!$state->{"postcal_shadow_dead_anchor_$idx"}, "$peers peers: anchor never declared dead");
  if($peers eq "silent") {
   # Nothing else can move once the anchor waits, so the early exit
   # ends the run there with the counts unchanged.
   is($status->{passes}, 8, 'wait keeps the counts and the run stops early');
   like($status->{note}, qr/early exit after pass 8/, 'early exit after the wait is noted');
   is($state->{postcal_shadow_pass_8_confirm_streak}{$idx}, 2, 'wait keeps the confirm streak');
  } else {
   isnt($state->{postcal_shadow_pass_9_counts}{$idx}, $state->{postcal_shadow_pass_8_counts}{$idx}, 'median update moves the anchor');
  }
 }
}

# (12) The seed is applied to the 5% anchor's first correction when the
# matrix entry matches this TV's series+model key and picture mode (or
# the operator configured seed_counts), only when the anchor is lifted,
# and never above the gain step plus 60; otherwise the gain step is
# kept and the reason logged.
{
 my $gen={ series=>"G3", model_name=>"OLED55G36LA" };
 my $entry=sub { my ($pm,$seed)=@_; $seed=57 if(!defined($seed)); { hdr20=>{ g3oled55g36la=>{ seed_counts=>$seed, picture_mode=>$pm, band_top_ire=>25, taper_top_ire=>30, tol=>0.15 } } } };
 my $gain_step=180*(1.299-1);
 my ($status,$state)=run_panel(matrix=>$entry->("cinema"), config=>{ lg_generation=>$gen, lg_autocal_hdr20_postcal_shadow_max_passes=>2 });
 my %z=zones_of($status);
 is($state->{postcal_shadow_pass_2_counts}{$z{5}}+0, 57, 'matching seed sets the 5% anchor first correction');
 is(slope_src_of($state,1,$z{5}), 'seed', 'seed is recorded as the pass-1 source');
 ok(scalar(grep { /5% anchor seeded at 57\.0 counts from the matrix entry g3oled55g36la \(picture mode 'cinema'\)/ } @{$panel{log}}), 'seed application is logged');
 ($status,$state)=run_panel(matrix=>$entry->("filmmaker"), config=>{ lg_generation=>$gen, lg_autocal_hdr20_postcal_shadow_max_passes=>2 });
 %z=zones_of($status);
 ok(abs($state->{postcal_shadow_pass_2_counts}{$z{5}}-$gain_step) < 0.5, 'mismatched picture mode leaves the gain step');
 ok(scalar(grep { /matrix seed not applied: matrix entry for g3oled55g36la is for picture mode 'filmmaker', this run is 'cinema'/ } @{$panel{log}}), 'seed rejection says why');
 # A seed recorded on another panel of the same series (series-only
 # key) is not found for this TV.
 ($status,$state)=run_panel(matrix=>{ hdr20=>{ g3=>{ seed_counts=>57, picture_mode=>"cinema" } } }, config=>{ lg_generation=>$gen, lg_autocal_hdr20_postcal_shadow_max_passes=>2 });
 %z=zones_of($status);
 ok(abs($state->{postcal_shadow_pass_2_counts}{$z{5}}-$gain_step) < 0.5, 'series-only entry from another panel does not fire');
 ok(!grep({ /anchor seeded/ } @{$panel{log}}), 'no seed is logged for a series-only entry');
 # A legacy signal-mode entry is ignored even without generation data.
 ($status,$state)=run_panel(matrix=>{ hdr20=>{ hdr10=>{ seed_counts=>57, picture_mode=>"cinema" } } }, config=>{ lg_autocal_hdr20_postcal_shadow_max_passes=>2 });
 %z=zones_of($status);
 ok(!grep({ /anchor seeded/ } @{$panel{log}}), 'legacy signal-mode entry is not applied');
 ok(abs($state->{postcal_shadow_pass_2_counts}{$z{5}}-$gain_step) < 0.5, 'fallback-key seed leaves the gain step');
 # The operator's configured seed_counts is honoured when no entry matches.
 ($status,$state)=run_panel(config=>{ lg_generation=>$gen, lg_autocal_hdr20_postcal_shadow_seed_counts=>40, lg_autocal_hdr20_postcal_shadow_max_passes=>2 });
 %z=zones_of($status);
 is($state->{postcal_shadow_pass_2_counts}{$z{5}}+0, 40, 'configured seed_counts is applied when no matrix entry matches');
 ok(scalar(grep { /5% anchor seeded at 40\.0 counts from the configured seed_counts/ } @{$panel{log}}), 'configured seed is logged as such');
 # Legacy entries must not hide the explicit knob on known or unknown TVs.
 for my $generation ($gen, {}) {
  ($status,$state)=run_panel(matrix=>{ hdr20=>{ hdr10=>{ seed_counts=>57, picture_mode=>"cinema" } } }, config=>{ lg_generation=>$generation, lg_autocal_hdr20_postcal_shadow_seed_counts=>40, lg_autocal_hdr20_postcal_shadow_max_passes=>2 });
  %z=zones_of($status);
  is($state->{postcal_shadow_pass_2_counts}{$z{5}}+0, 40, 'legacy entry does not shadow the configured seed');
  ok(scalar(grep { /5% anchor seeded at 40\.0 counts from the configured seed_counts/ } @{$panel{log}}), 'configured seed source survives a legacy entry');
 }
 # A stale seed of 300 against a panel needing 54 is clamped to the gain
 # step plus 60 and the run still converges.
 ($status,$state)=run_panel(matrix=>$entry->("cinema",300), config=>{ lg_generation=>$gen });
 %z=zones_of($status);
 diag("stale seed run: ".pass_series($state,$z{5},5).sprintf(" (%s, best worst %.3f)",$status->{status},$status->{best_worst}));
 ok(abs($state->{postcal_shadow_pass_2_counts}{$z{5}}-($gain_step+60)) < 0.5, 'stale seed is clamped to the gain step plus 60');
 ok(scalar(grep { /seed 300 clamped to the gain step plus 60/ } @{$panel{log}}), 'clamp is logged');
 is($status->{status}, 'converged', 'clamped stale seed still converges');
 # A 5% anchor that starts dark takes the floored gain step, not the seed.
 ($status,$state)=run_panel(matrix=>$entry->("cinema"), baseline=>{ %job1_baseline, 5=>0.93 }, config=>{ lg_generation=>$gen, lg_autocal_hdr20_postcal_shadow_max_passes=>2 });
 %z=zones_of($status);
 is($state->{postcal_shadow_pass_2_counts}{$z{5}}+0, 0, 'dark 5% anchor takes the floored gain step');
 isnt(slope_src_of($state,1,$z{5}), 'seed', 'dark anchor is not seeded');
 ok(scalar(grep { /seed not applied: pass-1 lift 0\.930 is not above target 1\.000/ } @{$panel{log}}), 'dark-anchor seed refusal is logged');
}

# (13) When the 4-index spacing moves an anchor above its measured
# bracket the override is logged. At 0.09x the 10% anchor shares the
# narrow bracket 47..49 with 15%, which is pushed to 51.
{
 my ($status,$state)=run_panel(sens=>{10=>0.09}, config=>{ lg_autocal_hdr20_postcal_shadow_max_passes=>1 });
 diag("spacing run zones: ".$status->{zone_probe});
 ok(scalar(grep { /zone probe: IRE 15 moved from 48 to 51 to keep 4 indices above IRE 10, above its measured bracket 47\.\.49/ } @{$panel{log}}), 'spacing override above the measured bracket is logged');
}

# (6) Cancellation inside a refinement shelf propagates as "cancelled"
# instead of being swallowed as an error, and the held session is not
# re-established for a run that is aborting. The 7th single-socket bind
# is the first refinement shelf, so the cancel is first seen by the
# per-member check between its reads.
{
 my ($status,$state,$err)=run_panel(cancel_at_binds=>7);
 is($err, "cancelled\n", 'cancel during a refinement read propagates as cancelled');
 ok(!defined($status), 'cancelled run returns no status');
 is($panel{reestablish}, 0, 'cancelled run does not re-establish the held session');
 is($panel{binds}, 7, 'cancel was raised inside the first refinement shelf');
}

# (4) Early exit. No anchor responds and only 5/10/15 start lifted, so
# the three lifted anchors are declared dead on pass 3 (parked at their
# best pass, counts 0) and pass 4 changes nothing; the loop stops there
# instead of spending the rest of the budget.
{
 my ($status,$state)=run_panel(
  sens=>{ map { $_=>0 } @anchor_ire },
  baseline=>{ 5=>1.299, 10=>1.518, 15=>1.199, 20=>1.0, 25=>1.0, 30=>1.0 },
 );
 my %z=zones_of($status);
 diag("dead panel zones: ".$status->{zone_probe}."; passes ".$status->{passes}."; status ".$status->{status});
 is($status->{passes}, 4, 'loop stops after the first pass with no count change');
 like($status->{note}, qr/early exit after pass 4/, 'early exit is noted');
 ok(scalar(grep { /no anchor counts changed after pass 4/ } @{$panel{log}}), 'early exit is logged');
 for my $ire (5,10,15) {
  ok($state->{"postcal_shadow_dead_anchor_$z{$ire}"}, "$ire% anchor declared dead after two flat passes");
  is($state->{postcal_shadow_pass_4_counts}{$z{$ire}}+0, 0, "$ire% anchor parked at its best pass (counts 0)");
 }
 is($status->{status}, 'reverted', 'no improvement reverts to the base DPG');
}

done_testing();
