use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('feedback-test','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my (@calls,@checks,@logs,$mode,$gamut,$read_error,$write_error);
local *main::_verify_live_capability_profile=sub {1}; # admitted-job feedback ordering
local *main::_log=sub {push @logs,$_[0]};
local *main::_sleep_controlled=sub {push @calls,'settle';1};
local *main::_append_setting_check=sub {push @checks,{%{$_[2]},checkpoint=>$_[1]};1};
local *main::_api=sub {
 my ($method,$path,$p)=@_;
 if($path eq '/api/lg/picture-settings/set') {
  push @calls,'write:'.join(',',sort keys %{$p->{settings}});
  return $write_error ? {status=>'error',message=>'Write rejected'} : {status=>'ok'};
 }
 if($path eq '/api/lg/picture-settings') {
  push @calls,'read:'.join(',',@{$p->{keys}});
  return {status=>$read_error?'error':'ok',message=>$read_error?'Read failed':'',picture_settings=>{pictureMode=>$mode,colorGamut=>$gamut,brightness=>50}};
 }
 die "Unexpected $path";
};
sub item {return {signal_format=>'sdr',picture_mode=>'cinema',settings=>{colorGamut=>'auto',brightness=>50},settle_seconds=>0,stages=>{calibration=>1}};}
sub reset_fixture {@calls=();@checks=();@logs=();$mode='cinema';$gamut='auto';$read_error=0;$write_error=0;}
reset_fixture();
ok(main::_apply_and_verify(0,item(),'c1'),'setup succeeds');
is_deeply(\@calls,['write:pictureMode','settle','read:pictureMode','write:brightness','write:colorGamut','read:brightness,colorGamut,pictureMode'],'mode confirmed before settings; all settings read back immediately after writes');
is($checks[0]{checkpoint},'c1-mode','mode confirmation saved separately');
like(join('\n',@logs),qr/Picture mode confirmed: cinema.*Applying 2 queued TV settings to cinema.*TV settings readback: 3\/3 matched/s,'feedback names the confirmed mode, writes, then measured readback result');
is(scalar(grep {/TV settings readback: 3\/3 matched/} @logs),1,'one settings outcome instead of duplicate all-matched messages');
for my $case (qw(wrong-mode read-failure write-failure)) {
 reset_fixture();$mode='filmMaker' if $case eq 'wrong-mode';$read_error=1 if $case eq 'read-failure';$write_error=1 if $case eq 'write-failure';
 ok(!main::_apply_and_verify(0,item(),'c4'),"$case blocks before control writes");
 ok(!grep(/^write:(brightness|colorGamut)$/, @calls),"$case never applies settings in an unconfirmed mode");
}
reset_fixture();$gamut='wide';my $i=item();
is(main::_apply_and_verify(0,$i,'c5'),'unverifiable','Auto/Wide warning permits calibration with explicit uncertainty');
is(scalar(grep {$_ eq 'write:colorGamut'} @calls),1,'warning does not trigger repeated setting writes');
is(scalar @{$i->{warnings}},1,'warning persists on the job');
is((grep {$_->{key} eq 'colorGamut'} @checks)[0]{observed},'wide','raw feedback retained');

# Upgrade only the actual sole-gamut pause; never trust its free-text message.
my $dir=PGAutomation::item_dir('feedback-test',0);
sub saved_checks {
 my ($other_mismatch)=@_;my @lines;
 for my $point (qw(c6 c6-confirm)) {
  for my $key (qw(pictureMode brightness colorGamut)) {
   my $expected=$key eq 'pictureMode'?'cinema':$key eq 'brightness'?50:'auto';
   my $bad=$key eq 'colorGamut'||($other_mismatch&&$key eq 'brightness');
   push @lines,JSON::PP::encode_json({checkpoint=>$point,key=>$key,expected=>$expected,observed=>$key eq 'colorGamut'?'wide':$bad?55:$expected,result=>$bad?'mismatch':'verified',verified=>$bad?JSON::PP::false:JSON::PP::true,operation=>'readback'})."\n";
  }
 }
 open(my $fh,'>',$dir.'/settings-checks.ndjson') or die $!;print $fh @lines;close($fh);
}
PGAutomation::write_json_atomic($dir.'/calibration/grey-state.json',{status=>'complete',final_1d_lut_upload_verified=>JSON::PP::true},0664);
sub interrupted_item {
 return {%{item()},settings_recovery=>{point=>'c6',resume_from=>'greyscale-done'},checkpoints=>[map {{name=>$_,status=>'done',verified=>1}} qw(reset-and-reapply-verified panel-light-settled greyscale-done)]};
}
saved_checks(0);$i=interrupted_item();
ok(main::_gamut_warning_only_recovery(0,$i),'saved sole-gamut evidence and committed upload permit retrying the gate');
main::_prepare_resume(0,$i,1);
ok(main::_checkpoint_exists($i,'greyscale-done'),'resume retains completed 1D');
ok(!exists($i->{settings_recovery}),'review consumed by resume');
saved_checks(1);$i=interrupted_item();
ok(!main::_gamut_warning_only_recovery(0,$i),'another setting mismatch cannot bypass recalibration');
saved_checks(0);$i->{settings}{brightness}=55;
ok(!main::_gamut_warning_only_recovery(0,$i),'changed job settings cannot reuse stale proof');
$i=interrupted_item();PGAutomation::write_json_atomic($dir.'/calibration/grey-state.json',{status=>'error'},0664);
ok(!main::_gamut_warning_only_recovery(0,$i),'missing verified upload cannot preserve 1D');
done_testing();
