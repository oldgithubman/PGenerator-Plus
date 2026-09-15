#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(
 lg_normalize_setting_value lg_record_setting_observation
 lg_setting_contracts lg_setting_values_agree lg_scoped_request_payload
);

my $root="$Bin/../usr/share/PGenerator/tv";
my $store=tempdir(CLEANUP=>1);
my $g3={
 series=>'G3',platform_model=>'HE_DTV_W23O_AFABATAA',platform_year=>2023,
 software_version=>'23.25.55',device_uuid=>'test-g3-a',device_id=>'aa:bb:cc:dd:ee:ff',
};
my %context=(
 root=>$root,store_root=>$store,category=>'picture',signal_mode=>'hdr10',
 picture_mode=>'hdrCinema',tv_input=>'hdmi1',
);
my $matrix=lg_setting_contracts($g3,%context,keys=>[qw(brightness gamma hdrDynamicToneMapping madeUpKey blackLevel)]);
is($matrix->{match_status},'exact_firmware','setting contracts use the exact G3 firmware profile');
is($matrix->{contracts}{brightness}{read_state},'inventory','firmware listing is represented as inventory evidence');
is($matrix->{contracts}{brightness}{read_decision},'probe_required','inventory alone does not claim a live read');
is($matrix->{contracts}{brightness}{write_decision},'verified_readback_required','inventory writes require TV readback');
is($matrix->{contracts}{gamma}{write_decision},'not_applicable','SDR gamma is blocked in HDR10 context');
is($matrix->{contracts}{madeUpKey}{write_decision},'preflight_and_verified_readback_required','unlisted keys require a successful preflight and readback');

my $dv=lg_setting_contracts($g3,%context,signal_mode=>'dv',keys=>['hdrDynamicToneMapping']);
is($dv->{contracts}{hdrDynamicToneMapping}{write_decision},'not_applicable','generic dynamic tone mapping is not sent in Dolby Vision');

my ($valid,$value,$error)=lg_normalize_setting_value($matrix->{contracts}{brightness},85);
ok($valid,'valid integer setting is accepted');
is($value,85,'valid integer is normalized');
($valid,$value,$error)=lg_normalize_setting_value($matrix->{contracts}{brightness},101);
ok(!$valid,'out-of-range integer is rejected');
like($error,qr/above 100/,'range error names the maximum');

my $energy=lg_setting_contracts($g3,%context,keys=>['energySaving'])->{contracts}{energySaving};
($valid,$value,$error)=lg_normalize_setting_value($energy,'minimum');
ok($valid,'documented enum alias is accepted');
is($value,'min','enum alias becomes the firmware token');

my $black=$matrix->{contracts}{blackLevel};
my $legacy={map {$_=>'auto'} qw(ntsc ntsc443 pal pal60 palm paln secam unknown)};
($valid,$value,$error)=lg_normalize_setting_value($black,'limited',$legacy);
ok($valid,'scalar range token is accepted against a legacy object readback');
is($value->{unknown},'low','active legacy range field is updated with the normalized token');
is($value->{ntsc},'auto','inactive legacy range fields are preserved');
ok(lg_setting_values_agree($black,'limited',{%$legacy,unknown=>'low'}),'scalar and legacy-map range values compare semantically');

my $record=lg_record_setting_observation($g3,{category=>'picture',signal_mode=>'hdr10',picture_mode=>'hdrCinema',tv_input=>'hdmi1'},
 'brightness','read',{status=>'supported',route=>'ssap.settings'},store_root=>$store);
ok($record->{ok},'successful live read observation is persisted');
$record=lg_record_setting_observation($g3,{category=>'picture',signal_mode=>'hdr10',picture_mode=>'hdrCinema',tv_input=>'hdmi1'},
 'brightness','verify',{status=>'verified',route=>'ssap.settings'},store_root=>$store);
ok($record->{ok},'verified live write observation is persisted');
my $observed=lg_setting_contracts($g3,%context,keys=>['brightness']);
is($observed->{contracts}{brightness}{read_decision},'allowed','an exact-context successful read promotes read access');
is($observed->{contracts}{brightness}{write_decision},'allowed','an exact-context verified write promotes write access');

my $other_mode=lg_setting_contracts($g3,%context,picture_mode=>'hdrGame',keys=>['brightness']);
is($other_mode->{contracts}{brightness}{read_decision},'probe_required','observation does not leak to another picture mode');
my $other_tv=lg_setting_contracts({%$g3,device_uuid=>'test-g3-b'},%context,keys=>['brightness']);
is($other_tv->{contracts}{brightness}{write_decision},'verified_readback_required','observation does not leak to another physical TV');

