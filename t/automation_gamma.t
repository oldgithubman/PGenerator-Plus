use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('gamma-test','test-token'); do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
my (@checks,@writes,@logs,$response);
local *main::_log=sub {push @logs,$_[0]};
local *main::_append_setting_check=sub {push @checks,$_[2];1};
local *main::_api=sub {push @writes,$_[2] if $_[1]=~/\/set$/; $response};
local *main::_select_item_picture_mode=sub {1};
local *main::_verify_live_capability_profile=sub {1}; # admitted-job gamma semantics
sub item {
 return {signal_format=>'sdr',picture_mode=>'filmMaker',settings=>{gamma=>'high2',brightness=>50},stages=>{calibration=>1},
  checkpoints=>[{name=>'greyscale-done',status=>'done',verified=>1}]};
}
sub check {
 my ($i,$point,$override)=@_;@checks=();@logs=();
 $response={status=>'ok',picture_settings=>{pictureMode=>'filmMaker',gamma=>'medium',brightness=>50},%{$override||{}}};
 return main::_read_and_verify_settings(0,$i,$point);
}
for my $pair (['1.9','low'],['2.2','medium'],['2.4','high1'],['bt1886','high2'],['BT.1886','high2']) {
 ok(main::_value_agrees(@$pair,'gamma'),'friendly gamma agrees with its wire enum');
 @writes=();$response={status=>'ok'};
 main::_apply_one_setting(item(),'gamma',$pair->[0]);
 is($writes[0]{settings}{gamma},$pair->[1],'writes LG enum, not UI label');
}
ok(!main::_value_agrees('high1','high2','gamma'),'power 2.4 is not aliased to BT.1886');
for my $point(qw(c6 c6-confirm c6-repair c6-stable c6-recovery c7 c8 c9 c10 resume-c6 resume-c8)) {
 is(check(item(),$point)->{verified},1,"$point accepts verified 1D ownership");
 my ($gamma)=grep {$_->{key} eq 'gamma'} @checks;
 is($gamma->{result},'lut-managed','raw menu value is not a false matched reading');
 is_deeply([@$gamma{qw(expected observed)}],['high2','medium'],'retains setup and observed values');
 like($gamma->{reason},qr/verified 1D LUT/,'explains why menu gamma does not represent the LUT target');
 like(join('\n',@logs),qr/TV Gamma controlled by the verified 1D LUT/,'logging identifies correct LUT owner');
}
for my $point(qw(c1 c4 c5 resume-c4 resume-profile-baseline)) {
 is(check(item(),$point)->{verified},0,"$point still verifies setup gamma strictly");
}
for my $change (
 sub {$_[0]{checkpoints}=[]},
 sub {$_[0]{checkpoints}[0]{verified}='unverifiable'},
 sub {$_[0]{checkpoints}[0]{status}='failed'},
 sub {push @{$_[0]{checkpoints}},{name=>'greyscale-done',status=>'failed',verified=>0}},
 sub {push @{$_[0]{checkpoints}},{name=>'reset-and-reapply-verified',status=>'done',verified=>1}},
 sub {$_[0]{stages}{calibration}=0},
 sub {$_[0]{signal_format}='hdr10'},
 sub {$_[0]{signal_format}='dv'},
) {
 my $i=item();$change->($i);is(check($i,'c6')->{verified},0,'no ownership exemption without valid SDR 1D evidence');
}
for my $override (
 {status=>'error',message=>'TV disconnected'},
 {picture_settings=>{pictureMode=>'cinema',gamma=>'medium',brightness=>50}},
 {picture_settings=>{pictureMode=>'filmMaker',gamma=>'medium',brightness=>55}},
 {picture_settings=>{pictureMode=>'filmMaker',brightness=>50}},
 {picture_settings=>{pictureMode=>'filmMaker',gamma=>'unknown',brightness=>50}},
) {is(check(item(),'c6',$override)->{verified},0,'LUT ownership cannot hide failed reads, wrong mode, missing/unknown values or brightness drift');}
is(check(item(),'c6',{unsupported_picture_keys=>{gamma=>1}})->{verified},0,'unsupported readback without matrix permission blocks progression');
check(item(),'c6');@writes=();
ok(main::_apply_and_verify(0,item(),'c6-recovery',1),'settings recovery succeeds with verified 1D ownership');
is_deeply([map {sort keys %{$_->{settings}}} @writes],['brightness'],'recovery never rewrites bypassed Gamma');
{local *main::_append_setting_check=sub {0};is(check(item(),'c6')->{verified},0,'failed evidence storage still fails the boundary');}
done_testing();
