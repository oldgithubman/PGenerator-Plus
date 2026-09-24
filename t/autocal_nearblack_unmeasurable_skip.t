#!/usr/bin/perl
# A deepest near-black SDR patch (e.g. sdr26_2.3% on an LG C1) can emit light
# below the colorimeter's usable floor: the meter returns no valid sample after
# the whole retry budget. Historically that unmeasurable read aborted the ENTIRE
# greyscale job (autocal_dpg_read_failure -> die), so a sweep that was otherwise
# complete committed nothing. This test pins the fix: such a patch is carried
# forward (left uncorrected / interpolated from neighbors) and the sweep
# finishes, while a mid/high patch that cannot be read STILL aborts -- that is a
# real meter/signal/alignment fault, not an expected sub-floor condition.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
use JSON::PP ();
do "$Bin/../usr/bin/meter_lg_autocal.pl"; die $@ if $@;
local *main::write_state=sub {};
local *main::log_line=sub {};
# cancelled() consults a stop FILE at a fixed path shared with any real run on
# this machine. A leftover /tmp/meter_lg_autocal.stop made every sweep below
# exit instantly and pass vacuously, so pin cancellation off for the whole file.
local *main::cancelled=sub {0};

my $UNMEASURABLE="No usable meter measurement for sdr26_2.3% after 4 sample attempts; check the signal range, displayed patch and meter alignment";

# ---------------------------------------------------------------------------
# 1. The meter-floor helper: defaults, clamps and the independent SDR/HDR keys.
# ---------------------------------------------------------------------------
is(main::autocal_dpg_meter_floor({},"sdr"),0.003,'SDR meter floor defaults to 0.003');
is(main::autocal_dpg_meter_floor({},"hdr20"),0.003,'HDR meter floor defaults to 0.003');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>0.01},"sdr"),0.01,'SDR meter floor honours its own knob');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>0.01},"hdr20"),0.003,'the HDR floor ignores the SDR knob');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>9},"sdr"),0.05,'meter floor is clamped to a sane ceiling');
is(main::autocal_dpg_meter_floor({lg_autocal_sdr26_dpg_meter_floor=>0},"sdr"),0.0005,'meter floor is clamped to a sane floor');

# ---------------------------------------------------------------------------
# 2. The skip predicate: every guard must agree, so a real fault still aborts.
# ---------------------------------------------------------------------------
my $step_nb={name=>"sdr26_2.3%",ire=>2.3};
# All guards satisfied: deepest near-black, meter proven, sub-floor target,
# unmeasurable-sample class.
ok(main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,$UNMEASURABLE,1),
   'skips a deepest near-black, sub-floor, unmeasurable patch once the meter is proven');
# Guard 1: meter not yet proven this pass.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,$UNMEASURABLE,0),
   'never skips before any valid read has proven the meter');
# Guard 2: IRE above the deepest near-black cap.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",{name=>"5%",ire=>5},0.0035,$UNMEASURABLE,1),
   'never skips a mid/low patch above the near-black IRE cap');
# Guard 3: expected luminance well above the meter floor.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.05,$UNMEASURABLE,1),
   'never skips when the expected target sits above the meter floor margin');
# The default margin is 2x the floor. At a 100-nit SDR white the 2.3% target is
# ~0.0117-0.014 cd/m2, which the C1 measured and converged once the renderer
# showed the requested code -- so that patch is readable and must never be
# written off as sub-floor. Only a dim reference puts it near the floor (0.0035
# above is 2.3% at a ~30-nit white).
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0117,$UNMEASURABLE,1),
   'a 2.3% patch at a 100-nit white (target 0.0117) is readable and is not skipped at the default margin');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0061,$UNMEASURABLE,1),
   'the default margin stops at 2x the 0.003 floor');
# Guard 4: cancellation and non-measurement errors are never sub-floor skips.
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,"Auto Cal cancelled",1),
   'never skips a cancellation');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,"SDR26 1D DPG upload failed",1),
   'never skips an upload/endpoint failure');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,"",1),
   'never skips with an empty reason');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,undef,$UNMEASURABLE,1),
   'never skips when the expected luminance is unknown');
