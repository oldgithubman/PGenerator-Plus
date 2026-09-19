package PGLGVerification;
use strict;
use warnings;
use Exporter qw(import);
use PGLGCapabilities qw(lg_panel_light_binding lg_normalize_setting_value lg_setting_values_agree);
our @EXPORT_OK=qw(verify_lg_panel_light);

# Runs in the daemon, not in the browser. Once a write is attempted, always
# attempt restoration, even if the write/read throws or the browser goes away.
sub verify_lg_panel_light {
 my ($request,$read,$write)=@_;
 my $result={status=>'error',restored=>0,write_attempted=>0};
 my ($context,$key,$original,$test,$contract,$baseline,$changed,$restored);
 my $ok=eval {
  die "Run Verify this TV first to confirm the TV, input and picture mode.\n"
   if(($request->{expected_profile_hash}||'')!~/^[0-9a-f]{64}$/ || ($request->{tv_input}||'')!~/^hdmi[1-4](?:_pc)?$/ || ($request->{picture_mode}||'') eq '');
  die "Choose a supported signal mode before verification.\n" if(($request->{signal_mode}||'') !~ /^(?:sdr|hdr10|hlg|dv)$/);
  $context={map {$_=>$request->{$_}} qw(tv_input picture_mode signal_mode expected_profile_hash)};
  @$context{qw(expected_tv_input category include_current_input ignore_calibration_picture_mode)}=($request->{tv_input},'picture',1,1);
  my $initial=$read->({%$context,keys=>[qw(pictureMode backlight oledLight oledPixelBrightness)]});
  my $profile=$initial->{generation_profile}||{};
  die "Unable to independently confirm this TV and active picture slot.\n"
   if(($initial->{status}||'') ne 'ok' || !$initial->{settings_matrix}{context_confirmed}
    || ($initial->{current_input}||'') ne $context->{tv_input}
    || ($profile->{capability_profile_hash}||'') ne $context->{expected_profile_hash}
    || !$profile->{capability_library_valid} || !$profile->{capability_platform_profile_applied});
  $baseline=$initial;
  my $binding=lg_panel_light_binding($initial->{lg_generation},$initial->{picture_settings},$initial->{setting_contracts});
  $key=$binding->{wire_key};
  die "No readable and writable panel-light key was found in this picture mode.\n" if(!$key || !$binding->{writable});
  $contract=$initial->{setting_contracts}{$key}||{};
  die "Panel-light readback is not verifiable on this TV.\n" if(!$contract->{require_readback});
  $original=0+$initial->{picture_settings}{$key};
  $test=$original<100 ? $original+1 : $original-1;
  my ($valid)=lg_normalize_setting_value($contract,$test);
  die "No safe adjacent panel-light value is allowed by this TV's contract.\n" if(!$valid);
  @$result{qw(key original test)}=($key,$original,$test);
  $result->{write_attempted}=1;
  my $ack=$write->({%$context,settings=>{$key=>$test},readback_keys=>[$key,'pictureMode']});
  die(($ack->{message}||'The TV did not verify the test write')."\n") if(($ack->{status}||'') ne 'ok' || ($ack->{verification_state}||'') ne 'verified');
  $changed=$read->({%$context,keys=>[$key,'pictureMode']});
  die "Independent readback did not confirm the test value in the original context.\n"
   if(!_matches($changed,$context,$contract,$key,$test));
  $result->{test_verified}=1;
  1;
 };
 my $error=$@;
 if($result->{write_attempted}) {
  my $restore_ok=eval {
   my $ack=$write->({%$context,settings=>{$key=>$original},readback_keys=>[$key,'pictureMode']});
   $restored=$read->({%$context,keys=>[$key,'pictureMode']});
   die "Original panel-light value could not be independently confirmed.\n" if(!_matches($restored,$context,$contract,$key,$original));
   $result->{restored}=1;
   1;
  };
  $result->{restore_error}=$@ if(!$restore_ok);
 }
 $result->{status}='ok' if($ok && $result->{test_verified} && $result->{restored});
 $result->{message}=$result->{status} eq 'ok' ? "Panel-light change and restoration independently verified."
  : (!$result->{write_attempted} ? ($error||'Verification could not start.') : !$result->{restored}
   ? "Restoration could not be confirmed. Return to the original input and picture mode, and restore panel light to $original."
   : "The test did not pass; the original panel-light value was restored. ".($error||''));
 $result->{error}=$error if($error);
 $result->{generation}=$baseline->{lg_generation} if($baseline);
 $result->{context}={category=>'picture',signal_mode=>$request->{signal_mode},picture_mode=>$request->{picture_mode},tv_input=>$request->{tv_input},context_confirmed=>1} if($baseline);
 return $result;
}

sub _matches {
 my ($read,$context,$contract,$key,$expected)=@_;
 return 0 if(ref($read) ne 'HASH' || ($read->{status}||'') ne 'ok' || !$read->{settings_matrix}{context_confirmed}
  || ($read->{current_input}||'') ne $context->{tv_input}
  || ($read->{generation_profile}{capability_profile_hash}||'') ne $context->{expected_profile_hash}
  || !exists($read->{picture_settings}{$key}));
 return lg_setting_values_agree($contract,$expected,$read->{picture_settings}{$key});
}
1;
