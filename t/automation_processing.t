use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use PGAutomationProcessing;
use Test::More;
use JSON::PP ();
my $config={picture_mode=>'hdrCinema',signal_mode=>'hdr10',automation_processing_settings=>{smoothGradation=>'off',sharpness=>0}};
# Confirmation polling is exercised without real waits.
$PGAutomationProcessing::CONFIRM_WINDOW=0;
$PGAutomationProcessing::CONFIRM_INTERVAL=0;
$PGAutomationProcessing::READ_ATTEMPTS=3;
for my $case (qw(matched repair read-failed read-timeout-then-ok read-timeout-persistent read-timeout-budget-spent repair-budget-spent read-attempts-zero unsupported missing-value wrong-mode write-failed unstable unknown-cal-mode cal-mode-changed virtual write-timeout write-did-not-finish write-timeout-second-poll write-timeout-unconfirmed write-timeout-virtual write-cancelled)) {
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
   return {status=>'error',message=>'Web UI API timed out during /api/lg/picture-settings'} if $case=~/^read-timeout-(?:persistent|budget-spent)$/ || ($case eq 'read-timeout-then-ok' && $reads==1);
   return {status=>'error',message=>'Web UI API timed out during /api/lg/picture-settings'} if $case eq 'write-timeout-second-poll' && $reads==2;
   return {status=>'ok',virtual_picture_settings=>1,supported_picture_keys=>[],picture_settings=>{pictureMode=>'hdrCinema',smoothGradation=>'off'}} if $case eq 'write-timeout-virtual' && $reads>=2;
   my $settings={pictureMode=>'hdrCinema',smoothGradation=>($case eq 'matched'||$reads>1)?'off':'low',sharpness=>0};
   $settings->{pictureMode}='hdrFilmMaker' if $case eq 'wrong-mode';
   delete $settings->{smoothGradation} if $case eq 'missing-value';
   $settings->{smoothGradation}='low' if $case eq 'unstable' && $reads==3;
   $settings->{smoothGradation}='low' if $case eq 'write-timeout-unconfirmed';
   $settings->{smoothGradation}='low' if $case eq 'read-timeout-then-ok' && $reads==2;
   return {status=>'ok',picture_settings=>$settings,
    ($case eq 'unsupported'?(unsupported_picture_keys=>{smoothGradation=>'not readable'}):()),
    ($case eq 'virtual'?(virtual_picture_settings=>1):())};
  }
  if($path eq '/api/lg/picture-settings/set') {
   is_deeply($body->{settings},{smoothGradation=>'off'},"$case writes only the changed requested control");
   ok(!$body->{keep_calibration_mode} && !$body->{calibration_mode_active},"$case does not reopen calibration mode");
   return {status=>'error',message=>'Web UI API timed out during /api/lg/picture-settings/set'} if $case=~/^write-timeout/;
   return {status=>'error',message=>'LG TV did not finish writing 1 picture control within 45s.'} if $case eq 'write-did-not-finish';
   return {status=>'error',message=>'cancelled'} if $case eq 'write-cancelled';
   return {status=>$case eq 'write-failed'?'error':'ok',message=>'write result'};
  }
  die 'Unexpected API';
 };
 # The second-poll case needs a window the mocked reads stay inside.
 local $PGAutomationProcessing::CONFIRM_WINDOW=$case eq 'write-timeout-second-poll' ? 30 : 0;
 local $PGAutomationProcessing::ENFORCE_BUDGET=$case=~/budget-spent$/ ? 0 : 600;
 local $PGAutomationProcessing::READ_ATTEMPTS=$case eq 'read-attempts-zero' ? 0 : 3;
 my $ok=eval {PGAutomationProcessing::enforce($config,$state,1,$api,sub{push @logs,$_[0]})};
 if($case eq 'read-timeout-then-ok') {
  ok($ok,"$case: a readback lost in transport is retried, then the mismatch is repaired");
  is($reads,4,"$case retries once, then reads for the repair and verification");
  next;
 }
 if($case eq 'read-timeout-budget-spent') {
  ok(!$ok,"$case stops before measuring");
  is($reads,1,'an exhausted enforce budget stops the readback retries');
  like($@,qr/cannot be verified/,'the check still fails with its own message');
  next;
 }
 if($case eq 'repair-budget-spent') {
  ok(!$ok,"$case stops before measuring");
  like($@,qr/did not respond within the check budget/,'an exhausted budget stops before the restore write');
  is(scalar(grep {$_->[0] eq '/api/lg/picture-settings/set'} @calls),0,'no write is started past the budget');
  next;
 }
 if($case eq 'read-attempts-zero') {
  ok(!$ok,"$case stops before measuring");
  is($reads,0,'no readback attempted');
  like($@,qr/Processing settings check: .*cannot be verified/,'zero attempts fail with the check message, not a Perl error');
  next;
 }
 if($case eq 'read-timeout-persistent') {
  ok(!$ok,"$case stops before measuring");
  is($reads,3,"$case gives the readback three attempts");
  like($@,qr/cannot be verified.*timed out/,'the transport reason survives the retries');
  next;
 }
 if($case eq 'write-did-not-finish') {
  # The daemon's own helper timeout after the write was sent is the same
  # lost-reply case one layer down.
  ok($ok,"$case: the daemon helper timing out after the write is confirmed by readback");
  my ($write)=grep {$_->{operation} eq 'write'} @{$state->{automation_processing_checks}};
  is($write->{result},'applied','confirmed write recorded as applied');
  next;
 }
 if($case eq 'write-timeout-second-poll') {
  ok($ok,"$case: a confirm read lost in transport does not end the window");
  is($reads,5,"$case reads, retries the lost confirm read, confirms, then verifies twice");
  next;
 }
 if($case eq 'write-timeout') {
  # 18 Sep 2026: the restore write timed out at the client and landed on the
  # TV six seconds later; the job was failed for a write that had succeeded.
  ok($ok,"$case: a lost write reply is confirmed by readback, not treated as a rejection");
  is($reads,4,"$case reads once, confirms once, then verifies twice");
  my ($write)=grep {$_->{operation} eq 'write'} @{$state->{automation_processing_checks}};
  is($write->{result},'applied','confirmed write is recorded as applied');
  like($write->{reason},qr/reply lost.*timed out.*readback confirms/,'record keeps the lost reply and the confirmation');
  is($write->{observed},'off','record carries the value the TV reported');
  is(scalar @{$state->{automation_processing_warnings}||[]},1,'restoration is still reported as a warning');
  ok((grep {/confirming by readback/} @logs),'log says the reply was lost and a readback followed');
  next;
 }
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
  if($case eq 'write-timeout-unconfirmed') {
   like($@,qr/failed to restore smoothGradation/,'a lost reply whose readback still differs is a failed restore');
   is($reads,2,'one confirmation readback inside the window');
   my ($write)=grep {$_->{operation} eq 'write'} @{$state->{automation_processing_checks}};
   is($write->{result},'apply-failed','unconfirmed write stays apply-failed');
   like($write->{reason},qr/timed out.*still differs/,'record explains both the lost reply and the readback');
  }
  if($case eq 'write-timeout-virtual') {
   like($@,qr/failed to restore smoothGradation/,'a virtual readback cannot confirm a lost write');
   my ($write)=grep {$_->{operation} eq 'write'} @{$state->{automation_processing_checks}};
   like($write->{reason},qr/readback unavailable/,'record says the readback could not confirm');
  }
  if($case eq 'write-cancelled') {
   like($@,qr/failed to restore smoothGradation/,'a cancelled write is not retried');
   is($reads,1,'no confirmation readback after a stop request');
  }
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
