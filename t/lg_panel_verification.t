use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(lg_panel_light_binding);
use PGLGVerification qw(verify_lg_panel_light);
my $contract={require_readback=>1,write_decision=>'verified_readback_required',value_schema=>{type=>'integer',minimum=>0,maximum=>100},verify=>{comparator=>'numeric',tolerance=>0.1}};
my $binding=lg_panel_light_binding({model_name=>'OLED55G36LA'},{backlight=>18},{backlight=>$contract});
is($binding->{wire_key},'backlight','G3 maps the logical panel control to the key actually read');
is($binding->{label},'OLED Pixel Brightness','G3 label uses the menu terminology');
ok($binding->{writable},'readable panel key remains usable');
$binding=lg_panel_light_binding({model_name=>'OLED55C16LA'},{oledLight=>33},{oledLight=>$contract});
is($binding->{wire_key},'oledLight','alternate live key is preserved, not blindly rewritten');
$binding=lg_panel_light_binding({model_name=>'OLED55G36LA'},{backlight=>18},{backlight=>{%$contract,write_decision=>'blocked'}});
ok(!$binding->{writable},'explicit write block is not bypassed by alias binding');
is(lg_panel_light_binding({}, {}, {})->{wire_key},'','no value means no invented working key');

my $req={expected_profile_hash=>'a'x64,tv_input=>'hdmi4',picture_mode=>'filmMaker',signal_mode=>'sdr',reset_ddc_baseline=>1};
sub run_case {
 my (%opts)=@_;
 my $value=defined($opts{original})?$opts{original}:18;my @writes;my $reads=0;
 my $read=sub {
  my ($p)=@_;$reads++;
  ok(!exists($p->{reset_ddc_baseline}),'caller cannot smuggle reset flags into verification reads');
  my $settings={pictureMode=>'filmMaker',backlight=>$value};
  delete $settings->{backlight} if($opts{missing_read} && $reads==2);
  return {status=>'ok',current_input=>$opts{wrong_input}?'hdmi1':'hdmi4',settings_matrix=>{context_confirmed=>$opts{unconfirmed}?0:1},
   lg_generation=>{model_name=>'OLED55G36LA'},picture_settings=>$settings,setting_contracts=>{backlight=>$contract},
   generation_profile=>{capability_profile_hash=>$opts{wrong_hash}?'b'x64:'a'x64,capability_library_valid=>1,capability_platform_profile_applied=>$opts{unknown}?0:1}};
 };
 my $write=sub {
  my ($p)=@_;
  ok(!exists($p->{reset_ddc_baseline}),'caller cannot smuggle reset flags into verification writes');
  is($p->{expected_tv_input},'hdmi4','writes and restoration carry frozen input');
  is($p->{expected_profile_hash},'a'x64,'writes and restoration carry frozen firmware/profile');
  push @writes,$p->{settings}{backlight};
  die "Restore refused\n" if($opts{restore_fails} && @writes==2);
  $value=$p->{settings}{backlight};
  die "Response lost after applying value\n" if($opts{throw_after_write} && @writes==1);
  return {status=>'ok',verification_state=>'verified'};
 };
 my $r=verify_lg_panel_light($req,$read,$write);
 return ($r,\@writes,$value);
}
my ($r,$writes,$value)=run_case();
is($r->{status},'ok','full round trip passes');
is_deeply($writes,[19,18],'panel light increases one step and restores its original');
ok($r->{test_verified}&&$r->{restored},'change and restoration are independently confirmed');
($r,$writes,$value)=run_case(original=>100);
is_deeply($writes,[99,100],'upper bound uses a safe downward step');
for my $case (qw(wrong_hash wrong_input unconfirmed unknown)) {
 ($r,$writes)=run_case($case=>1);
 is($r->{status},'error',"$case blocks verification");is(scalar @$writes,0,"$case makes no writes");
}
for my $case (qw(throw_after_write missing_read)) {
 ($r,$writes,$value)=run_case($case=>1);
 is($r->{status},'error',"$case is not reported as a pass");
 is_deeply($writes,[19,18],"$case still restores original");
 ok($r->{restored},"$case confirms restoration independently");is($value,18,'original is retained');
}
($r,$writes,$value)=run_case(restore_fails=>1);
is($r->{status},'error','failed restoration cannot pass');
ok(!$r->{restored},'failed restoration is explicit');
like($r->{message},qr/restore panel light to 18/,'failure gives the exact recovery value');
done_testing();
