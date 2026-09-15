use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
my @requests;
my $mode='filmMaker';my $failed=0;my $busy=0;my $switch=0;
{
 no warnings qw(redefine once prototype);
 *main::lg_automation_guard_json=sub {return $busy?' {"status":"error","message":"Automation active"}':'';};
 *main::webui_pattern_signal_mode=sub {'sdr'};
 *main::webui_lg_picture_settings=sub {
  my $request=PGAutomation::decode_json($_[0]);push @requests,$request;
  return PGAutomation::encode_json({status=>'error',message=>'Disconnected'}) if($failed);
  return PGAutomation::encode_json({status=>'ok',lg_generation=>{model_name=>'OLED55G36LA',platform_model=>'W23O',software_version=>'23.25.55'},current_input=>'hdmi4',
   picture_settings=>{pictureMode=>$switch&&@requests>1?'cinema':$mode,backlight=>18,contrast=>72},supported_picture_keys=>['pictureMode','backlight','contrast']});
 };
}
sub settings_plan {
 @requests=();
 return PGAutomation::decode_json(main::webui_automation_api('/api/automation/settings-plan','POST',PGAutomation::encode_json({settings=>{contrast=>85},signal_mode=>$_[0]||'sdr',picture_mode=>$_[1]||'filmMaker',lg_generation=>{model_name=>'FAKE'}})));
}
my $p=settings_plan();
is($p->{status},'ok','read-only settings plan endpoint works');
is($p->{model_name},'OLED55G36LA','identity comes from TV, not caller');
is($p->{automatic}{contrast},85,'reference value survives live read of 72');
is($p->{panel_light}{wire_key},'backlight','resolves shared logical control');
ok($p->{calibration_mode}{allowed},'editor plan includes AutoCal admission');
ok($p->{live_context_matches},'native matching context is confirmed');
is(scalar @requests,2,'reads context before controls');
ok(!grep({exists($_->{picture_mode})||exists($_->{settings})} @requests),'editor never switches mode or writes settings');
$p=settings_plan('hdr10','hdrCinema');
is(scalar @requests,1,'inactive signal does not probe picture controls');
ok(!$p->{live_context_matches},'inactive signal not presented as live verified');
is($p->{panel_light}{source},'tv_matrix','inactive job uses matrix mapping');
$p=settings_plan('hdr10','hdrCinemaBright');
ok(!$p->{calibration_mode}{allowed},'HDR Home selectable values do not imply a calibration bank');
is(scalar @requests,1,'mode rejection requires no signal switch or calibration probe');
$mode='cinema';$p=settings_plan();
is(scalar @requests,1,'different active picture mode is not probed');
$mode='filmMaker';$switch=1;
is(settings_plan()->{status},'error','mode change during read cannot publish stale context');
$switch=0;$failed=1;
is(settings_plan()->{status},'error','disconnection cannot become a guessed settings plan');
$failed=0;$busy=1;
is(settings_plan()->{status},'error','active calibration guards editor hardware reads');
is(scalar @requests,0,'busy state makes no TV calls');
done_testing();
