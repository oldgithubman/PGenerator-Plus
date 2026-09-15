use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
do "$Bin/../usr/bin/meter_lg_autocal.pl"; die $@ if $@;
local *main::write_state=sub {};
local *main::log_line=sub {};
local *main::cancelled=sub {1};
my @writes;
my $response={status=>'ok',picture_settings=>{contrast=>85,brightness=>50}};
local *main::api_json=sub {push @writes,$_[2];return $response};
my $state={};
is(main::restore_factory_levels_for_autocal({signal_mode=>'sdr',factory_contrast=>'85.0'},$state),undef,'reviewed SDR levels accept equivalent numeric overrides');
is_deeply($writes[0]{settings},{contrast=>85,brightness=>50},'manual AutoCal derives factory levels from reviewed recipe');
is($writes[0]{signal_mode},'sdr','factory write carries the signal context');
ok($state->{calibration_settings_recipe},'recipe identity is retained in worker state');
@writes=();
like(main::restore_factory_levels_for_autocal({signal_mode=>'sdr',factory_contrast=>100},{}),qr/conflicts with.*recipe/,'conflicting factory override is rejected');
is(scalar @writes,0,'recipe conflict is blocked before TV write');
$response={status=>'ok',picture_settings=>{}};
like(main::restore_factory_levels_for_autocal({signal_mode=>'sdr'},{}),qr/contrast unavailable and brightness unavailable/,'missing readback cannot be fabricated from requested values');
$response={status=>'ok',verification_state=>'acknowledged_unverified',picture_settings=>{},
 setting_verification=>{contrast=>{status=>'acknowledged_unverified',expected=>85},brightness=>{status=>'acknowledged_unverified',expected=>50}},
 setting_contracts=>{map {$_=>{allow_unverified_readback=>1,require_readback=>1,write_decision=>'readback_preferred'}} qw(contrast brightness)}};
my $legacy_state={};
is(main::restore_factory_levels_for_autocal({signal_mode=>'sdr'},$legacy_state),undef,'worker accepts matrix-authorized write-only defaults');
is($legacy_state->{factory_levels_verification_state},'acknowledged_unverified','worker never claims factory defaults were verified');
like($legacy_state->{factory_levels_warning},qr/unverified/,'worker exposes the readback limitation');
$response->{picture_settings}{contrast}=84;
like(main::restore_factory_levels_for_autocal({signal_mode=>'sdr'},{}),qr/contrast 84/,'matrix waiver cannot suppress actual factory-level mismatch');
{
 local $main::LG_AUTOCAL_CONFIG={signal_mode=>'hdr10',tv_input=>'hdmi2'};
 local *main::lg_clients=sub {{ip=>'test',client_key=>'test-key'}};
 my @requests;
 local *main::lg_helper_json=sub {push @requests,$_[0];return {status=>'ok'}};
 main::lg_helper_picture_set({whiteBalanceMethod=>'22'},'hdrCinema',1,1,1);
 main::lg_helper_picture_get(['whiteBalanceMethod'],'hdrCinema');
 for my $request (@requests) {
  is($request->{signal_mode},'hdr10','direct helper preserves calibration signal');
  is($request->{tv_input},'hdmi2','direct helper preserves HDMI scope');
  is($request->{category},'picture','direct helper specifies settings category');
 }
}
done_testing();