# Config knobs.
ok(!main::autocal_nearblack_unmeasurable_skip({lg_autocal_sdr26_dpg_nearblack_skip_max_ire=>0},"sdr",$step_nb,0.0035,$UNMEASURABLE,1),
   'an operator can disable the skip by setting the IRE cap to 0');
ok(main::autocal_nearblack_unmeasurable_skip({lg_autocal_sdr26_dpg_nearblack_skip_floor_margin=>100},"sdr",$step_nb,0.05,$UNMEASURABLE,1),
   'a wider floor margin lets a slightly brighter near-black patch skip');
# HDR20 uses the same gate.
ok(main::autocal_nearblack_unmeasurable_skip({},"hdr20",$step_nb,0.0035,"No usable meter measurement for 2.3% after 4 sample attempts",1),
   'HDR20 honours the same near-black skip gate');
# Guard 4b: the low-shadow ladder returns the SAME prefix whether the samples
# were valid-but-sub-floor (clean, no suffix -> skippable) or the ladder was
# exhausted by an underlying meter/comms/signal error (which it appends after
# "meter alignment"). A suffix means a real fault drove the failure -> abort.
my $CLEAN="No usable meter measurement for sdr26_2.3% after 4 sample attempts; check the signal range, displayed patch and meter alignment";
ok(main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,$CLEAN,1),
   'skips the CLEAN ladder-exhaustion message (valid-but-sub-floor samples)');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,$CLEAN.": spotread communication timeout",1),
   'never skips when the ladder appended a transient meter/comms error');
ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,$CLEAN.": Pattern rejected",1),
   'never skips when the ladder appended a hard (non-transient) read error');

# ---------------------------------------------------------------------------
# 3. The read-failure router: skip records the patch + throws the sentinel;
#    a non-skip defers to the unchanged fatal path.
# ---------------------------------------------------------------------------
for my $prefix (qw(sdr hdr20)) {
 my $state={};
 my $marker=eval { main::autocal_dpg_read_failure_or_skip($state,{},$prefix,$step_nb,21,"sdr26_2.3%",0.0035,$UNMEASURABLE,1); 1 };
 ok(!$marker,"$prefix near-black skip throws rather than returning");
 ok(main::autocal_nearblack_skip_marker($@),"$prefix throws the skip SENTINEL (a ref), not a fatal string");
 is(ref($state->{"${prefix}_1d_dpg_skipped_anchors"}),"ARRAY","$prefix records the skipped anchor list");
 is($state->{"${prefix}_1d_dpg_skipped_anchors"}[0]{ire},2.3,"$prefix records the skipped patch IRE");
 ok(!$state->{"phase"} || $state->{"phase"} ne "error","$prefix skip does NOT set the fatal error phase");
}
{
 # A mid patch that cannot be read is a genuine fault: the router defers to the
 # fatal path (a plain string die, phase=error), exactly as before the fix.
 my $state={};
 eval { main::autocal_dpg_read_failure_or_skip($state,{},"sdr",{name=>"50%",ire=>50},512,"sdr26_50%",22.7,$UNMEASURABLE,1) };
 ok(!main::autocal_nearblack_skip_marker($@),'a mid patch is NOT carried forward');
 like($@,qr/measurement failed at sdr26_50%.*No usable meter measurement/,'mid patch aborts through the normal fatal message');
 is($state->{"sdr_1d_dpg_exit_reason"},"read_failed",'mid patch keeps the machine-readable failure cause');
}

