use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(resolve_lg_capabilities lg_setting_contracts lg_best_settings_plan lg_setting_write_accepted lg_readback_unavailable_reason);

open my $fh,'<',"$Bin/fixtures/lg-capabilities/c1-run-2026-09-15.json" or die $!;
my $fixture=JSON::PP::decode_json(do {local $/;<$fh>});close $fh;
my $identity={model_name=>$fixture->{model_name},platform_model=>'HE_DTV_W21O_TEST',device_uuid=>'fixture-only'};
my %context=(root=>"$Bin/../usr/share/PGenerator/tv",store_root=>tempdir(CLEANUP=>1),
 category=>'picture',signal_mode=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi1');
my $profile=resolve_lg_capabilities($identity,root=>$context{root});
is($profile->{identity}{retail_series},'C1','retail family is extracted from full model name');
is($profile->{data}{identity}{compatibility_name},'LG C1 (2021)','known model description comes from the matrix');
ok($profile->{platform_profile_applied},'independently supplied internal platform admits the fixture');
my $regional=resolve_lg_capabilities({%$identity,model_name=>'OLED55C16LA'},root=>$context{root});
is_deeply($regional->{data},$profile->{data},'regional C1 variants use the same matrix policy');

my %requested=(backlight=>50,brightness=>50,color=>50,contrast=>85,energySaving=>'off',
 blackLevel=>'low',colorGamut=>'auto',dynamicColor=>'off',dynamicContrast=>'off',gamma=>'bt1886',
 mpegNoiseReduction=>'off',noiseReduction=>'off',peakBrightness=>'off',realCinema=>'on',sharpness=>0,
 smoothGradation=>'off',superResolution=>'off',tint=>0);
my $response={status=>'ok',current_input=>'hdmi1',virtual_picture_settings=>1,
 picture_settings=>{map {$_=>$requested{$_}} @{$fixture->{reported_working_keys}}},
 supported_picture_keys=>$fixture->{reported_working_keys},
 unsupported_picture_keys=>{map {$_=>$fixture->{refusal}} @{$fixture->{refused_read_keys}}}};
my $plan=lg_best_settings_plan($identity,\%requested,$response,%context);
ok($plan->{active},'reviewed legacy platform activates shared best-available policy');
is_deeply([sort keys %{$plan->{automatic}}],[sort @{$fixture->{reported_working_keys}}],'reported five native keys remain automatic');
is_deeply([sort keys %{$plan->{manual}}],[sort @{$fixture->{refused_read_keys}}],'all thirteen refused reads become explicit manual settings');
is_deeply($plan->{blocked},{},'all fixture recipe values have applicable contracts');
is($plan->{manual}{tint}{value},0,'zero-valued manual settings are preserved');
like($plan->{manual}{gamma}{message},qr/gamma to bt1886.*filmMaker.*sdr.*hdmi1/,'manual instruction includes exact value and context');
is(scalar keys %requested,18,'planning does not remove requested values from audit source');

my $contracts=lg_setting_contracts($identity,%context,keys=>[keys %requested])->{contracts};
ok($contracts->{brightness}{allow_unverified_readback},'matrix explicitly permits native brightness acknowledgement');
ok($contracts->{brightness}{require_readback},'even a write-only candidate must attempt post-write readback');
ok(!$contracts->{gamma}{allow_unverified_readback},'other controls do not inherit the waiver');
for my $case (['sdr','filmMaker'],['hdr10','hdrFilmMaker'],['dv','dolbyVisionFilmMaker']) {
 my ($signal,$mode)=@$case;
 my $keys=[qw(backlight brightness color contrast energySaving noiseReduction)];
 my $c=lg_setting_contracts($identity,%context,signal_mode=>$signal,picture_mode=>$mode,keys=>$keys)->{contracts};
 for my $key(qw(backlight brightness color contrast energySaving)) {
  ok($c->{$key}{allow_unverified_readback},"C1 $signal $key uses the reported native-write allowance");
  ok($c->{$key}{require_readback},"C1 $signal $key still attempts readback");
 }
 ok(!$c->{noiseReduction}{allow_unverified_readback},"$signal does not extend the allowance to a sixth control");
 my $requested={brightness=>50,noiseReduction=>'off'};
 my $r={%$response,picture_settings=>{},supported_picture_keys=>[],unsupported_picture_keys=>{brightness=>$fixture->{refusal},noiseReduction=>$fixture->{refusal}}};
 my $p=lg_best_settings_plan($identity,$requested,$r,%context,signal_mode=>$signal,picture_mode=>$mode);
 ok(exists($p->{automatic}{brightness})&&exists($p->{manual}{noiseReduction}),"$signal keeps native-write candidate automatic and unreadable extra control manual");
 my $ack={status=>'ok',verification_state=>'acknowledged_unverified',setting_contracts=>$c,setting_verification=>{brightness=>{status=>'acknowledged_unverified',expected=>50}}};
 ok(lg_setting_write_accepted($ack,'brightness',50),"$signal accepts an explicitly acknowledged, unverified native write");
 ok(!lg_setting_write_accepted({%$ack,status=>'error'},'brightness',50),"$signal never waives write refusal");
 ok(!lg_setting_write_accepted({%$ack,picture_settings=>{brightness=>49}},'brightness',50),"$signal never waives observed mismatch");
}
ok(!lg_setting_contracts($identity,%context,signal_mode=>'hlg',keys=>['brightness'])->{contracts}{brightness}{allow_unverified_readback},'report does not authorize unverified HLG writes');
my $denied={%$response,picture_settings=>{},supported_picture_keys=>[],unsupported_picture_keys=>{brightness=>$fixture->{refusal}}};
$plan=lg_best_settings_plan($identity,{brightness=>50},$denied,%context);
ok($plan->{unavailable}{brightness} && exists($plan->{automatic}{brightness}),'known write candidate remains automatic after an explicit read refusal');
for my $reason ('TV read timed out','Socket disconnected','Permission denied: setting unavailable','Unauthorized','Forbidden','Unknown failure','Service unavailable','401: keys not allowed') {
 ok(!lg_readback_unavailable_reason($reason),"$reason cannot authorize best-effort readback");
 my $p=lg_best_settings_plan($identity,{gamma=>'bt1886'},{%$denied,unsupported_picture_keys=>{gamma=>$reason}},%context);
 is_deeply($p->{manual},{},'transport/auth/ambiguous errors do not become manual capabilities');
}
my $invalid=lg_best_settings_plan($identity,{brightness=>101},$denied,%context);
ok($invalid->{blocked}{brightness},'invalid value cannot be waived');
my $inapplicable=lg_best_settings_plan($identity,{gamma=>'bt1886'},$response,%context,signal_mode=>'hdr10');
ok($inapplicable->{blocked}{gamma},'signal-inapplicable control cannot become manual success');
for my $case (
 ['retail name only',{model_name=>'OLED65C1PUB'}],
 ['conflicting modern platform',{%$identity,platform_model=>'W23O'}],
 ['unknown platform',{%$identity,platform_model=>'W99Q'}],
 ['G3',{model_name=>'OLED55G36LA',platform_model=>'W23O',software_version=>'23.25.55'}],
) {
 my $p=lg_best_settings_plan($case->[1],\%requested,$response,%context);
 ok(!$p->{active},"$case->[0] cannot inherit legacy policy");
 my $c=lg_setting_contracts($case->[1],%context,keys=>['brightness'])->{contracts}{brightness};
 ok(!$c->{allow_unverified_readback},"$case->[0] retains strict native readback");
}
my $cx=lg_best_settings_plan({model_name=>'OLED55CX6LA',platform_model=>'W20O'},{gamma=>'bt1886'},$response,%context);
ok($cx->{manual}{gamma},'another reviewed legacy family uses the identical manual policy');
ok(!lg_best_settings_plan($identity,\%requested,{%$response,current_input=>'hdmi2'},%context)->{active},'changed input blocks policy');
ok(!lg_best_settings_plan($identity,\%requested,{status=>'error'},%context)->{active},'failed request blocks policy');

my $ack={status=>'ok',verification_state=>'acknowledged_unverified',
 setting_verification=>{brightness=>{status=>'acknowledged_unverified',expected=>50}},
 setting_contracts=>{brightness=>$contracts->{brightness}}};
ok(lg_setting_write_accepted($ack,'brightness',50),'per-key acknowledgement plus matrix permission is accepted as unverified');
ok(!lg_setting_write_accepted({%$ack,status=>'error'},'brightness',50),'write error always fails');
ok(!lg_setting_write_accepted({%$ack,setting_contracts=>{}},'brightness',50),'acknowledgement cannot waive an absent contract');
ok(!lg_setting_write_accepted({%$ack,setting_verification=>{brightness=>{status=>'mismatch'}}},'brightness',50),'actual mismatch always fails');
ok(!lg_setting_write_accepted({%$ack,setting_contracts=>{brightness=>{%{$contracts->{brightness}},write_decision=>'blocked'}}},'brightness',50),'explicit matrix write block wins');
ok(!lg_setting_write_accepted($ack,'brightness',51),'acknowledgement for another requested value is rejected');
ok(!lg_setting_write_accepted({%$ack,picture_settings=>{brightness=>49}},'brightness',50),'aggregate acknowledgement cannot conceal actual mismatch');
ok(!lg_setting_write_accepted({%$ack,setting_verification=>{brightness=>{status=>'verified',expected=>50}}},'brightness',50),'verified label without observed value is not sufficient');
my $wrong_mode=lg_best_settings_plan($identity,\%requested,{%$response,picture_settings=>{%{$response->{picture_settings}},pictureMode=>'cinema'},supported_picture_keys=>[@{$response->{supported_picture_keys}},'pictureMode']},%context);
ok(!$wrong_mode->{active} && $wrong_mode->{context_error},'real mismatched picture mode cannot activate best-available settings');
my $alias_mode=lg_best_settings_plan($identity,{brightness=>50},{%$response,picture_settings=>{brightness=>50,pictureMode=>'dolbyHdrCinemaBright'},supported_picture_keys=>['brightness','pictureMode']},%context,signal_mode=>'dv',picture_mode=>'dolbyVisionCinemaBright');
ok($alias_mode->{active} && !$alias_mode->{context_error},'shared policy accepts equivalent UI/wire picture-mode aliases without confusing signals');
done_testing();
