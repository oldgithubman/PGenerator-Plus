use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempfile tempdir);
use JSON::PP qw(encode_json);
use Test::More;
no warnings qw(once redefine);

# Load the two production components in separate namespaces. Neither main
# routine runs and every device/state entry point below is forbidden.
{
 package AutomationTransportRunner;
 local @ARGV=('transport-test','offline-test-token');
 do "$FindBin::Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
do "$Bin/../usr/bin/meter_lg_autocal.pl"; die $@ if $@;
local *main::api_json=sub {die "Unexpected device API call\n"};
local *main::read_step=sub {die "Unexpected meter read\n"};
local *main::write_state=sub {die "Unexpected device state write\n"};

# Execute the production ladder-construction prefix and expose its locals
# before any measurement or LUT upload. This catches wrong codes/indexes that
# equal anchor counts and synthetic readings copied from the plan cannot.
open my $source,'<',"$Bin/../usr/bin/meter_lg_autocal.pl" or die $!;
my $worker_source=do {local $/;<$source>};close $source;
my ($prefix)=$worker_source=~/(sub lg_autocal_26_run_sdr_1d_dpg_greyscale \{.*?)(?= # Sort\/reorder\. Peak first)/s;
die 'SDR worker ladder boundary not found' if !defined($prefix);
$prefix=~s/sub lg_autocal_26_run_sdr_1d_dpg_greyscale/sub test_actual_sdr_ladder/;
eval 'our $LG_AUTOCAL_SDR26_DPG_SEED_IDXES; '.$prefix.' return {steps=>\@ordered,indexes=>\@sdr26_indexes}; }';
die $@ if $@;

my @cases;
for my $signal (qw(sdr hdr10 dv)) {
 for my $transport ($signal eq 'dv' ? ([0,2,8]) : ([0,1,8],[0,2,8],[1,1,8],[2,1,8],[0,1,10],[0,2,10],[1,1,10],[2,1,10])) {
  for my $dark (0,1) {
   my ($fmt,$range,$bits)=@$transport;
   next if $fmt==2&&$bits==8; # HDMI 4:2:2 transport is 10-bit-only.
   my $name="$signal fmt=$fmt range=$range bits=$bits dark=$dark";
   my $item={signal_format=>$signal,color_format=>"$fmt",signal_range=>"$range",max_bpc=>$bits,
    target_gamma=>$signal eq 'sdr'?'2.4':'st2084',target_gamut=>$signal eq 'sdr'?'bt709':'p3d65',
    calibration=>{dark_detail=>$dark,target_gamma=>$signal eq 'sdr'?'2.4':'st2084'}};
   my $grey=AutomationTransportRunner::_grey_payload($item);
   my $series=AutomationTransportRunner::_series_payload($item,'greyscale-21','transport-test');
   my $volume=$signal eq 'dv' ? AutomationTransportRunner::_dv_payload($item)
    : AutomationTransportRunner::_three_d_payload($item,{},undef);
   for my $stage (['grey',$grey],['verification',$series],['profile',$volume]) {
    is($stage->[1]{color_format},"$fmt","$name $stage->[0] retains colour format");
    is($stage->[1]{max_bpc},$bits,"$name $stage->[0] retains transport depth");
    is($stage->[1]{transport_signal_range},"$range","$name $stage->[0] retains transport range");
   }
   is($grey->{target_gamma},$signal eq 'sdr'?'2.4':'2.2',"$name calibration target");
   is($series->{target_gamma},$signal eq 'sdr'?'2.4':'st2084',"$name verification target");
   local $main::LG_AUTOCAL_CONFIG=$grey;
   local $main::LG_AUTOCAL_DARK_DETAIL=$dark;
   local $main::LG_AUTOCAL_DDC_LAYOUT=$signal eq 'sdr'?'sdr26':'hdr20';
   if($signal eq 'sdr') {
    my $peak=$range==1&&$fmt!=0?109:100;
    my $state={};
    my $message;
    local *main::log_line=sub {
     return if $_[0]!~/^SDR26 1D DPG greyscale: range=/;
     $message=$_[0];die "STOP_BEFORE_IO\n";
    };
    eval {main::lg_autocal_26_run_sdr_1d_dpg_greyscale($grey,$state,417.8,.3127,.329,'cinema')};
    is($@,"STOP_BEFORE_IO\n","$name executes production ladder selection without device I/O");
    is($state->{sdr_1d_dpg_peak_ire},$peak,"$name worker peak matches the planned transport");
    my $anchors=grep {$_->{ire}>0&&!$_->{autocal_reference_only}} @{$grey->{steps}};
    like($message,qr/anchors=$anchors bits=$bits /,"$name worker and planned ladder have identical anchor counts");
    is(main::autocal_sdr_signal_peak($grey),$peak,"$name target normalisation agrees");
    my $actual;
    { local *main::log_line=sub {}; $actual=main::test_actual_sdr_ladder($grey,{},417.8,.3127,.329,'cinema'); }
    my %planned=map {$_->{ire}=>$_} @{$grey->{steps}};
    my @codes;
    for my $index (0..$#{$actual->{steps}}) {
     my $step=$actual->{steps}[$index];
     my $plan=$planned{$step->{ire}};
     ok($plan,"$name actual $step->{ire}% anchor is in the plan");
     if($bits==8) {
      is($step->{r},$plan->{r},"$name $step->{ire}% actual emitted code matches planned code");
     } else {
      cmp_ok(abs($step->{r}-$plan->{r})/$plan->{input_max},'<=',.004,
       "$name $step->{ire}% empirical 10-bit code is within chart matching tolerance");
     }
     is($step->{input_max},$plan->{input_max},"$name $step->{ire}% code domain");
     if($bits==8&&$fmt==0&&$range==1) {
      my $limited10=64+($step->{r}-16)*4;
      is($actual->{indexes}[$index],main::lg_autocal_sdr26_dpg_sample_index_for_limited_code($limited10,1023),
       "$name $step->{ire}% 8-bit legal code maps to the correct 10-bit LUT index");
     }
     push @codes,$step->{r};
    }
    if($fmt!=0) {
     my %top=map {$_->{ire}=>$_->{r}} @{$actual->{steps}};
     cmp_ok($top{105},'<',$top{109},"$name headroom anchors remain distinct");
    }
   } else {
    my @ascending=sort {$a->{ire}<=>$b->{ire}} @{$grey->{steps}};
    for my $i (1..$#ascending) {
     cmp_ok($ascending[$i]{r},'>',$ascending[$i-1]{r},"$name code increases at $ascending[$i]{ire}%");
    }
    my $black=$signal eq 'dv'?256:$range==1?($bits==8?16:64):0;
    my $white=$signal eq 'dv'?3760:$range==1?($bits==8?235:940):($bits==8?255:1023);
    is($ascending[0]{r},$black,"$name correct legal/full black code");
    is($ascending[-1]{r},$white,"$name correct legal/full white code");
    my @ordered=main::order_autocal_steps($grey->{steps},$grey);
    my %actual=map {0+$_->{ire}=>1} @ordered;
    my @expected=sort {$a<=>$b} map {0+$_->{ire}} grep {$_->{ire}>0} @{$grey->{steps}};
    is_deeply([sort {$a<=>$b} keys %actual],\@expected,"$name worker preserves every configured HDR/DV anchor");
    ok($actual{100},"$name includes measured peak white");
    if($signal eq 'dv') {
     is($grey->{dv_map_mode},'2',"$name greyscale uses Relative");
     is($volume->{dv_map_mode},'2',"$name profile uses Relative");
     is($series->{dv_map_mode},'1',"$name verification uses Absolute");
     my ($white)=grep {$_->{ire}==100} @{$grey->{steps}};
     is_deeply([@$white{qw(r input_max)}],[3760,4095],"$name preserves 12-bit legal source inside the 8-bit Full tunnel");
    }
   }
   # Real worker snapshots carry solver context, not a browser_chart context.
   $grey->{calibration_target_context}={%{main::autocal_target_context_for($grey->{target_gamma},$signal)}};
   push @cases,{name=>$name,item=>$item,grey=>$grey,series=>$series};
  }
 }
}

# Pass the actual runner payloads into the browser-function regressions.
my ($fh,$file)=tempfile(UNLINK=>1);
print $fh encode_json(\@cases);close $fh;
my $dir=tempdir(CLEANUP=>1);
my $profile=AutomationTransportRunner::_dv_payload({signal_format=>'dv',color_format=>'0',signal_range=>'2',max_bpc=>8});
$profile->{fixture_mode}=JSON::PP::true;
$profile->{fixture_white_y}=500;
open my $config,'>',"$dir/config.json" or die $!;print $config encode_json($profile);close $config;
is(system($^X,"$Bin/../usr/bin/meter_lg_dv_profile.pl","$dir/config.json","$dir/state.json","$dir/stop"),0,
 'real DV profile worker completes fixture mode without device I/O');
open my $state,'<',"$dir/state.json" or die $!;my $dv=JSON::PP::decode_json(do {local $/;<$state>});close $state;
is($dv->{full_autocal_run_id},'transport-test','raw DV profile state retains automation ownership');
is(scalar @{$dv->{steps}},5,'real profile result has five xyY step measurements');
is($dv->{target_gamma},'2.2','raw profile state retains native calibration target');
is($dv->{dv_map_mode},'2','raw profile state retains Relative map mode');
is($dv->{max_bpc},8,'raw profile state retains tunnel depth');
my $output=`node "$Bin/js/automation_transport.js" "$file" "$dir/state.json" 2>&1`;
is($?,0,'production chart transport and coverage checks pass') or diag $output;
like($output,qr/PASS automation transport/,'all transport cases reached the renderer');
done_testing();
