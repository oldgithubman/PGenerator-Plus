#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Find qw(find);
use Test::More;

use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(
 clear_lg_capability_cache lg_platform_token lg_recipe
 resolve_lg_capabilities validate_lg_library
);

my $root="$Bin/../usr/share/PGenerator/tv";
my $validation=validate_lg_library($root);
ok($validation->{ok},'the shipped LG capability library validates')
 or diag(join("\n",@{$validation->{errors}||[]}));
is($validation->{version},'2026.09.15.5','library version is explicit');
is(lg_platform_token('HE_DTV_W23O_AFABATAA'),'W23O','internal platform token is extracted');
is(lg_platform_token('W26G'),'W26G','bare platform token is accepted');

open(my $fh,'<',"$Bin/fixtures/lg-capabilities/platform-cases.json") or die $!;
local $/; my $fixture_text=<$fh>; close($fh);
my $fixture=JSON::PP->new->decode($fixture_text);
foreach my $case (@{$fixture->{cases}}) {
 my $platform=$case->{platform};
 my $resolved=resolve_lg_capabilities({platform_model=>"HE_DTV_${platform}_AFABATAA"},root=>$root);
 is($resolved->{identity}{platform_token},$platform,"$platform identity is retained");
 is($resolved->{data}{identity}{model_year},$case->{year},"$platform resolves to model year $case->{year}");
 is($resolved->{data}{calibration}{three_d_lut}{grid_size},$case->{grid},"$platform resolves to $case->{grid}-point 3D LUT geometry");
 is($resolved->{data}{calibration}{dolby_vision_configuration}{format_generation},2019,"$platform uses the 2019 Dolby Vision configuration format");
 is($resolved->{match_status},'platform',"$platform reports a platform match");
}

my $g3=resolve_lg_capabilities({
 series=>'G3', platform_model=>'HE_DTV_W23O_AFABATAA',
 software_version=>'23.25.55', platform_year=>2023,
},root=>$root);
is($g3->{match_status},'exact_firmware','G3 exact firmware overlay is selected');
is(scalar(@{$g3->{data}{settings}{public_routes}{read}{picture_keys}}),61,'G3 has 61 firmware-inventory public read keys');
is(scalar(@{$g3->{data}{settings}{public_routes}{write}{picture_keys}}),61,'G3 has 61 firmware-inventory public write-list keys');
is($g3->{data}{settings}{public_routes}{write}{support_state},'firmware_inventory','a public write listing remains inventory, not verified');
is($g3->{data}{settings}{public_routes}{grouped_read}{support_state},'unknown','grouped read is independent and remains unknown');
like($g3->{capability_profile_hash},qr/^[0-9a-f]{64}$/,'effective profile has a SHA-256 content hash');
my $g3_again=resolve_lg_capabilities({series=>'G3',platform_model=>'HE_DTV_W23O_AFABATAA',software_version=>'23.25.55',platform_year=>2023},root=>$root);
is($g3_again->{capability_profile_hash},$g3->{capability_profile_hash},'effective profile hash is deterministic');

my $cx=resolve_lg_capabilities({series=>'CX',platform_model=>'HE_DTV_W20O_AFABATAA',software_version=>'4.63.25'},root=>$root);
is(scalar(@{$cx->{data}{settings}{public_routes}{read}{picture_keys}}),4,'CX exact firmware lists four public read keys');
is(scalar(@{$cx->{data}{settings}{public_routes}{write}{picture_keys}}),0,'CX exact firmware lists no public write keys');
is($cx->{data}{settings}{public_routes}{write}{support_state},'not_listed_in_firmware_inventory','empty public list is not represented as universal unsupported');

my $model_fallback=resolve_lg_capabilities({series=>'B4',platform_year=>2024},root=>$root);
is($model_fallback->{match_status},'retail_model_fallback','retail model is an explicit fallback');
is($model_fallback->{data}{calibration}{three_d_lut}{grid_size},17,'B4 fallback resolves to 17-point geometry');
ok(!$model_fallback->{platform_profile_applied},'retail fallback does not claim a reviewed internal platform match');
my $conflict=resolve_lg_capabilities({series=>'B4',platform_model=>'HE_DTV_W24O_AFABATAA',platform_year=>2024},root=>$root);
is($conflict->{data}{calibration}{three_d_lut}{grid_size},33,'reported internal platform wins over conflicting retail model');
like(join(' ',@{$conflict->{warnings}}),qr/internal platform wins/i,'platform/model conflict is visible');

