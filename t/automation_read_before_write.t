use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
make_path(PGAutomation::run_dir('rbw-test').'/items');
{ local @ARGV=('rbw-test','test-token'); local $SIG{__WARN__}=sub {}; do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
# Every settings pass reads the TV first and writes only what differs. The
# compatibility signature is taken from that same read when it is a single
# picture-category read; otherwise the explicit check still spawns.
local *main::_log=sub {};
my @actions;local *main::_log_action=sub {push @actions,$_[0]};
local *main::_update_run=sub {$_[0]->({});{}};
local *main::_sleep_controlled=sub {1};
local *main::_append_setting_check=sub {1};
local *main::_select_item_picture_mode=sub {1};
my $hash='a' x 64;
my (%tv,@writes,@reads,$live_hash);
sub reset_tv { %tv=(pictureMode=>'hdrFilmMaker',brightness=>50,contrast=>85,energySaving=>'off',gamma=>'medium',colorGamut=>'auto'); @writes=();@reads=();@actions=();$live_hash=$hash; }
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 if($path eq '/api/lg/picture-settings/set'){
  push @writes,[sort keys %{$payload->{settings}}];
  $tv{$_}=$payload->{settings}{$_} for keys %{$payload->{settings}};
  return {status=>'ok',verification_state=>'verified'};
 }
 if($path eq '/api/lg/picture-settings'){
  push @reads,$payload;
  my %settings=map { exists($tv{$_}) ? ($_=>$tv{$_}) : () } @{$payload->{keys}||[]};
  return {status=>'ok',picture_settings=>\%settings,current_input=>'hdmi4',generation_profile=>{capability_profile_hash=>$live_hash}};
 }
 return {status=>'error',message=>"unexpected $path"};
};
sub item { return {signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',tv_input=>'hdmi4',stages=>{calibration=>1},settle_seconds=>0,
 settings=>{brightness=>50,contrast=>85},capability_profile=>{hash=>$hash,id=>'p1'},%{$_[0]||{}}}; }
my $profile_reads=sub { scalar grep { @{$_->{keys}||[]}==1 && $_->{keys}[0] eq 'pictureMode' && ($_->{picture_mode}||'') ne '' } @reads };

reset_tv();
is(main::_apply_and_verify(0,item(),'c1',1),1,'a TV already at every value verifies');
is_deeply(\@writes,[],'without a write');
is(scalar(@reads),1,'one read in total');
is($profile_reads->(),0,'the compatibility signature came from that read, not a second spawn');

reset_tv();$live_hash='b' x 64;
ok(!main::_apply_and_verify(0,item(),'c1',1),'a changed compatibility signature still fails');
like($::LAST_ERROR,qr/compatibility signature/,'with the signature reason');
is_deeply(\@writes,[],'and writes nothing');

reset_tv();
my $two=item({settings=>{brightness=>50,energySaving=>'off'},hazard_capabilities=>{energySaving=>{category=>'general'}}});
is(main::_apply_and_verify(0,$two,'c1',1),1,'two categories verify');
is($profile_reads->(),1,'a multi-category pre-read cannot carry the signature, so the explicit check spawns');
is_deeply(\@writes,[],'still no writes');

reset_tv();delete $tv{contrast};
is(main::_apply_and_verify(0,item(),'c1',1),1,'a control the TV did not return is written');
is_deeply(\@writes,[['contrast']],'only that control');

reset_tv();
my $acked=item();$acked->{best_available_write_ack}{brightness}={expected=>50,profile_hash=>$hash};
main::_apply_and_verify(0,$acked,'c1',1);
ok(!exists($acked->{best_available_write_ack}{brightness}),'a matching readback clears an earlier accepted-without-readback acknowledgement');

reset_tv();$tv{colorGamut}='wide';
my $gamut=item({settings=>{brightness=>50,colorGamut=>'auto'}});
is(main::_apply_and_verify(0,$gamut,'c1',1),1,'a gamut left Wide by an earlier calibration is corrected');
is_deeply(\@writes,[['colorGamut']],'by writing it');
is_deeply($gamut->{warnings}||[],[],'without turning the pre-write state into a job warning');
ok(grep({/1 of 2 queued TV settings already match; writing the other 1/} @actions),'the pre-read is announced');

# LUT-managed controls are never rewritten, whatever the pre-read says.
reset_tv();$tv{brightness}=40;$tv{pictureMode}='filmMaker';
my $managed=item({signal_format=>'sdr',picture_mode=>'filmMaker',settings=>{gamma=>'high2',brightness=>50},
 checkpoints=>[{name=>'greyscale-done',status=>'done',verified=>1}]});
main::_apply_and_verify(0,$managed,'c6-recovery',1);
is_deeply(\@writes,[['brightness']],'gamma owned by the verified 1D LUT is left alone');

# After the SDR picture reset every menu control is back at factory values;
# c4 writes without a pre-read, once, and later passes read again.
local *main::_begin_run=sub {{status=>'ok',run_id=>'lg-run'}};
local *main::_verify_live_capability_profile=sub {1};
my $orig_api=\&main::_api;
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 return {status=>'ok'} if $path eq '/api/lg/picture-settings/reset';
 return {status=>'error',message=>'stop here'} if $path eq '/api/lg/picture-settings/set' && $payload->{reset_ddc_baseline};
 return {status=>'error',message=>'stop here'} if $path=~m{calman-reset$};
 return $orig_api->(@_);
};
reset_tv();$tv{pictureMode}='filmMaker';
my $sdr=item({signal_format=>'sdr',picture_mode=>'filmMaker'});
ok(!main::_reset_for_calibration(0,$sdr),'the reset stops at the stubbed DDC write, after the picture reset');
@writes=();@reads=();
is(main::_apply_and_verify(0,$sdr,'c4'),1,'c4 after an SDR picture reset verifies');
ok(!grep({$_->{keys} && @{$_->{keys}}>1 && !grep {$_ eq 'pictureMode'} @{$_->{keys}}} @reads[0..$#reads-1]),'no pre-read before the writes');
is_deeply($writes[0],['brightness','contrast'],'every control is written although the TV already matched');
@writes=();
is(main::_apply_and_verify(0,$sdr,'c4'),1,'a second c4 pass');
is_deeply(\@writes,[],'reads first again: the skip was consumed');
reset_tv();
my $hdr=item();
ok(!main::_reset_for_calibration(0,$hdr),'the HDR10 reset stops at the stubbed calman reset');
@writes=();
main::_apply_and_verify(0,$hdr,'c4');
is_deeply(\@writes,[],'an HDR10 reset leaves menu values alone, so c4 reads first and writes nothing');
done_testing();