# ---------------------------------------------------------------------------
# 4. End-to-end SDR26 greyscale: an unmeasurable deepest near-black patch does
#    NOT abort the job; a mid patch still does. This is the observed C1 case.
# ---------------------------------------------------------------------------
sub run_sdr26 {
 my ($fail_ire,%opt)=@_;
 my $state={};
 my $clean="; check the signal range, displayed patch and meter alignment";
 my $suffix=defined($opt{fail_suffix}) ? $opt{fail_suffix} : "";
 my %valid_seen;
 my %first_seen;
 # Once the target patch has gone unmeasurable, the very next upload is the
 # skip handler restoring the pre-anchor curve. fail_upload_after_skip makes
 # every one of its four retries fail, modeling a TV that drops off the wire.
 my $gone_unmeasurable=0;
 # Dark Detail adds the 2, 2.7, 3.7, 6, 8, 9 fillers. It is what puts an anchor
 # BELOW the deepest standard 2.3% one: the sweep runs high->low, so without it
 # 2.3% is the last anchor and nothing afterwards can consume a polluted @done.
 local $main::LG_AUTOCAL_DARK_DETAIL=$opt{dark_detail} ? 1 : 0;
 # Read every patch as a plausible BT.1886 luminance so the sweep converges
 # quickly -- except the target IRE, which is physically unmeasurable. With
 # valid_first set, the target IRE returns ONE barely-valid read (as a patch
 # right at the floor would) before going unmeasurable -- this is the case that
 # can leave a partial correction behind if the skip does not restore the curve.
 local *main::read_step=sub {
  my ($config,$rs,$st)=@_;
  my $ire=defined($rs->{ire})?($rs->{ire}+0):50;
  if(abs($ire-$fail_ire) < 0.01) {
   if($opt{valid_first} && !$valid_seen{sprintf("%.3f",$ire)}++) {
    return ({X=>0.02*0.95,Y=>0.02,Z=>0.02*1.09,x=>0.3127,y=>0.329,luminance=>0.02},undef);
   }
   # flat_valid: the #30 signature -- N valid reads that never move, whatever
   # the solver uploads, because the panel is not showing the corrected code.
   if($opt{flat_valid} && ($valid_seen{sprintf("flat%.3f",$ire)}++ < $opt{flat_valid})) {
    return ({X=>0.0021*0.95,Y=>0.0021,Z=>0.0021*1.09,x=>0.3127,y=>0.329,luminance=>0.0021},undef);
   }
   $gone_unmeasurable=1;
   return (undef,"No usable meter measurement for ".($rs->{name}||"patch")." after 4 sample attempts".$clean.$suffix);
  }
  # A dim ~30-nit white: the only regime where the 2.3% target (~0.0035) sits
  # within the default 2x margin of the meter floor.
  my $y=($ire/100.0)**2.4*30.0; $y=0.0005 if($y<=0);
  # A panel that already measures exactly on target converges on iteration 1 and
  # never rebuilds the curve, which hides anything wrong with the anchor list.
  # Read each patch 25% high ONCE so every anchor actually computes a
  # correction, uploads it and then converges -- the real sweep's behavior.
  $y*=1.25 if($opt{needs_correction} && !$first_seen{sprintf("%.3f",$ire)}++);
  return ({X=>$y*0.95,Y=>$y,Z=>$y*1.09,x=>0.3127,y=>0.329,luminance=>$y},undef);
 };
 local *main::api_json=sub {
  my ($method,$path)=@_;
  return {status=>'error',message=>'TV unreachable'}
   if($opt{fail_upload_after_skip} && $gone_unmeasurable
      && defined($path) && $path=~m{1d-dpg/upload});
  return {status=>'ok'};
 };
 # The full greyscale path emits a pre-existing "isn't numeric" warning from one
 # specific internal range check (line 1342) unrelated to this fix; suppress
 # only that exact line so any NEW numeric warning from the change still surfaces.
 local $SIG{__WARN__}=sub { warn $_[0] unless $_[0]=~/isn't numeric in int at .*meter_lg_autocal\.pl line 1342/; };
 my $config={ signal_mode=>'sdr', ddc_layout=>'sdr26', target_gamma=>'bt1886',
  max_bpc=>10, pattern_signal_range=>2, signal_range=>2, transport_signal_range=>2,
  color_format=>0, lg_autocal_26=>1, black_y=>0, target_delta_e=>0.5 };
 my ($err,$died);
 { local $@; $err=eval { main::lg_autocal_26_run_sdr_1d_dpg_greyscale($config,$state,30,0.3127,0.329,'filmMaker') }; $died=$@; }
 return ($err,$died,$state);
}

{
 # Deepest near-black (2.3%) unmeasurable -> carried forward, job completes.
 my ($err,$died,$state)=run_sdr26(2.3);
 is($died,'','the greyscale does NOT die when the deepest near-black patch is unmeasurable');
 is($err,undef,'and it returns success (no terminal error) so the LUT still commits');
 ok($state->{sdr_1d_dpg_uploaded},'the 1D DPG is reported uploaded (the sweep produced a curve)');
 is(ref($state->{sdr_1d_dpg_skipped_anchors}),"ARRAY",'the skipped patch is recorded for the operator');
 is(scalar(@{$state->{sdr_1d_dpg_skipped_anchors}||[]}),1,'exactly the one deepest near-black patch was skipped');
 is($state->{sdr_1d_dpg_skipped_anchors}[0]{ire},2.3,'and it is the 2.3% patch');
 like($state->{message},qr/left uncorrected/,'the completion message discloses the carried-forward patch');
}
{
 # A mid patch (50%) unmeasurable -> real fault -> the whole job still aborts.
 my ($err,$died,$state)=run_sdr26(50);
 like($died,qr/measurement failed at .*50%.*No usable meter measurement/,'a mid patch that cannot be read STILL aborts the whole greyscale');
 ok(!$state->{sdr_1d_dpg_skipped_anchors} || !@{$state->{sdr_1d_dpg_skipped_anchors}},'nothing is silently carried forward on a genuine mid-patch fault');
}
{
 # A near-black patch whose ladder exhaustion carries a meter/comms error suffix
 # is a real fault, not sub-floor darkness -> the whole job STILL aborts.
 my ($err,$died,$state)=run_sdr26(2.3, fail_suffix=>": spotread communication timeout");
 like($died,qr/measurement failed at .*2\.3%/,'a comms/hardware fault at the deepest near-black patch STILL aborts (not masked as sub-floor)');
 ok(!$state->{sdr_1d_dpg_skipped_anchors} || !@{$state->{sdr_1d_dpg_skipped_anchors}},'a meter fault at 2.3% is not silently carried forward');
}
{
 # The partial-correction guard: a near-black patch that gives ONE barely-valid
 # read (which uploads a provisional gain) before going sub-floor must land on
 # the SAME committed curve as a patch that was unmeasurable from the first read
 # -- i.e. genuinely uncorrected, with no partial move baked in.
 my (undef,$died_a,$state_a)=run_sdr26(2.3);                     # unmeasurable from the first read
 my (undef,$died_b,$state_b)=run_sdr26(2.3, valid_first=>1);     # one valid read, then sub-floor
 is($died_a,'','control run (fail-first) completes');
 is($died_b,'','valid-then-fail run completes');
 is_deeply($state_b->{sdr_1d_dpg_data},$state_a->{sdr_1d_dpg_data},
  'a partial correction from an early barely-valid read is NOT baked into the committed curve (patch truly left uncorrected)');
}
{
 # The same guard, but for the ANCHOR LIST rather than the curve. The inner
 # pushes a provisional anchor onto @done after every accepted upload, so a
 # patch that corrects once and then goes sub-floor leaves its gains there.
 # Restoring only the curve is not enough: the next anchor rebuilds the spline
 # FROM @done and re-applies them, moving the committed curve while the patch
 # is still reported "left uncorrected".
 #
 # Two conditions are needed to observe it, and the original version of this
 # test had neither:
 #   * Dark Detail on, so a 2% anchor runs AFTER the skipped 2.3% one (the
 #     sweep descends, so 2.3% is otherwise the final anchor);
 #   * a later anchor that actually rebuilds, which needs a panel that is off
 #     target (needs_correction) rather than already perfect.
 # Without the restore this diverges by ~99 of 3072 entries.
 my %dd=(dark_detail=>1, needs_correction=>1);
 my (undef,$died_a,$state_a)=run_sdr26(2.3,%dd);
 my (undef,$died_b,$state_b)=run_sdr26(2.3,%dd, valid_first=>1);
 is($died_a,'','dark-detail control run (fail-first) completes');
 is($died_b,'','dark-detail valid-then-fail run completes');
 is(scalar(@{$state_b->{sdr_1d_dpg_skipped_anchors}||[]}),1,'the 2.3% patch is still carried forward with Dark Detail on');
 is_deeply($state_b->{sdr_1d_dpg_data},$state_a->{sdr_1d_dpg_data},
  'the provisional anchor is removed from @done too, so a LATER anchor cannot re-apply the skipped patch gains');
}
{
 # Restoring the pre-anchor curve can itself fail. Exhausting its four retries
 # leaves the panel on the provisional correction while the solver has rolled
 # back, so every later anchor would be measured against a curve the TV is not
 # displaying. That is terminal, not a skip: the sweep must stop and must NOT
 # claim the curve was committed.
 my ($err,$died,$state)=run_sdr26(2.3, valid_first=>1, fail_upload_after_skip=>1);
 is($died,'','a failed restore is reported, not thrown as an uncaught die');
 like($err,qr/upload failed/,'SDR reports a terminal upload failure to the caller');
 ok(!$state->{sdr_1d_dpg_uploaded},'SDR does not claim the 1D DPG was uploaded after a failed restore');
 is($state->{sdr_1d_dpg_exit_reason},'restore_upload_failed','SDR records the machine-readable restore-failure cause');
}

# ---------------------------------------------------------------------------
# 4b. The HDR20 solver's skip handler, via the existing single-anchor test mode.
#     The 1% HDR20 anchor at a 100-nit reference targets ~0.0040 nits, within
#     the default 2x margin of the 0.003 floor. At 600 nits it targets ~0.024 and
#     at 1000 nits ~0.040, both readable and correctly NOT skippable, so the
#     reference has to be a dim one.
# ---------------------------------------------------------------------------
sub run_hdr20 {
 my (%opt)=@_;
 my $state={};
 my $valid=0;
 my $gone_unmeasurable=0;
 # 1% is only a legal HDR20 DDC slot when the Dark Detail ladder is merged.
 local $main::LG_AUTOCAL_DARK_DETAIL=1;
 local $main::LG_AUTOCAL_DDC_LAYOUT="hdr20";
 # One barely-valid read (which proves the meter AND uploads a provisional
 # correction), then physically unmeasurable -- the dangerous ordering.
 local *main::read_step=sub {
  if(!$valid++) { return ({X=>0.019,Y=>0.02,Z=>0.0218,x=>0.3127,y=>0.329,luminance=>0.02},undef); }
  $gone_unmeasurable=1;
  return (undef,"No usable meter measurement for 1% after 4 sample attempts; check the signal range, displayed patch and meter alignment");
 };
 local *main::api_json=sub {
  my ($method,$path)=@_;
  return {status=>'error',message=>'TV unreachable'}
   if($opt{fail_upload_after_skip} && $gone_unmeasurable
      && defined($path) && $path=~m{1d-dpg/upload});
  return {status=>'ok'};
 };
 my @dpg=map {($_%1024)*32} 0..3071;
 my ($err,$died);
 { local $@; $err=eval { main::lg_autocal_26_run_hdr20_dpg_greyscale({
    signal_mode=>'hdr10', target_delta_e=>0.5,
    hdr20_test_anchor_ire=>1, hdr20_test_snapshot_dpg=>\@dpg, hdr20_test_white_ref=>100,
    steps=>[{name=>'1%',ire=>1,stimulus=>1,ddc_layout=>'hdr20',r=>41,g=>41,b=>41,input_max=>4095}],
   },$state,100,0.3127,0.329,'dolbyVisionFilmMaker') }; $died=$@; }
 return ($err,$died,$state);
}
{
 # Control: the restore upload succeeds, so the patch is carried forward and
 # the sweep finishes -- the HDR20 mirror of the SDR end-to-end case.
 my ($err,$died,$state)=run_hdr20();
 is($died,'','HDR20 does NOT die when the deepest near-black patch is unmeasurable');
 is(scalar(@{$state->{hdr20_1d_dpg_skipped_anchors}||[]}),1,'HDR20 records the carried-forward near-black patch');
 is($state->{hdr20_1d_dpg_skipped_anchors}[0]{ire},1,'and it is the 1% patch');
}
{
 # The restore upload exhausts its retries: terminal, exactly as on the SDR path.
 my ($err,$died,$state)=run_hdr20(fail_upload_after_skip=>1);
 is($died,'','a failed HDR20 restore is reported, not thrown as an uncaught die');
 like($err,qr/upload failed/,'HDR20 reports a terminal upload failure to the caller');
 ok(!$state->{hdr20_1d_dpg_uploaded},'HDR20 does not claim the 1D DPG was uploaded after a failed restore');
 is($state->{hdr20_1d_dpg_exit_reason},'restore_upload_failed','HDR20 records the machine-readable restore-failure cause');
}


# ---------------------------------------------------------------------------
# 4c. Guard 5: a patch that ignores the LUT is a fault, not darkness.
#     The one hardware firing of this gate was the #30 renderer defect: code 84
#     shown as code 80, so two valid reads stayed at Y 0.0021 while the solver
#     moved R 976 -> 1220 -> 1525. That passed guards 1-4 and was recorded as
#     "left uncorrected". It must abort, naming the flat response.
# ---------------------------------------------------------------------------
{
 my @dpg=(1000) x 3072;
 my @h;
 main::autocal_dpg_note_anchor_read(\@h,\@dpg,21,{Y=>0.0021,luminance=>0.0021});
 is(scalar(@h),1,'a valid read is recorded with its luminance');
 is_deeply($h[0]{lut},[1000,1000,1000],'and the R/G/B LUT values at idx, idx+1024 and idx+2048');
 main::autocal_dpg_note_anchor_read(\@h,\@dpg,21,undef);
 is(scalar(@h),1,'an invalid read is not recorded');
 is(main::autocal_dpg_anchor_unresponsive(\@h),undef,'one read is too little evidence to call the patch unresponsive');

 my $flat=[{y=>0.0021,lut=>[976,1023,996]},{y=>0.0021,lut=>[1220,1279,1245]},{y=>0.0021,lut=>[1525,1599,1556]}];
 my $why=main::autocal_dpg_anchor_unresponsive($flat);
 ok(defined($why),'the hardware sequence (flat Y across R 976 -> 1525) is unresponsive');
 like($why,qr/did not respond to a LUT change: Y 0\.0021 -> 0\.0021/,'and the description names the flat luminance');

 is(main::autocal_dpg_anchor_unresponsive([{y=>0.0100,lut=>[1000,1000,1000]},{y=>0.0125,lut=>[1100,1100,1100]}]),undef,
  'a patch whose light followed a 10% LUT move is responsive');
 is(main::autocal_dpg_anchor_unresponsive([{y=>0.0100,lut=>[1000,1000,1000]},{y=>0.0100,lut=>[1050,1050,1050]}]),undef,
  'a LUT move under 10% is too small to judge, so it never blocks a skip');
 is(main::autocal_dpg_anchor_unresponsive([{y=>0.0100,lut=>[1000,1000,1000]},{y=>0.0180,lut=>[1300,1000,1000]},{y=>0.0101,lut=>[1000,1000,1000]}]),undef,
  'a move that was reverted is not a flat response (the LUT is the same again)');

 # sdr26_2% on the C1 after #30, straight from the run log: the panel output is
 # quantized near black, so reads alternate between two exact levels. The solver
 # restored near its best between moves, so no flat pair spans a 10% move.
 my $c1_two=[{y=>0.0057,lut=>[608,608,608]},{y=>0.0108,lut=>[721,760,608]},
  {y=>0.0057,lut=>[598,600,608]},{y=>0.0100,lut=>[711,750,608]}];
 is(main::autocal_dpg_anchor_unresponsive($c1_two),undef,'the real quantized 2% sequence is responsive');
 # The same quantization CAN put two LUT values >10% apart on one output step.
 # A pair that responded elsewhere must still clear the patch.
 is(main::autocal_dpg_anchor_unresponsive([{y=>0.0057,lut=>[608,608,608]},{y=>0.0108,lut=>[721,760,608]},{y=>0.0057,lut=>[680,690,608]}]),undef,
  'one responsive pair clears the patch even when another pair lands on the same quantized step');

 ok(!main::autocal_nearblack_unmeasurable_skip({},"sdr",$step_nb,0.0035,$UNMEASURABLE,1,$why),
  'guard 5: an otherwise-skippable patch is NOT skipped once it has shown a flat response');
 my $state={};
 eval { main::autocal_dpg_read_failure_or_skip($state,{},"sdr",$step_nb,21,"sdr26_2.3%",0.0035,$UNMEASURABLE,1,$why) };
 ok(!main::autocal_nearblack_skip_marker($@),'the router aborts instead of throwing the skip sentinel');
 like($@,qr/measurement failed at sdr26_2\.3%.*did not respond to a LUT change/,'and the abort names the flat response, which points at the renderer, not the meter');
 ok(!$state->{sdr_1d_dpg_skipped_anchors},'nothing is recorded as carried forward');
}
{
 # End to end through the real SDR solver: two flat valid reads, then
 # unmeasurable. Before guard 5 this completed with the patch "left uncorrected".
 my ($err,$died,$state)=run_sdr26(2.3, flat_valid=>2);
 like($died,qr/measurement failed at .*2\.3%.*did not respond to a LUT change/,
  'the real sweep aborts on the #30 signature rather than carrying the patch forward');
 ok(!$state->{sdr_1d_dpg_skipped_anchors} || !@{$state->{sdr_1d_dpg_skipped_anchors}},'and records no skipped anchor');
}

# ---------------------------------------------------------------------------
# 4d. The skip is visible at job level. The sweep's own note is overwritten by
#     the worker's final "Auto Cal complete", so the outcome must be stated
#     there and raised as a processing warning the runner lifts onto the item.
# ---------------------------------------------------------------------------
{
 my $clean={};
 main::autocal_apply_completion_outcome($clean);
 is($clean->{message},'Auto Cal complete','a run with nothing carried forward keeps the plain completion message');
 ok(!$clean->{automation_processing_warnings},'and raises no warning');

 my $s={sdr_1d_dpg_skipped_anchors=>[{label=>'sdr26_2.3%'}]};
 main::autocal_apply_completion_outcome($s);
 is($s->{message},'Auto Cal complete; 1 near-black patch not measured (sdr26_2.3%): left uncorrected, outcome unknown',
  'the completion message names the unmeasured patch and says its outcome is unknown');
 is_deeply($s->{automation_processing_warnings},['Greyscale: 1 near-black patch not measured (sdr26_2.3%): left uncorrected, outcome unknown'],
  'and the same note is raised as an automation processing warning');
 main::autocal_apply_completion_outcome($s);
 is(scalar(@{$s->{automation_processing_warnings}}),1,'applying it twice does not duplicate the warning');
 ok((grep { $_ eq 'automation_processing_warnings' } @PGAutomation::WORKER_STATUS_SUMMARY_KEYS),
  'the warning key is in the summary sidecar, so the persisted summary carries it');

 my $h={hdr20_1d_dpg_skipped_anchors=>[{label=>'1%'}],sdr_1d_dpg_skipped_anchors=>[{label=>'sdr26_2.3%'},{label=>'sdr26_2%'}]};
 main::autocal_apply_completion_outcome($h);
 like($h->{message},qr/3 near-black patches not measured \(sdr26_2\.3%, sdr26_2%, 1%\)/,'several patches across layouts are all named');
}

# ---------------------------------------------------------------------------
# 5. Load-bearing call sites (a passing suite must not survive their deletion).
#    Model: t/idle_pattern_seed.t asserts the caller body contains the call.
# ---------------------------------------------------------------------------
my $src=do { open(my $fh,'<',"$Bin/../usr/bin/meter_lg_autocal.pl") or die $!; local $/; <$fh> };

# The SDR inner routes read failures through the gate, never the bare fatal call.
ok($src =~ /my \$_sdr_read_failure=sub \{/, 'SDR inner defines the near-black read-failure router');
ok(index($src,'$_sdr_read_failure->($err)') >= 0, 'SDR inner main read routes through the router');
ok(index($src,'$_sdr_read_failure->($are)') >= 0, 'SDR inner revert re-read routes through the router');
ok($src !~ /autocal_dpg_read_failure\(\$state,"sdr"/, 'no bare SDR fatal read-failure call remains');

# The HDR calibrate_anchor routes read failures through the gate; only the
# outer provisional 100% white-reference read stays a hard abort (never skippable).
ok($src =~ /my \$_hdr_read_failure=sub \{/, 'HDR calibrate_anchor defines the near-black read-failure router');
ok(index($src,'$_hdr_read_failure->(') >= 0, 'HDR read sites route through the router');
my @hdr_fatal=($src =~ /autocal_dpg_read_failure\(\$state,"hdr20"([^\n]*)/g);
is(scalar(@hdr_fatal),1,'exactly one bare HDR fatal call remains (the 100% white reference)');
like($hdr_fatal[0],qr/100% white reference/,'and it is the white-reference seed read, which is never skippable');

# Both outer loops catch the skip sentinel and continue the sweep.
ok($src =~ /autocal_nearblack_skip_marker\(\$_e\)/, 'an outer loop distinguishes the skip sentinel from a fatal die');
my @markers=($src =~ /if\(!autocal_nearblack_skip_marker\(\$_e\)\)/g);
ok(scalar(@markers) >= 2, 'both the SDR and HDR outer loops re-propagate real fatal errors unchanged');

# Both handlers snapshot the anchor list as well as the curve, and treat an
# exhausted restore upload as terminal. The end-to-end tests above cover the SDR
# anchor-list restore directly; these pin the HDR half, whose single-anchor test
# mode cannot exercise a following anchor.
my @done_snapshots=($src =~ /_pre_anchor_done/g);
ok(scalar(@done_snapshots) >= 4, 'both solvers snapshot AND restore the anchor list, not just the curve');
# Pin the skip handlers' own abort, not the exit_reason string: an unrelated
# revert path already used "restore_upload_failed", so counting that would stay
# satisfied with one of these two handlers deleted.
my @restore_terminal=($src =~ /no longer matches the solver state/g);
is(scalar(@restore_terminal),2,'both solvers abort the sweep when the skip restore upload cannot be committed');


# Guard 5 is fed from BOTH solvers' read histories; an unwired history would
# pass every unit test above while the gate never saw a flat response.
my @resp_wired=($src =~ /autocal_dpg_anchor_unresponsive\(\\\@_anchor_reads\)/g);
is(scalar(@resp_wired),2,'both read-failure routers pass the anchor read history to the gate');
my @notes=($src =~ /autocal_dpg_note_anchor_read\(/g);
ok(scalar(@notes) >= 5,'valid reads are recorded at every SDR and HDR read site that follows an upload');
# The final completion goes through the outcome helper, not a bare literal.
ok($src =~ /current_name"\}="Auto Cal complete";\s*autocal_apply_completion_outcome\(\$state\);/,
 'the successful completion states the carried-forward outcome instead of a bare "Auto Cal complete"');

done_testing();
