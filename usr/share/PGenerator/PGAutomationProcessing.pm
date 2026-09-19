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

# Client budgets for the two TV conversations this check makes. The daemon
# gives the helper 60 s for a read and 45 s for a lone write, and both queue
# behind whatever else holds the TV helper gate (a 19-key readback is 26-60 s
# on the G3), so the client must outwait the queue as well as the helper.
# 18 Sep 2026: a restore write that timed out at 45 s landed on the TV six
# seconds later and the job was failed for a write that had succeeded.
our $READ_TIMEOUT=90;
our $WRITE_TIMEOUT=120;
# After a write whose outcome is unknown (client timeout, daemon unreachable),
# poll the TV for this long before calling the restore a failure. The window
# is two full read budgets so a confirm read that itself times out behind
# the gate still leaves room for a second attempt.
our $CONFIRM_WINDOW=180;
our $CONFIRM_INTERVAL=5;
# A readback that fails in transport (never a TV answer) is retried this many
# times before the check gives up; the daemon can hold the TV gate for up to
# about four minutes when a helper times out and reconnects.
our $READ_ATTEMPTS=3;
# One enforce call starts no further write or verification read once this
# many seconds have passed, whatever the retries and the confirm window
# would otherwise allow (about 44 minutes in the worst case for six
# controls); a TV that stays unreachable this long is a failure, not a
# queue. A conversation already in flight still runs to its own timeout.
our $ENFORCE_BUDGET=600;

# A result that says nothing about what the TV did: the request may still
# be queued or in flight on the daemon, or the daemon's own helper timed out
# after sending the write ("LG TV did not finish writing ... within 45s").
# A TV rejection or a stop request is a known outcome and is never retried.
sub outcome_unknown {
 my ($r)=@_;
 return 0 if ref($r) ne 'HASH' || ($r->{status}||'') eq 'ok';
 my $message=$r->{message}||'';
 return 0 if $message=~/cancel/i;
 return $message=~/timed out|unavailable|read failed|no response|did not (?:answer|finish)|connection (?:reset|refused|closed)/i ? 1 : 0;
}
sub write_outcome_unknown { return outcome_unknown(@_); }

# One settings readback through the daemon, retried on transport failure
# only. A stop request or a TV answer of any kind returns at once.
sub read_settings {
 my ($api,$config,$keys,$deadline)=@_;
 my $r={};
 for my $attempt (1..$READ_ATTEMPTS) {
  $r=$api->('POST','/api/lg/picture-settings',{
   keys=>$keys,picture_mode=>$config->{picture_mode},signal_mode=>$config->{signal_mode},
   category=>'picture',include_current_input=>JSON::PP::true,tv_input=>$config->{tv_input}||'',
  },$READ_TIMEOUT);
  $r={} if ref($r) ne 'HASH';
  last if !outcome_unknown($r);
  last if defined($deadline) && time()>=$deadline;
 }
 return $r;
}

# Read one control (and the picture mode) until it shows the expected value
# or the window closes. A differing value is not final until the window
# closes, because the write may still be queued behind the helper gate.
sub confirm_by_readback {
 my ($api,$config,$key,$expected,$limit)=@_;
 my $deadline=time()+$CONFIRM_WINDOW;
 $deadline=$limit if defined($limit) && $limit<$deadline;
 my $observed;
 while(1) {
  my $r=read_settings($api,$config,[$key,'pictureMode'],$deadline);
  return (0,undef,'cancelled') if ($r->{message}||'')=~/cancel/i;
  my $values=$r->{picture_settings}||$r->{settings};
  my $usable=($r->{status}||'') eq 'ok' && ref($values) eq 'HASH'
   && (($config->{tv_input}||'') eq '' || ($r->{current_input}||'') eq $config->{tv_input})
   && !(ref($r->{unsupported_picture_keys}) eq 'HASH' && exists($r->{unsupported_picture_keys}{$key}))
   && !(($r->{virtual_picture_settings}||$r->{manual_confirmation_required}) && !grep {$_ eq $key} @{$r->{supported_picture_keys}||[]});
  if($usable && defined($values->{$key})) {
   $observed=$values->{$key};
   my $mode_ok=!defined($values->{pictureMode}) || agrees($config->{picture_mode},$values->{pictureMode},'pictureMode');
   return (1,$observed,'TV readback confirms the value') if $mode_ok && agrees($expected,$observed,$key);
  }
  last if time()>=$deadline;
  sleep($CONFIRM_INTERVAL) if $CONFIRM_INTERVAL>0;
 }
 return (0,$observed,defined($observed)?'TV readback still differs after the write':'TV readback unavailable after the write');
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
 my $budget_deadline=time()+$ENFORCE_BUDGET;
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
  my $r=read_settings($api,$config,[sort keys %expected],$budget_deadline);
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
 my $over_budget=sub { die "Processing settings check: TV did not respond within the check budget\n" if time()>=$budget_deadline; };
 if(@$bad) {
  for my $key (@$bad) {
   $over_budget->();
   my $r=$api->('POST','/api/lg/picture-settings/set',{
    settings=>{$key=>$expected{$key}},readback_keys=>[$key,'pictureMode'],
    picture_mode=>$config->{picture_mode},signal_mode=>$config->{signal_mode},category=>'picture',
    tv_input=>$config->{tv_input}||'',
    keep_calibration_mode=>$mode->{calibration_mode}?JSON::PP::true:JSON::PP::false,
    calibration_mode_active=>$mode->{calibration_mode}?JSON::PP::true:JSON::PP::false,
   },$WRITE_TIMEOUT);
   $r={} if ref($r) ne 'HASH';
   my $ok=($r->{status}||'') eq 'ok'
    && (!exists($r->{verification_state}) || ($r->{verification_state}||'') eq 'verified');
   my $observed;
   my $reason=$ok?'Restoring requested processing setting before further measurements':$r->{message}||'TV rejected restoration';
   if(!$ok && write_outcome_unknown($r)) {
    # The write may have landed after the client stopped waiting. Ask the TV
    # before treating a lost reply as a rejection.
    $log->("Restore write for $key returned no result ($reason); confirming by readback");
    my ($confirmed,$seen,$why)=confirm_by_readback($api,$config,$key,$expected{$key},$budget_deadline);
    $observed=$seen;
    if($confirmed) {
     $ok=1;
     $reason="Write reply lost ($r->{message}); $why";
    } else {
     $reason="$reason; $why";
    }
   }
   $record->($key,$observed,$ok?'applied':'apply-failed',$reason,'write');
   die "Processing settings check: failed to restore $key\n" if !$ok;
  }
  for(1..2) {
   $over_budget->();
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
