#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $worker="$Bin/../usr/bin/meter_lg_3d_autocal.pl";
my $loaded=do $worker;
ok(defined($loaded),'3D AutoCal worker loads') or BAIL_OUT($@);

is(main::lg_payload_grid_for_config({
 preflight_lg_generation=>{platform_model=>'HE_DTV_W20H_AFABATAA',platform_year=>2020,series=>'BX'},
}),17,'AutoCal selects 17-point payloads for W20H');
is(main::lg_payload_grid_for_config({
 preflight_lg_generation=>{platform_model=>'HE_DTV_W23O_AFABATAA',platform_year=>2023,series=>'G3'},
}),33,'AutoCal selects 33-point payloads for W23O');
is(main::lg_payload_grid_for_config({
 preflight_lg_generation=>{platform_model=>'HE_DTV_W26G_AFABATAA',platform_year=>2026,series=>'G6'},
}),33,'AutoCal selects 33-point payloads for W26G');
is(main::lg_payload_grid_for_config({
 preflight_lg_generation=>{platform_model=>'HE_DTV_W99Q_UNKNOWN'},
}),0,'AutoCal refuses unknown platform geometry');
is(main::lg_payload_grid_for_config({
 preflight_lg_generation=>{series=>'G3',platform_year=>2023},
}),0,'AutoCal refuses retail-model-only geometry');
is(main::lg_payload_grid_for_config({fixture_mode=>1}),33,'legacy maths fixtures retain an explicit non-TV default');
is(main::lg_payload_grid_for_config({fixture_mode=>1,payload_lut_size=>17}),17,'fixtures can exercise 17-point geometry');
is(main::lg_3d_grid_from_value_count(17**3*3),17,'17-point value count is recognized');
is(main::lg_3d_grid_from_value_count(33**3*3),33,'33-point value count is recognized');
is(main::lg_3d_grid_from_value_count(123),0,'invalid value count is rejected');
my $generation={platform_model=>'W23O',series=>'G3',platform_year=>2023};
my $resolved=main::resolve_lg_capabilities($generation);
is(main::lg_payload_grid_for_config({preflight_lg_generation=>$generation,preflight_generation_profile=>{capability_profile_hash=>$resolved->{capability_profile_hash}}}),33,'frozen profile and generation agree on payload geometry');
is(main::lg_payload_grid_for_config({preflight_lg_generation=>$generation,preflight_generation_profile=>{capability_profile_hash=>'stale'}}),0,'stale frozen profile cannot authorize payload generation');
is(main::lg_payload_grid_for_config({preflight_generation_profile=>{lut_grid=>33,capability_profile_hash=>$resolved->{capability_profile_hash}}}),0,'profile without TV identity cannot authorize payload generation');

done_testing();
