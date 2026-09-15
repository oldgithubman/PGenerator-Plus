package PGAutomationProcessing;
use strict;
use warnings;
use JSON::PP ();
use Time::HiRes qw(time);
use PGLGCapabilities qw(lg_setting_values_agree lg_best_settings_plan);

# Only queue-requested processing controls, never luminance, gamut or a mode
# substitution. Called between calibration transitions and meter readings.
sub agrees {
 my ($a,$b,$key)=@_;
 return 0 if !defined($a) || !defined($b) || ref($a) || ref($b);
 if($key eq 'pictureMode') {
  ($a,$b)=map {my $v=lc($_);$v=~s/[\s_-]+//g;$v} ($a,$b);
 }
 return abs($a-$b)<=0.1 if "$a"=~/^-?\d+(?:\.\d+)?$/ && "$b"=~/^-?\d+(?:\.\d+)?$/;
 return lc("$a") eq lc("$b");
}

sub enforce {
 my ($config,$state,$epoch,$api,$log)=@_;
 my $requested=$config->{automation_processing_settings};
 return 1 if ref($requested) ne 'HASH' || !keys %$requested;
 return 1 if defined($state->{automation_processing_epoch}) && $state->{automation_processing_epoch}==$epoch;
 my %expected=%$requested;
 die "Invalid automation processing control\n" if grep {!/^(?:smoothGradation|noiseReduction|mpegNoiseReduction|superResolution|sharpness|realCinema)$/} keys %expected;
 die "Missing automation picture mode\n" if !$config->{picture_mode};
 $expected{pictureMode}=$config->{picture_mode};
 my $point="3d-processing-transition-$epoch";
 my $record=sub {
  my ($key,$observed,$result,$reason,$operation)=@_;
  push @{$state->{automation_processing_checks}}, {
   key=>$key,expected=>$expected{$key},observed=>$observed,result=>$result,
   reason=>$reason,operation=>$operation||'readback',category=>'picture',
   verified=>$result eq 'verified'?JSON::PP::true:JSON::PP::false,
   timestamp=>time(),checkpoint=>$point,
  };
 };
 my $mode=$api->('GET','/api/lg/status',undef,30);
 die "Processing settings check: calibration mode unavailable\n"
  if ref($mode) ne 'HASH' || ($mode->{status}||'') ne 'ok' || $mode->{disconnected} || !exists $mode->{calibration_mode};
 my $read=sub {
  my $r=$api->('POST','/api/lg/picture-settings',{
   keys=>[sort keys %expected],picture_mode=>$config->{picture_mode},signal_mode=>$config->{signal_mode},
   category=>'picture',include_current_input=>JSON::PP::true,tv_input=>$config->{tv_input}||'',
  },45);
  $r={} if ref($r) ne 'HASH';
  my $values=$r->{picture_settings}||$r->{settings};
  my $unavailable=($r->{status}||'') ne 'ok' || ref($values) ne 'HASH'
   || (($config->{tv_input}||'') ne '' && ($r->{current_input}||'') ne $config->{tv_input});
  my %native=map {$_=>1} @{$r->{supported_picture_keys}||[]};
  my $virtual=$r->{virtual_picture_settings} || $r->{manual_confirmation_required};
  my $best=lg_best_settings_plan($r->{lg_generation},$requested,$r,
   category=>'picture',signal_mode=>$config->{signal_mode},picture_mode=>$config->{picture_mode},tv_input=>$config->{tv_input});
  my $frozen=$config->{preflight_generation_profile}{capability_profile_hash}||'';
  my $mode_unverified=0;
  my @bad;
  for my $key (sort keys %expected) {
   my $unsupported=ref($r->{unsupported_picture_keys}) eq 'HASH' && exists($r->{unsupported_picture_keys}{$key});
   my $has=!$unavailable && !$unsupported && (!$virtual || $native{$key}) && exists($values->{$key}) && defined($values->{$key});
   if($key eq 'pictureMode' && !$has && !$unavailable && $virtual && $best->{active}
      && $frozen ne '' && $best->{capability_profile_hash} eq $frozen) {
    $mode_unverified=1;
    $record->($key,undef,'unverifiable','TV matrix permits unavailable mode readback; no processing rewrites are allowed without confirmed mode');
    next;
   }
   my $ok=$has && agrees($expected{$key},$values->{$key},$key);
   my $contract=ref($r->{setting_contracts}) eq 'HASH' ? $r->{setting_contracts}{$key} : undef;
   $ok=$has && lg_setting_values_agree($contract,$expected{$key},$values->{$key})
    if($key ne 'pictureMode' && ref($contract) eq 'HASH');
   my $reason=$ok?'TV readback matches the requested value':!$has
    ? ($r->{message}||'Processing setting readback unavailable') : 'TV value differs after calibration transition';
   $record->($key,$has?$values->{$key}:undef,$ok?'verified':$has?'mismatch':'unverifiable',$reason);
   die "Processing settings check: $key cannot be verified: $reason\n" if !$has;
   push @bad,$key if !$ok;
  }
  die "Processing settings check: picture mode differs; no settings rewritten\n" if grep {$_ eq 'pictureMode'} @bad;
  die "Processing settings check: picture mode is unverified and a processing value differs; no settings rewritten\n"
   if($mode_unverified && @bad);
  if($mode_unverified) {
   my $warning='Native processing values matched, but the TV matrix cannot verify picture mode; no settings were rewritten.';
   $log->($warning);
   push @{$state->{automation_processing_warnings}},$warning
    if !grep {$_ eq $warning} @{$state->{automation_processing_warnings}||[]};
  }
  return (\@bad,$values);
 };
 $log->('Checking queued processing settings after calibration transition');
 my ($bad,$values)=$read->();
 if(@$bad) {
  for my $key (@$bad) {
   my $r=$api->('POST','/api/lg/picture-settings/set',{
    settings=>{$key=>$expected{$key}},readback_keys=>[$key,'pictureMode'],
    picture_mode=>$config->{picture_mode},signal_mode=>$config->{signal_mode},category=>'picture',
    tv_input=>$config->{tv_input}||'',
    keep_calibration_mode=>$mode->{calibration_mode}?JSON::PP::true:JSON::PP::false,
    calibration_mode_active=>$mode->{calibration_mode}?JSON::PP::true:JSON::PP::false,
   },45);
   $r={} if ref($r) ne 'HASH';
   my $ok=($r->{status}||'') eq 'ok'
    && (!exists($r->{verification_state}) || ($r->{verification_state}||'') eq 'verified');
   $record->($key,undef,$ok?'applied':'apply-failed',$ok?'Restoring requested processing setting before further measurements':$r->{message}||'TV rejected restoration','write');
   die "Processing settings check: failed to restore $key\n" if !$ok;
  }
  for(1..2) {
   my ($remaining)=$read->();
   die 'Processing settings did not remain restored: '.join(', ',@$remaining)."\n" if @$remaining;
  }
  my $after=$api->('GET','/api/lg/status',undef,30);
  die "Processing settings check: calibration mode changed during restoration\n"
   if ref($after) ne 'HASH' || ($after->{status}||'') ne 'ok' || $after->{disconnected}
    || !exists($after->{calibration_mode}) || !!$after->{calibration_mode} != !!$mode->{calibration_mode};
  for my $key (@$bad) {
   my $message="Restored $key to $expected{$key} after calibration transition; checked before further measurements";
   $log->($message);
   push @{$state->{automation_processing_warnings}},$message
    if !grep {$_ eq $message} @{$state->{automation_processing_warnings}||[]};
  }
 }
 $state->{automation_processing_epoch}=$epoch;
 return 1;
}
1;
