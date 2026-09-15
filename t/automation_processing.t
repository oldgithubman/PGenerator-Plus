use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use PGAutomationProcessing;
use Test::More;
use JSON::PP ();
my $config={picture_mode=>'hdrCinema',signal_mode=>'hdr10',automation_processing_settings=>{smoothGradation=>'off',sharpness=>0}};
for my $case (qw(matched repair read-failed unsupported missing-value wrong-mode write-failed unstable unknown-cal-mode cal-mode-changed virtual)) {
 my (@calls,@logs);my $state={};my $reads=0;my $modes=0;
 my $api=sub {
  my ($method,$path,$body)=@_;push @calls,[$path,$body];
  if($path eq '/api/lg/status') {
   $modes++;
   return {status=>'ok'} if $case eq 'unknown-cal-mode';
   return {status=>'ok',calibration_mode=>($case eq 'cal-mode-changed' && $modes>1)?1:0};
  }
  if($path eq '/api/lg/picture-settings') {
   $reads++;
   return {status=>'error',message=>'TV socket timed out'} if $case eq 'read-failed';
   my $settings={pictureMode=>'hdrCinema',smoothGradation=>($case eq 'matched'||$reads>1)?'off':'low',sharpness=>0};
   $settings->{pictureMode}='hdrFilmMaker' if $case eq 'wrong-mode';
   delete $settings->{smoothGradation} if $case eq 'missing-value';
   $settings->{smoothGradation}='low' if $case eq 'unstable' && $reads==3;
   return {status=>'ok',picture_settings=>$settings,
    ($case eq 'unsupported'?(unsupported_picture_keys=>{smoothGradation=>'not readable'}):()),
    ($case eq 'virtual'?(virtual_picture_settings=>1):())};
  }
  if($path eq '/api/lg/picture-settings/set') {
   is_deeply($body->{settings},{smoothGradation=>'off'},"$case writes only the changed requested control");
   ok(!$body->{keep_calibration_mode} && !$body->{calibration_mode_active},"$case does not reopen calibration mode");
   return {status=>$case eq 'write-failed'?'error':'ok',message=>'write result'};
  }
  die 'Unexpected API';
 };
 my $ok=eval {PGAutomationProcessing::enforce($config,$state,1,$api,sub{push @logs,$_[0]})};
 if($case eq 'matched'||$case eq 'repair') {
  ok($ok,"$case allows measurement");
  is($reads,$case eq 'repair'?3:1,"$case reads the needed evidence");
  my $before=@calls;
  ok(PGAutomationProcessing::enforce($config,$state,1,$api,sub{}),'same transition is cached');
  is(scalar @calls,$before,'no TV polling per patch without a calibration transition');
  ok(PGAutomationProcessing::enforce($config,$state,2,$api,sub{}),'new transition requires a check');
  ok(@calls>$before,'new calibration transition gets fresh readback');
  is(scalar @{$state->{automation_processing_warnings}||[]},$case eq 'repair'?1:0,'only actual restoration creates a warning');
 } else {
  ok(!$ok,"$case stops before measuring");
  ok(!exists $state->{automation_processing_epoch},"$case cannot be cached as checked");
  is(scalar @{$state->{automation_processing_warnings}||[]},0,"$case does not claim successful restoration");
  like($@,qr/socket timed out/,'transport reason retained') if $case eq 'read-failed';
  is(scalar(grep {$_->[0] eq '/api/lg/picture-settings/set'} @calls),0,"$case makes no speculative setting write")
   if $case=~/^(?:read-failed|unsupported|missing-value|wrong-mode|unknown-cal-mode|virtual)$/;
 }
}
my $called=0;
ok(PGAutomationProcessing::enforce({}, {}, 0, sub {$called++},sub{}),'standalone run with no queue contract unchanged');
is($called,0,'standalone path does not introduce TV requests');
{
 my $identity={model_name=>'OLED65C1PUB',platform_model=>'W21O'};
 my $profile=PGLGCapabilities::resolve_lg_capabilities($identity);
 my $config={picture_mode=>'filmMaker',signal_mode=>'sdr',tv_input=>'hdmi1',
  preflight_generation_profile=>{capability_profile_hash=>$profile->{capability_profile_hash}},
  automation_processing_settings=>{noiseReduction=>'off'}};
 my $mismatch=0;my $writes=0;my $state={};
 my $api=sub {
  return {status=>'ok',calibration_mode=>0} if $_[1] eq '/api/lg/status';
  if($_[1] eq '/api/lg/picture-settings/set') {$writes++;die 'Unexpected write'}
  return {status=>'ok',current_input=>'hdmi1',lg_generation=>$identity,virtual_picture_settings=>1,
   supported_picture_keys=>['noiseReduction'],picture_settings=>{pictureMode=>'filmMaker',noiseReduction=>$mismatch?'low':'off'}};
 };
 ok(PGAutomationProcessing::enforce($config,$state,1,$api,sub {}),'legacy native processing reads remain usable despite unreadable mode');
 my ($mode)=grep {$_->{key} eq 'pictureMode'} @{$state->{automation_processing_checks}};
 is($mode->{result},'unverifiable','worker does not relabel the legacy mode verified');
 is(scalar @{$state->{automation_processing_warnings}},1,'mode uncertainty remains visible in worker evidence');
 $mismatch=1;
 ok(!eval {PGAutomationProcessing::enforce($config,{},2,$api,sub {})},'processing mismatch with unconfirmed mode blocks rather than repairing blindly');
 is($writes,0,'legacy mode uncertainty never authorizes speculative processing rewrites');
 $mismatch=0;$config->{preflight_generation_profile}{capability_profile_hash}='changed';
 ok(!eval {PGAutomationProcessing::enforce($config,{},3,$api,sub {})},'changed frozen profile prevents the legacy processing exception');
}
done_testing();
