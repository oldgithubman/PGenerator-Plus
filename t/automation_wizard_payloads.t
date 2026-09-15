use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
{
 local @ARGV=('wizard-payload-test','wizard-payload-test-token');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
for my $case (['hybrid',3,63],['hybrid',5,161],['hybrid',9,765],['skeleton',5,45],['lattice',3,27],['lattice',5,125],['lattice',9,729]) {
 my ($method,$size,$count)=@$case;
 my $patches=main::_lattice_patches({calibration=>{method=>$method,lattice_size=>$size}});
 is(scalar(@$patches),$count,"$method $size has the wizard's exact patch count");
 ok(!scalar(grep { !defined($_->{name}) || $_->{name}!~m{^[\d.]+/[\d.]+/[\d.]+$} } @$patches),'all volume patches use the worker percent-triplet contract');
}
my $legacy=main::_lattice_patches({calibration=>{lattice_patches=>[{r=>25,g=>50,b=>75}]}});
is_deeply([@{$legacy->[0]}{qw(r_pct g_pct b_pct)}],[25,50,75],'legacy percent coordinates are converted to worker keys');
my $sdr={signal_format=>'sdr',color_format=>'0',signal_range=>'2',max_bpc=>10,settings=>{backlight=>80},panel_light=>{policy=>'fixed',key=>'backlight'},calibration=>{target_delta_e=>0.5,target_gamma=>'srgb'}};
ok(main::_record_setup_luminance($sdr,419.71),'fixed brightness captures the actual setup white');
my $payload=main::_grey_payload($sdr);
is($payload->{target_delta_e},0.5,'the explicit 1D LUT delta target reaches the worker');
is($payload->{target_gamma},'srgb','sRGB wizard target reaches the worker');
is($payload->{target_luminance},419.71,'fixed value does not silently calibrate to 100 nits');
is($payload->{setup_luminance_reference},419.71,'measured setup white reaches the worker');
is($payload->{headroom_target_luminance},419.71,'RGB has no super-white headroom');
ok(!scalar(grep { $_->{ire}>100 } @{$payload->{steps}}),'RGB excludes the YCbCr-only super-white ladder');
my ($five)=grep { $_->{ire}==5 } @{$payload->{steps}};
is($five->{r},52,'SDR RGB 10-bit uses the shared wizard code quantization');
ok($payload->{lg_autocal_26_full_ddc_spine},'wizard full DDC spine is enabled');
my $tv={%$sdr,color_format=>'1',signal_range=>'1',calibration=>{target_delta_e=>0.3,target_gamma=>'bt1886',dark_detail=>1}};
ok(main::_record_setup_luminance($tv,120),'target-policy actual settled white is captured');
$payload=main::_grey_payload($tv);
cmp_ok($payload->{headroom_target_luminance},'>',120,'YCbCr Limited derives a super-white headroom target');
my ($peak)=grep { $_->{ire}==109 } @{$payload->{steps}};
is($peak->{r},1023,'109% YCbCr white does not exceed the 10-bit code domain');
ok(scalar(grep { $_->{ire}==3.7 } @{$payload->{steps}}),'Dark Detail supplies filler patches to the worker');
for my $signal ('hdr10','dv') {
 my $item={signal_format=>$signal,calibration=>{target_delta_e=>0.4,target_gamma=>'st2084',dark_detail=>1}};
 my $body=main::_grey_payload($item);
 is($body->{target_gamma},'2.2',"$signal uses the pinned HDR calibration gamma");
 is($body->{target_delta_e},0.4,"$signal retains the selected 1D target");
 ok(!exists($body->{setup_luminance_reference}),"$signal skips SDR setup luminance");
 ok(scalar(grep { $_->{ire}==55 } @{$body->{steps}}),"$signal includes HDR Dark Detail fillers");
}
ok(!main::_record_setup_luminance($sdr,0),'missing/black setup white cannot pass');
my $volume=main::_three_d_payload({%$sdr,settings=>{smoothGradation=>'off',sharpness=>0,brightness=>50,colorGamut=>'auto'}},{},undef);
is_deeply($volume->{automation_processing_settings},{smoothGradation=>'off',sharpness=>0},'3D worker receives only explicitly requested processing controls');
is($sdr->{settings}{backlight},80,'luminance capture never changes a fixed brightness value');
done_testing();
