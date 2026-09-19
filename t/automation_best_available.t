use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(lg_setting_contracts resolve_lg_capabilities);
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
local *main::webui_lg_status_json=sub {PGAutomation::encode_json({paired=>1,connected=>1})};
local *main::webui_lg_calibration_mode=sub {PGAutomation::encode_json({status=>'ok',calibration_mode=>0})};
local *main::webui_meter_status=sub {PGAutomation::encode_json({detected=>1})};
local *main::webui_meter_series_alive=sub {0};
local *main::webui_meter_lg_autocal_running=sub {0};
local *main::webui_meter_lg_3d_autocal_running=sub {0};
local *main::webui_meter_lg_dv_profile_running=sub {0};
local *main::webui_meter_session_alive=sub {0};
local *main::webui_automation_probe_hazard=sub {undef};
my $identity={model_name=>'OLED65C1PUB',series=>'C1',platform_model=>'W21O',platform_year=>2021,generation_id=>'lg2020_2021_oled'};
my $refusal='Some keys are not allowed for the request';
my $missing_brightness=0;
local *main::webui_lg_picture_settings=sub {
 my $req=PGAutomation::decode_json($_[0]);
 my $matrix=lg_setting_contracts($identity,category=>'picture',signal_mode=>$req->{signal_mode}||'sdr',picture_mode=>$req->{picture_mode}||'filmMaker',tv_input=>'hdmi1',keys=>$req->{keys});
 my $profile=resolve_lg_capabilities($identity);
 my %read=(pictureMode=>$req->{picture_mode}||'filmMaker',brightness=>50,contrast=>85,backlight=>50,color=>50,energySaving=>'off');
 delete $read{brightness} if $missing_brightness;
 my @native=grep {exists($read{$_}) && $_ ne 'pictureMode'} @{$req->{keys}};
 return PGAutomation::encode_json({status=>'ok',current_input=>'hdmi1',lg_generation=>$identity,
  generation_profile=>{capability_library_valid=>$profile->{library_valid},capability_platform_profile_applied=>$profile->{platform_profile_applied},
   capability_profile_id=>'fixture',capability_profile_hash=>$profile->{capability_profile_hash}},
  virtual_picture_settings=>1,picture_settings=>\%read,supported_picture_keys=>\@native,
  unsupported_picture_keys=>{map {$_=>$refusal} grep {!exists $read{$_}} @{$req->{keys}}},
  setting_contracts=>$matrix->{contracts},settings_matrix=>$matrix});
};
my $job={name=>'Legacy recipe',signal_format=>'sdr',picture_mode=>'filmMaker',settings=>{gamma=>'bt1886',noiseReduction=>'off',brightness=>50},
 stages=>{calibration=>1,apply_all=>0,pre_readings=>0,post_readings=>0}};
my $untrusted=main::webui_automation_normalize_item({%$job,best_available_settings=>{active=>1,manual=>{brightness=>{value=>50}}},best_available_write_ack=>{brightness=>{expected=>50}}},0);
ok(!exists($untrusted->{best_available_settings}) && !exists($untrusted->{best_available_write_ack}),'client-supplied plans and acknowledgements cannot bypass fresh server readiness');
my $run=sub {main::webui_automation_checked_readiness({scope=>'job',items=>[$job]},'start')};
my $r=$run->();
ok($r->{ready},'known legacy model passes readiness with explicit manual settings') or diag(PGAutomation::encode_json($r->{checks}));
ok($r->{items}[0]{best_available_settings}{manual}{gamma},'readiness saves matrix-derived manual instructions');
is($r->{items}[0]{settings}{noiseReduction},'off','requested manual values remain in job, not silently discarded');
ok(grep({$_->{level} eq 'warning' && $_->{message}=~/Set noiseReduction to off/} @{$r->{checks}}),'existing readiness UI receives actionable manual warning');
# Missing top-level/virtual aliases do not erase the generation's read ban.
{
 my $original=\&main::webui_lg_picture_settings;
 local *main::webui_lg_picture_settings=sub {
  my $reply=PGAutomation::decode_json($original->(@_));
  delete $reply->{virtual_picture_settings};
  delete $reply->{picture_settings}{pictureMode};
  $reply->{lg_generation}{picture_mode_read_forbidden}=JSON::PP::true;
  return PGAutomation::encode_json($reply);
 };
 my $limited=$run->();
 ok($limited->{ready},'nested read ban retains reviewed per-job readiness');
 ok(grep({$_->{name} eq 'item-0-key-pictureMode' && $_->{level} eq 'warning'} @{$limited->{checks}}),'unavailable nested picture mode is a visible warning, never a verified read');
}
$missing_brightness=1;
$r=$run->();
ok($r->{ready},'matrix-authorized missing brightness read does not block accepted-write attempt');
ok(grep({$_->{level} eq 'warning' && $_->{message}=~/brightness.*labelled unverified/} @{$r->{checks}}),'write-only readiness is visibly unverified');
$refusal='Permission denied: settings unavailable';
ok(!$run->()->{ready},'authentication refusal cannot become best-settings success');
$refusal='Some keys are not allowed for the request';
$job->{settings}{brightness}=101;
ok(!$run->()->{ready},'invalid recipe value remains blocked');
$job->{settings}{brightness}=50;
$job->{panel_light}={policy=>'target',key=>'brightness'};
ok(!$run->()->{ready},'invalid panel-light key is never authorized');
$job->{panel_light}={policy=>'target',key=>'backlight'};
# Make the normal supported panel value unavailable through the same fixture.
{
 my $original=\&main::webui_lg_picture_settings;
 local *main::webui_lg_picture_settings=sub {
  my $reply=PGAutomation::decode_json($original->(@_));
  delete $reply->{picture_settings}{backlight};
  $reply->{supported_picture_keys}=[grep {$_ ne 'backlight'} @{$reply->{supported_picture_keys}}];
  $reply->{unsupported_picture_keys}{backlight}=$refusal;
  PGAutomation::encode_json($reply);
 };
 ok(!$run->()->{ready},'target-luminance readiness cannot waive panel readback');
}
delete $job->{panel_light};
for my $case (['hdr10','hdrFilmMaker'],['dv','dolbyVisionFilmMaker']) {
 local $job->{signal_format}=$case->[0];local $job->{picture_mode}=$case->[1];
 local $job->{settings}={brightness=>50,noiseReduction=>'off'};
 my $result=$run->();
 ok($result->{ready},"C1 $case->[0] job readiness accepts the five-key policy with missing readback") or diag(PGAutomation::encode_json($result->{checks}));
 ok($result->{items}[0]{best_available_settings}{manual}{noiseReduction},"$case->[0] readiness retains manual instructions for other settings");
 ok(grep({$_->{level} eq 'warning' && $_->{message}=~/brightness.*labelled unverified/} @{$result->{checks}}),"$case->[0] accepted-only path is never presented as verified");
}
$identity={model_name=>'OLED55G36LA',series=>'G3',platform_model=>'W23O',platform_year=>2023,generation_id=>'lg2022plus_oled',software_version=>'23.25.55'};
ok(!$run->()->{ready},'modern TV still blocks these missing controls under its own matrix');
done_testing();
