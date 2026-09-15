use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('gamut-settings-test','test-token'); do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
my (@checks,@logs,@writes,$response);
local *main::_log=sub {push @logs,$_[0]};
local *main::_append_setting_check=sub {push @checks,$_[2];1};
local *main::_api=sub {$response};
local *main::_select_item_picture_mode=sub {1};
# Identity admission is covered in automation_runner_load.t; this fixture
# isolates post-LUT settings semantics after admission.
local *main::_verify_live_capability_profile=sub {1};
local *main::_apply_one_setting=sub {push @writes,$_[1];{status=>'ok'}};
sub item {
 return {signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>1},settings=>{colorGamut=>'auto',brightness=>50},checkpoints=>[{name=>'volume-done',status=>'done',verified=>JSON::PP::true,evidence=>{terminal_commit_verified=>JSON::PP::true}}]};
}
sub check {
 my ($item,$point,$overrides)=@_;@checks=();@logs=();
 $response={status=>'ok',picture_settings=>{pictureMode=>'filmMaker',colorGamut=>'wide',brightness=>50},%{$overrides||{}}};
 return main::_read_and_verify_settings(0,$item,$point);
}
for my $point (qw(c7 c7-confirm c7-repair c7-stable c8 c8-confirm c8-repair c8-stable c9 c10 resume-c8 resume-c9 resume-c10)) {
 my $r=check(item(),$point);
 is($r->{verified},1,"$point accepts the evidenced LUT-managed control");
 my ($gamut)=grep {$_->{key} eq 'colorGamut'} @checks;
 is($gamut->{result},'lut-managed','does not pretend the two raw values match');
 ok(!$gamut->{verified},'raw value is not falsely marked verified');
 is($gamut->{expected},'auto','requested pre-calibration value is retained');
 is($gamut->{observed},'wide','actual TV readback is retained');
 like($gamut->{reason},qr/3D LUT/i,'control ownership has an explanation');
 unlike(join("\n",@logs),qr/mismatch or failed/,'expected LUT ownership does not create an error log');
}
for my $point (qw(c1 c4 c5 c6 c6-confirm resume-c1)) {
 is(check(item(),$point)->{verified},'unverifiable',"$point records Auto/Wide as a warning, not a match");
 my ($gamut)=grep {$_->{key} eq 'colorGamut'} @checks;
 is($gamut->{result},'readback-warning','raw mismatch has a distinct warning result');
 ok(!$gamut->{verified},'warning is not verified');
 like(join('\n',@logs),qr/Warning: colorGamut.*Requested Auto; LG reported Wide/,'warning names the requested and reported values');
}
sub after_grey_item {
 my $i=item();
 $i->{checkpoints}=[
  {name=>'reset-and-reapply-verified',status=>'done',verified=>JSON::PP::true},
  {name=>'greyscale-done',status=>'done',verified=>JSON::PP::true},
 ];
 return $i;
}
for my $signal (qw(sdr hdr10)) {
 for my $point (qw(c6 c6-confirm c6-repair c6-stable c6-recovery resume-c6)) {
  my $i=after_grey_item();$i->{signal_format}=$signal;
  $i->{picture_mode}=$signal eq 'sdr'?'filmMaker':'hdrFilmMaker';
  my $r=check($i,$point,{picture_settings=>{pictureMode=>$i->{picture_mode},colorGamut=>'wide',brightness=>50}});
  is($r->{verified},1,"$signal $point accepts the expected calibration transition");
  my ($gamut)=grep {$_->{key} eq 'colorGamut'} @checks;
  is($gamut->{result},'expected-calibration-state','distinct informational result');
  ok(!$gamut->{verified} && !$r->{values}{colorGamut}{matched},'does not pretend raw values match');
  ok($r->{values}{colorGamut}{calibration_managed},'repair logic leaves the control alone');
  ok(!$r->{values}{colorGamut}{readback_warning},'does not create an unverifiable boundary');
  is_deeply([@$gamut{qw(expected observed)}],['auto','wide'],'retains raw diagnostic values');
  is_deeply($i->{warnings}||[],[],'no warning attached to the job');
  like(join('\n',@logs),qr/expected LG calibration state: Auto requested, Wide reported/,'concise informative log');
  unlike(join('\n',@logs),qr/Warning:|warning:|controlled by the verified 3D LUT/,'no warning or premature final 3D ownership claim');
 }
}
for my $case (
 ['no combined baseline',sub {shift @{$_[0]{checkpoints}}}],
 ['failed reset',sub {$_[0]{checkpoints}[0]{status}='interrupted'}],
 ['unverified reset',sub {$_[0]{checkpoints}[0]{verified}='unverifiable'}],
 ['no 1D upload',sub {pop @{$_[0]{checkpoints}}}],
 ['unverified 1D upload',sub {$_[0]{checkpoints}[1]{verified}='unverifiable'}],
 ['failed 1D upload',sub {$_[0]{checkpoints}[1]{status}='failed'}],
 ['later failed 1D upload',sub {push @{$_[0]{checkpoints}},{name=>'greyscale-done',status=>'failed',verified=>0}}],
 ['new reset invalidates old 1D',sub {push @{$_[0]{checkpoints}},{name=>'reset-and-reapply-verified',status=>'done',verified=>1}}],
 ['measurement-only job',sub {$_[0]{stages}{calibration}=0}],
 ['Dolby Vision not covered by this evidence',sub {$_[0]{signal_format}='dv'}],
) {
 my $i=after_grey_item();$case->[1]->($i);
 is(check($i,'c6')->{verified},'unverifiable',$case->[0].' cannot claim an expected transition');
 is((grep {$_->{key} eq 'colorGamut'} @checks)[0]{result},'readback-warning','unknown context keeps existing warning');
}
for my $point (qw(c1 c4 c5 c7 c8 c9 c10 resume-profile-baseline)) {
 is(check(after_grey_item(),$point)->{verified},'unverifiable',"$point cannot borrow 1D-only evidence for a different phase");
}
for my $override (
 {status=>'error',message=>'Socket failed'},
 {picture_settings=>{pictureMode=>'cinema',colorGamut=>'wide',brightness=>50}},
 {picture_settings=>{pictureMode=>'filmMaker',colorGamut=>'wide',brightness=>55}},
 {picture_settings=>{pictureMode=>'filmMaker',brightness=>50}},
 {picture_settings=>{pictureMode=>'filmMaker',colorGamut=>'extended',brightness=>50}},
) {
 is(check(after_grey_item(),'c6',$override)->{verified},0,'expected transition never hides real failures');
}
is(check(after_grey_item(),'c6',{unsupported_picture_keys=>{colorGamut=>1}})->{verified},0,'unsupported readback without matrix permission blocks after 1D');
is((grep {$_->{key} eq 'colorGamut'} @checks)[0]{result},'unverifiable','unsupported control not reclassified');
check(after_grey_item(),'c6');@writes=();
ok(main::_apply_and_verify(0,after_grey_item(),'c6-recovery',1),'recovery after 1D accepts expected state');
is_deeply(\@writes,['brightness'],'does not write Auto merely to satisfy readback after 1D');
{
 my $i=after_grey_item();check($i,'c6');@writes=();
 $response->{calibration_mode}=JSON::PP::false;
 my $boundary=main::_calibration_settings_boundary(0,$i,'c6');
 is($boundary->{verified},1,'whole stage gate completes without an unverified-stage warning');
 is_deeply(\@writes,[],'expected transition does not trigger any boundary repair');
 ok(!$i->{settings_recovery},'expected transition does not request recalibration');
}
{
 local *main::_append_setting_check=sub {0};
 is(check(after_grey_item(),'c6')->{verified},0,'unable to save expected-state evidence remains a failure');
}
{
 local *main::_apply_one_setting=sub {{status=>'error',message=>'TV rejected brightness'}};
 ok(!main::_apply_and_verify(0,after_grey_item(),'c6-recovery',1),'expected gamut never hides another setting write failure');
 like($::LAST_ERROR,qr/TV rejected brightness/,'write failure retains its cause');
}
for my $case (
 ['no calibration',sub {$_[0]{stages}{calibration}=0}],
 ['no committed checkpoint',sub {$_[0]{checkpoints}=[]}],
 ['unverified upload',sub {$_[0]{checkpoints}[0]{verified}='unverifiable'}],
 ['failed upload',sub {$_[0]{checkpoints}[0]{status}='interrupted'}],
 ['superseded upload',sub {push @{$_[0]{checkpoints}},{name=>'volume-done',status=>'interrupted',verified=>0}}],
 ['Dolby Vision profile is not a 3D LUT commit',sub {$_[0]{signal_format}='dv'}],
) {
 my $item=item();$case->[1]->($item);
 is(check($item,'c8')->{verified},'unverifiable',$case->[0].' warns without claiming LUT ownership');
 is((grep {$_->{key} eq 'colorGamut'} @checks)[0]{result},'readback-warning','no false LUT ownership');
}
for my $pair (['wide','auto'],['auto','extended'],['auto',undef]) {
 my $item=item();$item->{checkpoints}=[];$item->{settings}{colorGamut}=$pair->[0];
 is(check($item,'c6',{picture_settings=>{pictureMode=>'filmMaker',brightness=>50,colorGamut=>$pair->[1]}})->{verified},0,'other gamut differences still block');
}
{
 my $item=item();$item->{checkpoints}=[];
 is(check($item,'c6',{status=>'error',message=>'Socket failed'})->{verified},0,'cached Auto/Wide on failed read is an error');
 is(check($item,'c6',{picture_settings=>{pictureMode=>'cinema',colorGamut=>'wide',brightness=>50}})->{verified},0,'Auto/Wide cannot excuse wrong mode');
 is(check($item,'c6',{picture_settings=>{pictureMode=>'filmMaker',colorGamut=>'wide',brightness=>55}})->{verified},0,'Auto/Wide cannot excuse another setting');
}
my $hdr=item();$hdr->{signal_format}='hdr10';$hdr->{picture_mode}='hdrFilmMaker';
is(check($hdr,'c8',{picture_settings=>{pictureMode=>'hdrFilmMaker',colorGamut=>'wide',brightness=>50}})->{verified},1,'HDR10 verified LUT uses the same ownership rule');
for my $case (
 ['wrong picture mode',{picture_settings=>{pictureMode=>'cinema',colorGamut=>'wide',brightness=>50}}],
 ['real brightness drift',{picture_settings=>{pictureMode=>'filmMaker',colorGamut=>'wide',brightness=>55}}],
 ['missing gamut',{picture_settings=>{pictureMode=>'filmMaker',brightness=>50}}],
 ['unknown gamut value',{picture_settings=>{pictureMode=>'filmMaker',colorGamut=>'unexpected',brightness=>50}}],
 ['failed read containing cached matching values',{status=>'error',message=>'TV read failed',picture_settings=>{pictureMode=>'filmMaker',colorGamut=>'auto',brightness=>50}}],
) {
 is(check(item(),'c8',$case->[1])->{verified},0,$case->[0].' remains an error');
}
my $r=check(item(),'c8',{unsupported_picture_keys=>{colorGamut=>1}});
is($r->{verified},0,'unsupported readback without matrix permission blocks progression');
is((grep {$_->{key} eq 'colorGamut'} @checks)[0]{result},'unverifiable','unsupported readback is not relabelled LUT-managed');
check(item(),'c8');@writes=();
ok(main::_apply_and_verify(0,item(),'c8-recovery',1),'genuine recovery can reapply other controls');
is_deeply(\@writes,['brightness'],'post-LUT recovery never writes the bypassed gamut menu');
my $message=main::_settings_failure_message('c8',{values=>{brightness=>{expected=>50,observed=>55},colorGamut=>{expected=>'auto',observed=>'wide',calibration_managed=>1}}},1);
like($message,qr/brightness: requested 50, TV reported 55/,'recovery cause names the real mismatched control');
unlike($message,qr/colorGamut|three cycles/,'one read does not claim three attempts or a LUT mismatch');
done_testing();
