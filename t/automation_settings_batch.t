use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
make_path(PGAutomation::run_dir('batch-test').'/items');
{
 local @ARGV=('batch-test','token-for-batch-test');
 local $SIG{__WARN__}=sub {};
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
# TV setup reads every control first and rewrites only the ones that differ;
# the first pass writes each category in one helper session (the helper
# writes and reads back each control inside that session) and a readback
# verifies them together. Anything unverified takes the per-control path.
local *main::_log=sub {};
my @actions;local *main::_log_action=sub {push @actions,$_[0]};
local *main::_update_run=sub {$_[0]->({});{}};
local *main::_sleep_controlled=sub {1};
local *main::_append_setting_check=sub {1};
local *main::_verify_live_capability_profile=sub {1};
local *main::_select_item_picture_mode=sub {1};
my %tv;
sub reset_tv { %tv=(pictureMode=>'filmMaker',brightness=>40,contrast=>80,color=>45); }
my (@writes,$batch_reply,$reads);
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 if($path eq '/api/lg/picture-settings/set'){
  my $settings=$payload->{settings};
  push @writes,[sort keys %$settings];
  my $reply=keys(%$settings)>1 ? $batch_reply->($payload) : {status=>'ok',verification_state=>'verified'};
  if(($reply->{status}||'') eq 'ok') {
   my $verification=$reply->{setting_verification};
   for my $key (keys %$settings) {
    next if ref($verification) eq 'HASH' && (($verification->{$key}{status}||'') ne 'verified');
    $tv{$key}=$settings->{$key} if ($reply->{verification_state}||'verified') eq 'verified' || ref($verification) eq 'HASH';
   }
  }
  return $reply;
 }
 $reads++;
 return {status=>'ok',picture_settings=>{%tv}};
};
my $item=sub { {signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>0},settle_seconds=>0,settings=>{brightness=>50,contrast=>85,color=>50}} };

$batch_reply=sub {{status=>'ok',verification_state=>'verified'}};reset_tv();@writes=();$reads=0;@actions=();
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'three controls apply and verify');
is_deeply(\@writes,[['brightness','color','contrast']],'one write carries every mismatched picture control');
is($reads,2,'one read before the write and one after it');
ok(grep({/Applied 3 picture controls in one TV session/} @actions),'the batched write is announced');

reset_tv();@writes=();$reads=0;@actions=();
%tv=(%tv,brightness=>50,contrast=>85,color=>50);
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'controls already at their values verify without writing');
is_deeply(\@writes,[],'nothing is written when the readback already matches');
is($reads,1,'the pre-read is the verification; no second read');
ok(grep({/All 3 queued TV settings already match; nothing to write/} @actions),'the skipped write is announced');

reset_tv();@writes=();@actions=();$tv{contrast}=85;
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'a partly matching TV gets only the differing controls');
is_deeply(\@writes,[['brightness','color']],'the matching control is left alone');
ok(grep({/1 of 3 queued TV settings already match; writing the other 2/} @actions),'the partial pre-read is announced');

$batch_reply=sub {{status=>'error',message=>'TV refused the batch'}};reset_tv();@writes=();@actions=();
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'a refused batch still ends verified');
is_deeply(\@writes,[['brightness','color','contrast'],['brightness'],['color'],['contrast']],'a refused batch falls back to one control at a time');
ok(grep({/not confirmed; applying them one at a time/} @actions),'the fallback is announced');

$batch_reply=sub {{status=>'ok',verification_state=>'unverified',message=>'no readback'}};reset_tv();@writes=();
main::_apply_and_verify(0,$item->(),'settings-applied',1);
is(scalar(@writes),4,'an unverified batch without per-control evidence also falls back per control');

# A readback mismatch on one control keeps the controls that did verify.
$batch_reply=sub {{status=>'ok',verification_state=>'acknowledged_unverified',
 setting_verification=>{brightness=>{status=>'verified'},color=>{status=>'verified'},contrast=>{status=>'mismatch'}}}};
reset_tv();@writes=();@actions=();
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'a partly verified batch ends verified');
is_deeply(\@writes,[['brightness','color','contrast'],['contrast']],'only the unverified control is rewritten');
ok(grep({/not confirmed; 2 verified, applying the rest one at a time/} @actions),'kept controls are announced');

# A readback mismatch after the batch reaches the existing retry cycle.
$batch_reply=sub {{status=>'ok',verification_state=>'verified'}};reset_tv();@writes=();
my $stale=1;my $inner=\&main::_api;
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 return $inner->(@_) if $path eq '/api/lg/picture-settings/set';
 my $r=$inner->(@_);$r->{picture_settings}{contrast}=80 if $tv{contrast}==85 && $stale-- > 0;return $r;
};
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'a mismatch after the batch is repaired by the second cycle');
is_deeply($writes[0],['brightness','color','contrast'],'second cycle starts from the batched first cycle');
is(scalar(@writes),4,'the second cycle uses the per-control path');

local *main::_api=$inner;reset_tv();@writes=();
ok(main::_apply_and_verify(0,{%{$item->()},settings=>{brightness=>50}},'settings-applied',1),'a single control applies');
is_deeply(\@writes,[['brightness']],'a lone control is not batched');
done_testing();
