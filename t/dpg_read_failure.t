use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
use JSON::PP ();
do "$Bin/../usr/bin/meter_lg_autocal.pl"; die $@ if $@;
local *main::write_state=sub {};
local *main::log_line=sub {};
{
 my $reads=0;
 local *main::cancelled=sub {0};
 local *main::read_step=sub {$reads++;return (undef,'Meter returned unusable all-zero reading')};
 local *main::api_json=sub {die 'Must not upload a curve after a failed measurement'};
 my $state={};my @dpg=map {($_%1024)*32} 0..3071;
 eval {main::lg_autocal_26_run_sdr_1d_dpg_greyscale_inner(
  {signal_mode=>'sdr',target_gamma=>'bt1886',target_delta_e=>0.5},$state,
  {name=>'100%',ire=>100,r=>940,g=>940,b=>940,input_max=>1023},1023,'100%',3,430,0.3127,0.329,'filmMaker',\@dpg,[],1)};
 like($@,qr/measurement failed at 100%.*all-zero/,'real SDR anchor loop preserves the failure and aborts before uploads');
 is($reads,1,'no lower anchors or endless reads after a terminal meter failure');
}
for my $signal (qw(hdr10 dv)) {
 my $reads=0;my $state={};
 local *main::cancelled=sub {0};
 local *main::read_step=sub {$reads++;return (undef,'No usable meter measurement for 5% after 4 sample attempts')};
 local *main::api_json=sub {die 'Must not upload after invalid shadow probe' if $reads;return {status=>'ok'}};
 my @dpg=map {($_%1024)*32} 0..3071;
 eval {main::lg_autocal_26_run_hdr20_dpg_greyscale({signal_mode=>$signal,target_delta_e=>0.5,
  hdr20_test_anchor_ire=>5,hdr20_test_snapshot_dpg=>\@dpg,hdr20_test_white_ref=>1000,
  steps=>[{name=>'5%',ire=>5,stimulus=>5,ddc_layout=>'hdr20',r=>431,g=>431,b=>431,input_max=>4095}]},$state,1000,0.3127,0.329,'dolbyVisionFilmMaker')};
 like($@,qr/measurement failed at 5%.*No usable meter measurement/,"$signal real solver aborts on the initial failed probe");
 is($reads,1,"$signal never starts another sample ladder after probe failure");
 is($state->{hdr20_1d_dpg_exit_reason},'read_failed',"$signal preserves the measurement cause");
}
for my $prefix (qw(sdr hdr20)) {
 for my $patch ('100%','25%') {
  my $state={readings=>[{Y=>120}],"${prefix}_1d_dpg_uploaded"=>1,"${prefix}_1d_dpg_final_de"=>0.2};
  eval { main::autocal_dpg_read_failure($state,$prefix,$patch,'Meter returned unusable all-zero reading') };
  like($@,qr/measurement failed at \Q$patch\E.*all-zero/,'original read error and patch reach top-level cleanup');
  unlike($@,qr/upload failed|committed|line \d+/,'not misreported as an upload failure or success');
  is($state->{"${prefix}_1d_dpg_exit_reason"},'read_failed','machine-readable failure phase');
  ok(!$state->{"${prefix}_1d_dpg_uploaded"},'partial curve is not reported finished');
  ok(!defined $state->{"${prefix}_1d_dpg_final_de"},'no invented final quality value');
  is_deeply($state->{readings},[{Y=>120}],'prior measured evidence retained');
 }
}
for my $response ({status=>'ok',calibration_mode=>JSON::PP::false},{status=>'error',message=>'TV unreachable'},undef,{status=>'ok'}) {
 my $state={calibration_mode=>1};
 local *main::end_calibration_mode=sub {$response};
 my $ok=main::autocal_error_calibration_cleanup($state,'filmMaker');
 my $expected=ref($response) eq 'HASH' && exists($response->{calibration_mode});
 is(!!$ok,!!$expected,'only an explicit CAL_END acknowledgement clears held mode');
 is(!!$state->{calibration_mode},!$expected,'uncertain cleanup remains visible');
 like($state->{calibration_recovery_message},qr/not confirmed/,'cleanup failure is actionable') unless $ok;
}
{
 my $state={calibration_mode=>1,calibration_end_retry_forbidden=>1};
 local *main::end_calibration_mode=sub {die 'Forbidden second CAL_END'};
 ok(!main::autocal_error_calibration_cleanup($state,'filmMaker'),'unconfirmed same-socket exit is not retried');
}
done_testing();
