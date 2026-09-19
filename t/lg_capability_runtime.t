#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use File::Temp qw(tempfile tempdir);
use FindBin qw($Bin);
use Test::More;

my $helper="$Bin/../usr/sbin/pgenerator-lg";
my $loaded=do $helper;
ok(defined($loaded),'LG helper loads with capability resolver') or diag($@);

my $g3=main::lg_generation_info(
 { modelName=>'OLED55G36LA' },
 { model_name=>'HE_DTV_W23O_AFABATAA', product_name=>'webOSTV 23', software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff' },
 { deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'runtime-g3' },
);
is($g3->{series},'G3','retail G3 series is parsed');
is($g3->{software_version},'23.25.55','full firmware version enters the compatibility signature');
is($g3->{device_uuid},'runtime-g3','stable physical TV UUID enters the compatibility signature');
my $g3_profile=main::lg_generation_profile($g3);
{
 no warnings 'redefine';
 local *main::lg_current_input_info=sub {{current_input=>'hdmi2'}};
 is(main::lg_connected_context_error({},$g3,1,'hdmi2',$g3_profile->{capability_profile_hash}),undef,'same connected input and profile admit request');
 is(main::lg_connected_context_error({},$g3,1,'hdmi1',$g3_profile->{capability_profile_hash})->{error_code},'lg-input-context-changed','different active input blocks before workflow writes');
 is(main::lg_connected_context_error({},$g3,1,'hdmi2','b'x64)->{error_code},'lg-capability-context-changed','different frozen profile blocks before workflow writes');
 local *main::lg_current_input_info=sub {{}};
 is(main::lg_connected_context_error({},$g3,1,'hdmi2','')->{error_code},'lg-input-context-changed','unreadable active input blocks scoped request');
 is(main::lg_connected_context_error({},$g3,1,'',''),undef,'unscoped cleanup does not require current input');
}
is($g3_profile->{lut_grid},33,'G3 runtime profile uses W23O 33-point geometry');
is($g3_profile->{capability_match_status},'series','G3 runtime profile includes the series match');
like($g3_profile->{capability_profile_hash},qr/^[0-9a-f]{64}$/,'runtime profile includes deterministic hash');
is(scalar(@{$g3_profile->{settings_capabilities}{public_routes}{read}{picture_keys}}),61,'runtime exposes exact-firmware settings matrix');

my $b4=main::lg_generation_info(
 { modelName=>'OLED55B46LA' },
 { model_name=>'HE_DTV_W24H_AFABATAA', product_name=>'webOSTV 24', software_version=>'23.20.01' },
 { deviceOSReleaseVersion=>'9.0.0' },
);
is(main::lg_3d_lut_size_for_generation($b4),17,'H-platform runtime resolves a 17-point payload');

my $c6_2026=main::lg_generation_info(
 { modelName=>'OLED55C66LA' },
 { model_name=>'HE_DTV_W26O_AFABATAA', product_name=>'webOSTV 26', software_version=>'43.11.77' },
 { deviceOSReleaseVersion=>'11.1.0' },
);
is($c6_2026->{series},'C6','2026 C6 retail series is parsed');
is($c6_2026->{platform_year},2026,'W26 platform disambiguates the 2026 generation');
is(main::lg_3d_lut_size_for_generation($c6_2026),33,'2026 W26O runtime resolves a 33-point payload');

my $unknown={generation_id=>'lg_unknown',platform_model=>'HE_DTV_W99Q_UNKNOWN'};
is(main::lg_3d_lut_size_for_generation($unknown),0,'unknown runtime geometry fails closed');
is(main::lg_3d_lut_size_for_generation({series=>'G3',platform_year=>2023}),0,'retail series alone cannot authorize a TV payload');
for my $feature (qw(session one_d_lut dolby_vision_configuration hdr_tonemap)) {
 ok(main::lg_calibration_profile_allows($g3,$feature),"reviewed G3 platform permits $feature");
 ok(!main::lg_calibration_profile_allows($unknown,$feature),"unknown platform cannot authorize $feature");
}
ok(!main::lg_generation_profile($unknown)->{readback_supported},'unknown profile cannot advertise calibration readback support');

my ($fh17,$path17)=tempfile();
binmode($fh17);
print {$fh17} pack('v*',(0) x (17**3*3));
close($fh17);
my $lut17=main::lg_read_3d_lut_file($path17);
is(ref($lut17),'ARRAY','17-point binary payload is accepted by the reader');
is(scalar(@{$lut17}),17**3*3,'17-point payload value count is retained');

my ($fh_bad,$path_bad)=tempfile();
binmode($fh_bad);
print {$fh_bad} pack('v*',(0) x 12);
close($fh_bad);
ok(!defined(main::lg_read_3d_lut_file($path_bad)),'non-matrix payload size is rejected');

my ($put_ok,$put_message);
{
 no warnings 'redefine';
 local *main::lg_calibration_request=sub {{type=>'response',payload=>{returnValue=>1}}};
 local *main::response_is_app_failure=sub { return (0,''); };
 ($put_ok,$put_message)=main::lg_3d_lut_put({},'test',{upload=>'BT709_3D_LUT_DATA'},$lut17,'cinema',1);
}
ok($put_ok,'17-point payload reaches the calibrated write route');
is($put_message,'','valid 17-point payload has no validation error');
my ($bad_ok,$bad_message)=main::lg_3d_lut_put({},'test',{upload=>'BT709_3D_LUT_DATA'},[0,1,2],'cinema',1);
ok(!$bad_ok,'invalid payload is rejected before transport');
like($bad_message,qr/17x17x17 or 33x33x33/,'validation names both supported geometries');

my $observation_store=tempdir(CLEANUP=>1);
{
 local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$observation_store;
 no warnings 'redefine';
 local *main::lg_authenticated_session=sub {{
  status=>'ok',session=>{},client_key=>'test-key',
  system_info=>{modelName=>'OLED55G36LA'},
  software_info=>{model_name=>'HE_DTV_W23O_AFABATAA',product_name=>'webOSTV 23',software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff'},
  hello_info=>{deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'runtime-g3'},
 }};
 local *main::websocket_close=sub {};
 my @requests;
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  return {type=>'response',payload=>{settings=>{brightness=>50}}}
   if($label eq 'get_picture_settings');
  return {type=>'response',payload=>{settings=>{contrast=>85}}}
   if($label eq 'get_picture_setting_contrast');
  return {type=>'response',payload=>{settings=>{}}};
 };
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[qw(brightness contrast)],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','matrix-aware picture read succeeds with partial grouped response');
 is($read->{picture_settings}{contrast},85,'a key omitted from a successful grouped response is retried individually');
 ok(grep(($_->{label}||'') eq 'get_picture_setting_contrast',@requests),'individual omission retry reached the transport');
 my ($scoped_request)=grep {$_->{label} eq 'get_picture_settings'} @requests;
 is_deeply($scoped_request->{payload}{dimension},{pictureMode=>'hdrCinema',input=>'hdmi1',_3dStatus=>'2d'},'native matrix reads carry the requested mode/input dimension');
 ok(!$read->{settings_matrix}{context_confirmed},'caller-supplied context alone is not confirmed observation evidence');
 is($read->{setting_contracts}{brightness}{write_decision},'verified_readback_required','read response exposes the resolved write contract');
 local *main::lg_current_input_info=sub {{current_input=>'hdmi1',current_input_checked=>1}};
 my $actual_mode='hdrCinema';
 local *main::lg_current_picture_mode=sub {$actual_mode};
 my $confirmed=main::lg_picture_get_workflow('127.0.0.1','test-key',1,['brightness'],'hdrCinema','hdmi1',0,'hdr10',1,'picture');
 ok($confirmed->{settings_matrix}{context_confirmed},'independently matching input and mode establish observation scope');
 $actual_mode='hdrGame';
 my $wrong_mode=main::lg_picture_get_workflow('127.0.0.1','test-key',1,['brightness'],'hdrCinema','hdmi1',0,'hdr10',1,'picture');
 # The G3 answers every read from the active mode whatever dimension is sent
# (18 September 2026 sweep), so a read requested for another mode is taken
# and labelled as the active mode rather than filed under the requested one.
is($wrong_mode->{requested_picture_mode_not_active},'hdrCinema','read for a non-active mode is flagged');
is(lc($wrong_mode->{settings_matrix}{context}{picture_mode}),'hdrgame','values are attributed to the mode the TV is in');
ok(!grep({ ($_->{settings_matrix}{context}{picture_mode}||'') eq 'hdrCinema' && $_->{settings_matrix}{context_confirmed} } $wrong_mode),'active-mode mismatch never promotes the requested mode');
}

{
 local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$observation_store;
 no warnings 'redefine';
 local *main::lg_authenticated_session=sub {{
  status=>'ok',session=>{},client_key=>'test-key',
  system_info=>{modelName=>'OLED55G36LA'},
  software_info=>{model_name=>'HE_DTV_W23O_AFABATAA',product_name=>'webOSTV 23',software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff'},
  hello_info=>{deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'runtime-g3'},
 }};
 local *main::websocket_close=sub {};
 my $transport_calls=0;
 local *main::lg_request=sub { $transport_calls++; return {type=>'response',payload=>{returnValue=>1,settings=>{}}}; };
 my $invalid=main::lg_picture_set_workflow('127.0.0.1','test-key',1,{brightness=>101},[],'hdmi1',0,'hdrCinema',0,0,0,0,'hdr10','picture');
 is($invalid->{error_code},'invalid-setting-value','out-of-range write is rejected by the TV contract');
 is($transport_calls,0,'invalid value is rejected before a settings transport call');
 # The G3's API accepts tone mapping in Dolby Vision, so prove the signal
 # block on a C2, which keeps the common scoping.
 local *main::lg_authenticated_session=sub {{
  status=>'ok',session=>{},client_key=>'test-key',
  system_info=>{modelName=>'OLED65C26LA'},
  software_info=>{model_name=>'HE_DTV_W22O_AFABATAA',product_name=>'webOSTV 22',software_version=>'13.30.60',device_id=>'aa:bb:cc:dd:ee:02'},
  hello_info=>{deviceOSReleaseVersion=>'7.3.1',deviceUUID=>'runtime-c2'},
 }};
 my $inapplicable=main::lg_picture_set_workflow('127.0.0.1','test-key',1,{hdrDynamicToneMapping=>'off'},[],'hdmi1',0,'dolbyVisionCinemaBright',0,0,0,0,'dv','picture');
 is($inapplicable->{error_code},'setting-not-applicable','Dolby Vision tone-mapping write is blocked by signal applicability');
 is($transport_calls,0,'inapplicable write is rejected before a settings transport call');
}

{
 local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$observation_store;
 no warnings 'redefine';
 local *main::lg_authenticated_session=sub {{
  status=>'ok',session=>{},client_key=>'test-key',
  system_info=>{modelName=>'OLED55G36LA'},
  software_info=>{model_name=>'HE_DTV_W23O_AFABATAA',product_name=>'webOSTV 23',software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff'},
  hello_info=>{deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'runtime-g3'},
 }};
 local *main::websocket_close=sub {};
 local *main::lg_request=sub {
  my ($session,$label,$path)=@_;
  return {type=>'response',payload=>{returnValue=>1}} if($path eq 'settings/setSystemSettings');
  return {type=>'response',payload=>{settings=>{}}};
 };
 my $unverified=main::lg_picture_set_workflow('127.0.0.1','test-key',1,{brightness=>50},[],'hdmi1',0,'hdrCinema',0,0,0,0,'hdr10','picture');
 is($unverified->{status},'error','acknowledged write without TV readback is not reported as success');
 is($unverified->{error_code},'setting-readback-unavailable','missing post-write value has an explicit verification error');
 ok(!exists($unverified->{picture_settings}{brightness}),'requested value is never synthesized as TV readback');
 my @writes;
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  if($path eq 'settings/setSystemSettings') {
   push @writes,$payload->{settings};
   return {type=>'response',payload=>{returnValue=>1}};
  }
  return {type=>'response',payload=>{returnValue=>1,settings=>{brightness=>'50',contrast=>'100'}}};
 };
 my $verified=main::lg_picture_set_workflow('127.0.0.1','test-key',1,{brightness=>50,contrast=>100},[],'hdmi1',0,'hdrCinema',0,0,1,0,'hdr10','picture');
 is($verified->{status},'ok','multi-setting native write succeeds with matching numeric-string readbacks');
 is($verified->{verification_state},'verified','skip_readback cannot suppress contract-required verification');
 is_deeply([sort map {keys %$_} @writes],[qw(brightness contrast)],'generic settings are each written through the verified single-key path');
 is($verified->{setting_verification}{contrast}{status},'verified','batch retains per-setting evidence');
 my $verify_requested;
 local *main::lg_ddc_1d_white_balance_set=sub {$verify_requested=$_[8];return (1,{status=>'ok',ddc_upload_verified=>1,ddc_upload_verify_contract=>'write-accepted-readback-untrusted',picture_settings=>{}})};
 my $ddc_result=main::lg_picture_set_workflow('127.0.0.1','test-key',1,{whiteBalanceMethod=>'22',whiteBalanceIre=>100,whiteBalanceRed=>[(0)x22],whiteBalanceGreen=>[(0)x22],whiteBalanceBlue=>[(0)x22]},[],'hdmi1',1,'hdrCinema',1,0,0,1,'hdr10','picture');
 ok($verify_requested,'DDC contract forces verification despite caller not requesting it');
 is($ddc_result->{error_code},'ddc-readback-unverified','untrusted DDC readback cannot masquerade as a verified upload');
}

{
 no warnings 'redefine';
 my @categories;
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push @categories,$payload->{category};
  return {type=>'response',payload=>{returnValue=>1,settings=>{autoPowerOff=>'off'}}};
 };
 my $read=main::lg_picture_readback_settings({},'power-read',['autoPowerOff'],'hdrCinema','hdmi1','hdr10',1,'power');
 is($read->{autoPowerOff},'off','hazard readback uses its own category');
 is_deeply(\@categories,['power'],'power setting verification never falls back to picture');
}
{
 no warnings 'redefine';
 my $calls=0;
 local *main::lg_request=sub {
  $calls++;
  return {type=>'response',payload=>{returnValue=>1,settings=>{brightness=>50}}} if $calls==1;
  return {type=>'response',payload=>{returnValue=>1,settings=>{brightness=>99,contrast=>85}}};
 };
 my $read=main::lg_picture_readback_settings({},'partial-read',[qw(brightness contrast)],'hdrCinema','hdmi1','hdr10',1);
 is($read->{brightness},50,'a later fallback cannot overwrite the first scoped value');
 is($read->{contrast},85,'a partial grouped read still fills in omitted keys');
}
{
 no warnings 'redefine';
 my @scopes;
 local *main::lg_request=sub {push @scopes,$_[3];return {type=>'response',payload=>{settings=>{}}}};
 main::lg_picture_readback_settings({},'write-read',['brightness'],'hdrCinema','hdmi1','hdr10',1,'picture',{category=>'picture',dimension=>{pictureMode=>'hdrCinema',input=>'hdmi1'}});
 ok(!grep(($_->{category}||'') ne 'picture' || ($_->{dimension}{input}||'') ne 'hdmi1',@scopes),'post-write verification never searches a different scope');
 # A G5 on its catalogued firmware keeps the common SDR-only gamma scoping.
 my $g5=main::lg_generation_info({modelName=>'OLED83G54LW'},{model_name=>'HE_DTV_W25G_AFABATAA',product_name=>'webOSTV 25',software_version=>'33.21.81'},{deviceOSReleaseVersion=>'10.2.0'});
 my ($keys)=main::lg_picture_reset_contract_keys($g5,[qw(brightness gamma madeUpKey)],'hdr10','hdrCinema','hdmi1',{});
 is_deeply($keys,['brightness'],'reset filters wrong-signal and unprobed keys through the matrix');
 ($keys)=main::lg_picture_reset_contract_keys($g3,[qw(brightness gamma madeUpKey)],'hdr10','hdrCinema','hdmi1',{});
 is_deeply($keys,['brightness','gamma'],'G3 reset keeps gamma in HDR10, where its API accepts it');
 ok(!main::lg_picture_reset_ddc_baseline_ok(1,{status=>'ok',ddc_baseline_reset=>1,ddc_reset_verified=>1,ddc_reset_verify_contract=>'write-accepted-readback-untrusted'}),'reset cannot relabel legacy acknowledgement as hardware verification');
}

{
 local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=tempdir(CLEANUP=>1);
 no warnings 'redefine';
 local *main::lg_authenticated_session=sub {{status=>'ok',session=>{},client_key=>'fixture',
  system_info=>{modelName=>'OLED65C1PUB'},
  software_info=>{model_name=>'HE_DTV_W21O_TEST'},hello_info=>{deviceUUID=>'fixture-c1'}}};
 local *main::websocket_close=sub {};
 local *main::diag_log_append=sub {};
 my $read={type=>'error',error=>'500 Application error',payload=>{errorMessage=>'Some keys are not allowed for the request'}};
 my $write={type=>'response',payload=>{returnValue=>1}};
 local *main::lg_request=sub {$_[2] eq 'settings/setSystemSettings' ? $write : $read};
 my $run=sub {main::lg_picture_set_workflow('fixture','fixture',1,{brightness=>50},[],'hdmi1',0,'filmMaker',0,0,0,0,'sdr','picture')};
 my $r=$run->();
 is($r->{status},'ok','native write accepts explicit matrix-authorized unavailable readback');
 is($r->{verification_state},'acknowledged_unverified','native helper never labels the missing readback verified');
 is($r->{setting_verification}{brightness}{status},'acknowledged_unverified','per-key evidence retains acknowledgement status');
 ok(!exists($r->{picture_settings}{brightness}),'write-only result never fabricates current brightness');
 $write={type=>'response',payload=>{}};
 is($run->()->{status},'error','ambiguous write reply cannot become write-only success');
 $write={type=>'response',payload=>{returnValue=>1}};
 my $panel=main::lg_picture_set_workflow('fixture','fixture',1,{backlight=>50},[],'hdmi1',0,'filmMaker',0,0,0,0,'sdr','picture');
 is($panel->{verification_state},'acknowledged_unverified','panel-light readback loop respects the same matrix policy');
 $read={type=>'response',payload=>{returnValue=>1,settings=>{brightness=>49}}};
 is($run->()->{error_code},'setting-readback-mismatch','write-only candidate still fails actual mismatch');
 $read={type=>'response',payload=>{returnValue=>1,settings=>{brightness=>50}}};
 is($run->()->{verification_state},'verified','same native route verifies when the TV can read back');
 for my $failure (undef,{type=>'close'}, {type=>'error',error=>'Permission denied: unavailable'}, {type=>'error',error=>'Read timed out'}) {
  $read=$failure;
  is($run->()->{status},'error','lost, unauthorised or timed-out readback is not waived');
 }
 $write={type=>'error',error=>'Write not allowed'};
 $read={type=>'response',payload=>{returnValue=>1,settings=>{brightness=>50}}};
 is($run->()->{status},'error','actual native write rejection remains fatal');
}

done_testing();
