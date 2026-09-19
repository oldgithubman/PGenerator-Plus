use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('apply-all-test','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my ($response,$saved,$checkpoint,$settings_verified,@logs);
local *main::_api=sub {$response};
local *main::_read_and_verify_settings=sub {{verified=>$settings_verified}};
local *main::_write_artifact=sub {$saved=$_[1];1};
local *main::_log=sub {push @logs,$_[0]};
local *main::_refresh_control=sub {};
local *main::_checkpoint_exists=sub {0};
local *main::_update_item_snapshot=sub {1};
local *main::_update_run=sub {{}};
local *main::_checkpoint_record=sub {$checkpoint={verified=>$_[3],evidence=>$_[4]};$checkpoint};
sub run_case {
 my ($signal,$overrides,$setting_check)=@_;@logs=();$checkpoint=undef;
 $settings_verified=$setting_check//1;
 $response={status=>'ok',confirmed=>0,acknowledged=>0,transport=>'luna',confirmation_unavailable=>1,
  readback_error=>'500 Application error: Some keys are not allowed for the request. ( applyToAllInput )',%{$overrides||{}}};
 my $item={signal_format=>$signal,picture_mode=>'filmMaker',settings=>{},warnings=>[]};
 my $ok=main::_stage(0,$item,'apply-all-done',sub {main::_apply_all(0,$item)});
 return ($ok,$item);
}
for my $signal(qw(sdr hdr10 dv)) {
 my ($ok,$item)=run_case($signal);
 ok($ok,"$signal permits dispatch without unsupported confirmation");
 is_deeply($item->{warnings},[],'does not mark an otherwise completed job with warnings');
 is($saved->{outcome},'sent-unconfirmed','artifact distinguishes dispatch from verified completion');
 ok(!$saved->{confirmed}&&!$saved->{acknowledged},'retains truthful confirmation and bridge receipt semantics');
 is($checkpoint->{verified},'unverifiable','checkpoint does not claim a verified copy');
 like(join('\n',@logs),qr/Apply to All Inputs sent - confirmation unavailable on this TV/,'activity log explains informational result');
}
for my $case (
 {confirmation_unavailable=>0,readback_error=>'timeout'},
 {confirmation_unavailable=>0,readback_error=>''},
 {transport=>'unknown'},
 {error_code=>'unexpected-readback-error'},
) {
 my ($ok,$item)=run_case('sdr',$case);
 ok($ok,'ordinary unconfirmed outcome can still continue');
 is_deeply($item->{warnings},['apply-all-unverified','apply-all-done-unverified'],'other confirmation problems still warn');
}
{
 my ($ok,$item)=run_case('sdr',{},'unverifiable');
 ok($ok,'known unsupported action readback does not interrupt an unverified setting read');
 is_deeply($item->{warnings},['apply-all-done-unverified'],'unverified picture settings remain a warning');
}
for my $case ({status=>'error',message=>'TV rejected command'},{status=>'error',message=>'Connection lost'},{error_code=>'lg-calibration-session-held'},{error_code=>'apply-all-inputs-unsupported'}) {
 my ($ok,$item)=run_case('sdr',$case);
 ok(!$ok,'real dispatch/guard failure is not excused by capability flag');
 ok($item->{failure},'failure is recorded on the stage');
}
{
 my ($ok,$item)=run_case('sdr',{confirmed=>1,confirmation_unavailable=>0,readback=>'done',readback_error=>''});
 ok($ok,'confirmed apply still succeeds');is($checkpoint->{verified},1,'genuine confirmation remains verified');
}
{
 local *main::_write_artifact=sub {0};
 my ($ok)=run_case('sdr');ok(!$ok,'failed persistence still fails');
}
done_testing();