my $ddc=lg_setting_contracts($g3,%context,ddc_white_balance=>1,keys=>[qw(whiteBalanceRed whiteBalanceIre ddc_layout)])->{contracts};
($valid,$value,$error)=lg_normalize_setting_value($ddc->{whiteBalanceRed},[(0.125)x26]);
ok($valid,'fractional DDC correction arrays remain valid');
is($value->[0],0.125,'DDC correction precision is retained');
($valid,$value,$error)=lg_normalize_setting_value($ddc->{whiteBalanceIre},'2.5');
ok($valid,'fractional near-black DDC point is accepted');
my $native=lg_setting_contracts($g3,%context,keys=>['whiteBalanceRed'])->{contracts}{whiteBalanceRed};
is($native->{write}{route},'ssap.settings','native white balance does not inherit the DDC transport');
ok((lg_normalize_setting_value($native,-10))[0],'native scalar white balance is accepted');
ok(!(lg_normalize_setting_value($native,[(0.125)x22]))[0],'fractional DDC arrays cannot escape onto native transport');
my $g5=lg_setting_contracts({series=>'G5',platform_model=>'W25O',software_version=>'33.21.81'},%context,signal_mode=>'sdr',keys=>['gamma'])->{contracts}{gamma};
ok((lg_normalize_setting_value($g5,'mediumHavingLevel'))[0],'G5 exact firmware permits its catalogued gamma token');
ok(!(lg_normalize_setting_value($energy,'screenOff'))[0],'G3 rejects an enum token absent from its exact firmware catalogue');
my $power=lg_setting_contracts($g3,%context,category=>'power',keys=>['brightness'])->{contracts}{brightness};
is($power->{write_decision},'preflight_and_verified_readback_required','picture inventory cannot authorize another category');
is($power->{value_schema}{type},'unknown','picture value schema cannot leak into another category');
ok(!lg_setting_values_agree({verify=>{comparator=>'picture_mode_semantic'}},'cinema','hdrCinema'),'picture-mode comparator does not accept substring matches');
my $unconfirmed=lg_record_setting_observation($g3,{category=>'picture',signal_mode=>'hdr10',picture_mode=>'hdrGame',tv_input=>'hdmi2',context_confirmed=>0},'brightness','verify',{status=>'verified'},store_root=>$store);
is($unconfirmed->{error},'context-unconfirmed','caller-supplied but unconfirmed context cannot be promoted');
my $incomplete=lg_record_setting_observation($g3,{category=>'picture',signal_mode=>'hdr10',picture_mode=>'hdrGame'},'brightness','verify',{status=>'verified'},store_root=>$store);
is($incomplete->{error},'context-unconfirmed','missing input prevents reusable capability evidence');
my $c1ddc=lg_setting_contracts({platform_model=>'W21O',series=>'C1'},%context,ddc_white_balance=>1,keys=>['whiteBalanceRed'])->{contracts}{whiteBalanceRed};
ok(!$c1ddc->{require_readback},'reviewed readback-incapable DDC profile declares acknowledged-only transport');
ok($ddc->{whiteBalanceRed}{require_readback},'G3 DDC profile requires hardware readback even during iteration');

my $frozen={tv_input=>'hdmi2',picture_mode=>'cinema',signal_format=>'sdr',preflight_generation_profile=>{capability_profile_hash=>'a'x64}};
my $request={tv_input=>'hdmi1',settings=>{brightness=>50},automation_token=>'test-token'};
for my $path (qw(/api/lg/picture-settings /api/lg/picture-settings/set /api/lg/sdr-calman-reset /api/lg/hdr-calman-reset /api/lg/dv-calman-reset /api/lg/1d-dpg/upload /api/lg/3d-lut/upload /api/lg/hdr-tone-map/upload /api/lg/dv-profile/upload /api/lg/calibration-mode)) {
 my $scoped=lg_scoped_request_payload($path,$request,$frozen);
 is($scoped->{tv_input},'hdmi2',"$path uses frozen input");
 is($scoped->{expected_tv_input},'hdmi2',"$path guards active input");
 is($scoped->{expected_profile_hash},'a'x64,"$path guards frozen profile");
 is($scoped->{automation_token},'test-token',"$path preserves ownership token");
}
is($request->{tv_input},'hdmi1','decorator does not mutate original payload');
is(lg_scoped_request_payload('/api/meter/start',$request,$frozen),$request,'non-LG requests are unchanged');
is(lg_scoped_request_payload('/api/lg/picture-settings',undef,$frozen),undef,'bodyless requests remain bodyless');
done_testing();
