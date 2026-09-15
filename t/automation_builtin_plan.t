use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{
 local @ARGV=('reference-payload-test','reference-payload-test-token');
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}

my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
plan skip_all => 'Node is required for the built-in template behavior tests' if !$node;
my $json = `"$node" "$Bin/js/automation_builtin_plan.js" 2>&1`;
is($? >> 8, 0, 'template selection, insertion, persistence and isolation checks pass') or diag($json);
my $items = eval { decode_json($json) };
BAIL_OUT('JavaScript did not return template items') if ref($items) ne 'ARRAY';
is(scalar(@$items), 6, 'all six reference modes are represented');
for my $item (@$items) {
 my $normal = main::webui_automation_normalize_item($item);
 my $name = $item->{name};
 ok(main::webui_automation_mode_available({platform_year=>2025}, $normal->{signal_format}, $normal->{picture_mode}), "$name is in the backend mode map");
 ok(main::webui_automation_calibration_mode_ok($normal->{picture_mode}), "$name is accepted as a calibration mode");
 # The server intentionally represents an inapplicable shadow fix as numeric 0.
 $item->{calibration}{shadow_fix}=0 if $item->{signal_format} ne 'hdr10';
 for my $key (qw(target_gamma tv_gamma_follows_target target_gamut target_delta_e target_white settings panel_light color_format max_bpc rgb_quant_range calibration)) {
  is_deeply($normal->{$key}, $item->{$key}, "$name preserves $key through server normalization");
 }
 is($normal->{template_id}, 'reference-settings-v5', "$name keeps reference version in saved recipes");
 is_deeply($normal->{stages},{pre_readings=>0,calibration=>1,post_readings=>0,apply_all=>1},"$name applies to all inputs without optional sweeps after server normalization");
 is_deeply(main::_stages($normal),{pre=>0,calibration=>1,post=>0,apply_all=>1},"$name executes Apply to All without optional sweeps");
 my $sdr=$normal->{signal_format} eq 'sdr';
 main::_record_setup_luminance($normal,419.71) if $sdr;
 my $grey=main::_grey_payload($normal);
 is($grey->{target_gamma},$sdr?$item->{target_gamma}:'2.2',"$name sends the correct 1D calibration gamma to the worker");
 is($grey->{target_delta_e},0.5,"$name sends delta E 0.5 to the 1D worker");
 ok($grey->{dark_detail},"$name enables Dark Detail in the worker");
 ok(scalar(grep {abs($_->{ire}-3.7)<0.001} @{$grey->{steps}}),"$name includes Dark Detail filler patches");
 if ($sdr) {
  is($grey->{target_luminance},419.71,"$name uses measured fixed-panel white, not the dormant 100-nit target");
 }
 if ($normal->{signal_format} ne 'dv') {
  my $volume=main::_three_d_payload($normal,{},undef);
  is($volume->{target_gamma},$item->{target_gamma},"$name retains its SDR curve or HDR PQ target for the 3D worker");
  is($volume->{method},$sdr?'hybrid':'matrix',"$name sends the intended volume profiling method");
 }
}
is_deeply(main::_stages({}),{pre=>0,calibration=>1,post=>0,apply_all=>1},'runner missing-stage fallback leaves sweeps off without changing other defaults');
is_deeply(main::_stages({pre_readings=>1,post_readings=>1}),{pre=>1,calibration=>1,post=>1,apply_all=>1},'runner preserves explicit legacy sweep flags');
done_testing();
