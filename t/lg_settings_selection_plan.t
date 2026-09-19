use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(lg_settings_selection_plan);
my %context=(root=>"$Bin/../usr/share/PGenerator/tv",store_root=>tempdir(CLEANUP=>1),category=>'picture',signal_mode=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi4');
my $g3={model_name=>'OLED55G36LA',platform_model=>'W23O',software_version=>'23.25.55'};
my $c1={model_name=>'OLED65C1PUB',platform_model=>'W21O'};
my $requested={contrast=>85,brightness=>50,gamma=>'bt1886',backlight=>95,tint=>0};
my $p=lg_settings_selection_plan($g3,$requested,{picture_settings=>{backlight=>18}},%context);
ok($p->{known},'G3 uses known shared platform');
is($p->{automatic}{contrast},85,'reference contrast is not replaced by current values');
is($p->{automatic}{gamma},'high2','reference gamma normalized by matrix');
is($p->{automatic}{tint},0,'zero preserved');
is($p->{panel_light}{label},'OLED Pixel Brightness','human panel label');
is($p->{panel_light}{wire_key},'backlight','native API binding');
ok($p->{panel_light}{target_available},'readable brightness supports targeting');
ok(!exists($p->{automatic}{backlight}),'panel policy is separate from optional pins');
for my $identity ($g3,$c1,{model_name=>'OLED55C16LA',platform_model=>'W21O'}) {
 my $plan=lg_settings_selection_plan($identity,$requested,{},%context);
 is($plan->{panel_light}{wire_key},'backlight','known TV matrix resolves control without model-specific editor code');
 is($plan->{panel_light}{source},'tv_matrix','inactive/unprobed context identified honestly');
}
my $refusal='There is no matched settings for requested keys';
$p=lg_settings_selection_plan($c1,$requested,{unsupported_picture_keys=>{gamma=>$refusal,backlight=>$refusal}},%context);
ok(exists($p->{manual}{gamma}),'proven C1 read refusal becomes a manual reference instruction');
ok($p->{panel_light}{writable},'C1 reviewed SDR fixed-write policy retained');
ok(!$p->{panel_light}{target_available},'write-only brightness cannot run measured targeting');
for my $case (['hdr10','hdrCinema'],['dv','dolbyVisionFilmMaker']) {
 my $plan=lg_settings_selection_plan($c1,{brightness=>50,backlight=>100,noiseReduction=>'off'},
  {unsupported_picture_keys=>{brightness=>$refusal,backlight=>$refusal,noiseReduction=>$refusal}},%context,signal_mode=>$case->[0],picture_mode=>$case->[1]);
 ok(exists($plan->{automatic}{brightness}),"$case->[0] editor retains matrix-authorized fixed write");
 ok($plan->{panel_light}{writable}&&!$plan->{panel_light}{target_available},"$case->[0] panel can be fixed but not automatically targeted");
 ok($plan->{manual}{noiseReduction},"$case->[0] extra unreadable controls stay manual");
}
$p=lg_settings_selection_plan($g3,$requested,{unsupported_picture_keys=>{backlight=>$refusal}},%context);
ok(!$p->{panel_light}{writable},'strict-readback TV cannot inherit C1 write waiver');
$p=lg_settings_selection_plan({},$requested,{},%context);
ok(!$p->{known}&&!$p->{panel_light}{wire_key}&&!$p->{panel_light}{target_available},'unknown TV never gets a guessed panel binding');
is_deeply($p->{automatic},{},'unknown TV gets no automatic reference writes');
$p=lg_settings_selection_plan({model_name=>'OLED65C26LA',platform_model=>'W22O'},{contrast=>101,gamma=>'bt1886'}, {},%context,signal_mode=>'hdr10',picture_mode=>'hdrCinema');
ok($p->{blocked}{contrast}&&$p->{blocked}{gamma},'range-invalid and signal-inapplicable settings are blocked');
$p=lg_settings_selection_plan($g3,{gamma=>'bt1886'},{unsupported_picture_keys=>{gamma=>'Socket disconnected'}},%context);
ok(!$p->{manual}{gamma},'transport failures never establish a manual-only capability');
done_testing();