my $ambiguous_c6=resolve_lg_capabilities({series=>'C6',platform_year=>2016},root=>$root);
is($ambiguous_c6->{match_status},'conservative','bare 2016/2026 C6 ambiguity fails closed');
ok(!defined($ambiguous_c6->{data}{calibration}{three_d_lut}{grid_size}),'ambiguous C6 has no guessed LUT geometry');

my $unknown=resolve_lg_capabilities({series=>'Q9',platform_model=>'HE_DTV_W99Q_UNKNOWN'},root=>$root);
is($unknown->{match_status},'conservative','unknown platform uses conservative profile');
ok(!defined($unknown->{data}{calibration}{three_d_lut}{grid_size}),'unknown platform does not guess a 3D LUT size');

my $sdr=lg_recipe('sdr',root=>$root);
my $hdr=lg_recipe('hdr',root=>$root);
my $dv=lg_recipe('dv',root=>$root);
is($sdr->{settings}[1]{value},85,'SDR recipe contrast is 85');
is($hdr->{settings}[1]{value},100,'HDR10 recipe contrast is 100');
is($dv->{signal},'dolby_vision','DV alias resolves the Dolby Vision recipe');
{
 my $temporary=tempdir(CLEANUP=>1);
 find({no_chdir=>1,wanted=>sub {
  my $relative=substr($File::Find::name,length($root));
  my $target=$temporary.$relative;
  if(-d $File::Find::name) {make_path($target)}
  elsif(-f $File::Find::name) {copy($File::Find::name,$target) or die $!}
 }},$root);
 my $path="$temporary/lg/recipes/autocal-sdr.json";
 open my $in,'<',$path or die $!;my $document=JSON::PP::decode_json(do {local $/;<$in>});close $in;
 $document->{recipes}[0]{settings}[0]{value}=999;
 open my $out,'>',$path or die $!;print {$out} JSON::PP::encode_json($document);close $out;
 my $bad=validate_lg_library($temporary);
 ok(!$bad->{ok},'malformed recipe value invalidates the entire library');
 like(join(' ',@{$bad->{errors}}),qr/invalid recipe value brightness/,'recipe validation identifies the bad control');
 $document->{recipes}[0]{settings}[0]{value}=50;
 open $out,'>',$path or die $!;print {$out} JSON::PP::encode_json($document);close $out;
 my $policy_path="$temporary/lg/settings/legacy-best-available.json";
 open $in,'<',$policy_path or die $!;my $policy=JSON::PP::decode_json(do {local $/;<$in>});close $in;
 my $original=JSON::PP::encode_json($policy);
 for my $mutate (
  sub {$_[0]{profiles}[0]{data}{settings}{best_available}{enabled}='false'},
  sub {$_[0]{profiles}[2]{data}{settings}{best_available}{unverified_write_signals}='sdr'},
  sub {$_[0]{profiles}[2]{data}{settings}{best_available}{unverified_write_signals}=['anything']},
  sub {$_[0]{profiles}[2]{data}{settings}{controls}{brightness}{write}{allow_unverified_readback}='false'},
 ) {
  my $changed=JSON::PP::decode_json($original);$mutate->($changed);
  open $out,'>',$policy_path or die $!;print {$out} JSON::PP::encode_json($changed);close $out;
  my $validation=validate_lg_library($temporary);
  ok(!$validation->{ok},'malformed best-settings policy invalidates the whole library');
  my $resolved=resolve_lg_capabilities({model_name=>'OLED65C1PUB',platform_model=>'W21O'},root=>$temporary);
  ok(!$resolved->{library_valid},'malformed policy never resolves a partially permissive profile');
 }
 my $changed=JSON::PP::decode_json($original);
 # Changing only a data selector transfers the rule to another retail label.
 # This would fail if application code secretly special-cased C1.
 $changed->{profiles}[2]{match}{retail_series}=['TEST'];
 open $out,'>',$policy_path or die $!;print {$out} JSON::PP::encode_json($changed);close $out;
 clear_lg_capability_cache();
 my $other=PGLGCapabilities::lg_setting_contracts({series=>'TEST',platform_model=>'W21O'},root=>$temporary,category=>'picture',signal_mode=>'sdr',keys=>['brightness']);
 ok($other->{contracts}{brightness}{allow_unverified_readback},'data-only selector change applies the shared policy to another family');
 my $c1=PGLGCapabilities::lg_setting_contracts({series=>'C1',platform_model=>'W21O'},root=>$temporary,category=>'picture',signal_mode=>'sdr',keys=>['brightness']);
 ok(!$c1->{contracts}{brightness}{allow_unverified_readback},'C1 has no hard-coded waiver after its matrix selector changes');
}

done_testing();
