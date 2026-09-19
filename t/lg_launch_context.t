use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
my $live={status=>'ok',current_input=>'hdmi2',generation_profile=>{
 capability_library_valid=>1,capability_platform_profile_applied=>1,
 capability_profile_id=>'test-g3',capability_profile_hash=>'a'x64}};
local *main::webui_lg_picture_settings=sub {
 my $request=PGAutomation::decode_json($_[0]);
 ok($request->{include_current_input},'launch independently probes current input');
 is_deeply($request->{keys},['pictureMode'],'launch performs only a read');
 return PGAutomation::encode_json($live);
};
my ($body,$error)=main::webui_lg_freeze_calibration_context('{"signal_mode":"sdr","automation_token":"test-token"}');
ok(!$error,'standalone launch without context is stamped from TV');
my $config=PGAutomation::decode_json($body);
is($config->{tv_input},'hdmi2','actual input frozen');
is($config->{preflight_generation_profile}{capability_profile_hash},'a'x64,'actual profile frozen');
is($config->{automation_token},'test-token','ownership token retained');
($body,$error)=main::webui_lg_freeze_calibration_context(PGAutomation::encode_json($config));
ok(!$error,'matching queued context remains valid');
$config->{tv_input}='hdmi1';
($body,$error)=main::webui_lg_freeze_calibration_context(PGAutomation::encode_json($config));
like($error,qr/input changed/,'changed queued input blocks launch');
$config->{tv_input}='hdmi2';$config->{preflight_generation_profile}{capability_profile_hash}='b'x64;
($body,$error)=main::webui_lg_freeze_calibration_context(PGAutomation::encode_json($config));
like($error,qr/profile changed/,'changed queued profile blocks launch');
$live->{generation_profile}{capability_platform_profile_applied}=0;
($body,$error)=main::webui_lg_freeze_calibration_context('{}');
ok($error && !defined($body),'unknown internal platform cannot launch standalone calibration');
$live->{generation_profile}{capability_platform_profile_applied}=1;$live->{current_input}='';
($body,$error)=main::webui_lg_freeze_calibration_context('{}');
ok($error && !defined($body),'unreadable input cannot launch standalone calibration');
done_testing();
