use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP ();
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Find qw(find);
use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(lg_calibration_mode_contract lg_settings_selection_plan lg_picture_mode_record clear_lg_capability_cache validate_lg_library);
my %ctx=(root=>"$Bin/../usr/share/PGenerator/tv",signal_mode=>'hdr10');
for my $id ({},{model_name=>'OLED55G36LA',platform_model=>'W23O'},{model_name=>'OLED65C1PUB',platform_model=>'W21O'}) {
 for my $mode(qw(hdrCinemaBright hdrCinemaHome hdr_cinema_home hdr_cinema_bright)) {
  my $c=lg_calibration_mode_contract($id,%ctx,picture_mode=>$mode);
  ok(!$c->{allowed},"$mode is not an AutoCal bank for ".($id->{model_name}||'static queue validation'));
  like($c->{message},qr/HDR Cinema.*turn AutoCal off and enable readings/,'restriction includes safe alternatives');
 }
 for my $mode(qw(hdrCinema hdr_cinema hdrFilmMaker hdrGame)) {
  ok(lg_calibration_mode_contract($id,%ctx,picture_mode=>$mode)->{allowed},"$mode has a workflow contract");
 }
 ok(lg_calibration_mode_contract($id,%ctx,signal_mode=>'dv',picture_mode=>'dolbyVisionCinemaBright')->{allowed},'DV Cinema Home remains separate and eligible');
 ok(!lg_calibration_mode_contract($id,%ctx,picture_mode=>'dolbyVisionCinemaBright')->{allowed},'cross-signal alias cannot pass');
 ok(!lg_calibration_mode_contract($id,%ctx,picture_mode=>'hdrUnknown')->{allowed},'unrecognised bank is not invented');
}
my $plan=lg_settings_selection_plan({model_name=>'OLED55G36LA',platform_model=>'W23O'},{contrast=>100},{},%ctx,picture_mode=>'hdrCinemaBright');
ok(exists($plan->{automatic}{contrast}),'selectable mode still has independent picture-setting controls');
ok(!$plan->{calibration_mode}{allowed},'editor plan distinguishes control writes from AutoCal bank admission');
my $g3={model_name=>'OLED55G36LA',platform_model=>'W23O'};
my $c1={model_name=>'OLED65C1PUB',platform_model=>'W21O'};
is(lg_picture_mode_record($g3,picture_mode=>'dolbyHdrCinema')->{label},'DV Filmmaker','G3 native token uses catalogue label');
is(lg_picture_mode_record($c1,picture_mode=>'dolbyHdrCinema')->{label},'DV Cinema','older menu label is a data override');
is(lg_picture_mode_record($c1,picture_mode=>'dolbyVisionCinema')->{calibration}{bank},'dolby_cinema_dark','older legacy token uses catalogue bank override');
is(lg_picture_mode_record($g3,picture_mode=>'hdrCinemaBright')->{calibration}{bank},undef,'selectable Home does not invent a calibration token');
{
 my $tmp=tempdir(CLEANUP=>1);my $root=$ctx{root};
 find({no_chdir=>1,wanted=>sub {my $dest=$tmp.substr($File::Find::name,length($root));if(-d $File::Find::name){make_path($dest)}else{copy($File::Find::name,$dest) or die $!}}},$root);
 my $path="$tmp/lg/picture-modes/catalogue.json";
 open my $in,'<',$path or die $!;my $doc=JSON::PP::decode_json(do {local $/;<$in>});close $in;
 push @{$doc->{profiles}},{profile_id=>'lg/test/contributed-mode',priority=>90,match=>{retail_series=>['G3'],firmware_versions=>['test-only']},
  data=>{picture_modes=>{hdr10=>{hdrCinema=>{label=>'Contributed HDR label',settings_value=>'hdrReviewedSelector',aliases=>['hdrReviewedReadback'],calibration=>{support_state=>'inventory',bank=>'hdr_reviewed_bank',internal_mode=>'hdr_reviewed_bank'}}}}},
  evidence=>[{source_id=>'pgenerator-existing-behaviour',strength=>'implementation_policy',scope=>'Synthetic test fixture, not hardware evidence'}]};
 my $write=sub {open my $out,'>',$path or die $!;print {$out} JSON::PP::encode_json($doc);close $out;clear_lg_capability_cache();};$write->();
 ok(validate_lg_library($tmp)->{ok},'scoped contribution validates');
 my $id={%$g3,software_version=>'test-only'};
 my $updated=lg_settings_selection_plan($id,{contrast=>100},{},root=>$tmp,signal_mode=>'hdr10',picture_mode=>'hdrCinema');
 is($updated->{calibration_mode}{mode}{label},'Contributed HDR label','data-only label reaches editor plan');
 is($updated->{calibration_mode}{mode}{settings_value},'hdrReviewedSelector','data-only selector reaches editor plan');
 ok(lg_calibration_mode_contract($id,root=>$tmp,signal_mode=>'hdr10',picture_mode=>'hdrReviewedReadback')->{allowed},'contributed readback alias shares admission');
 is(lg_picture_mode_record($g3,root=>$tmp,picture_mode=>'hdrCinema')->{settings_value},'hdrCinema','unmatched firmware is unaffected');
 local $ENV{PGENERATOR_TV_PROFILE_ROOT}=$tmp;
 my $rc=do "$Bin/../usr/sbin/pgenerator-lg";ok(defined($rc),'helper loads for contribution integration') or BAIL_OUT($@);
 is(main::map_picture_mode_label_to_ddc_name('hdrCinema','hdr10',$id),'hdrReviewedSelector','helper selector consumes scoped contribution');
 ok(main::lg_picture_mode_tokens_agree('hdrCinema','hdrReviewedReadback','hdr10',$id),'helper comparison consumes contributed readback alias');
 is(main::lg_picture_mode_for_calibration('hdrCinema',$id,'hdr10'),'hdr_reviewed_bank','helper uses contributed calibration bank');
 is(main::lg_generation_profile($id)->{picture_mode_catalogue}{hdr10}{hdrCinema}{label},'Contributed HDR label','Display receives the same resolved label');
 $doc->{profiles}[-1]{data}{picture_modes}{hdr10}{hdrCinema}{calibration}{bank}=undef;$write->();
 ok(!validate_lg_library($tmp)->{ok},'declared calibration support without a bank invalidates the library');
 ok(!lg_calibration_mode_contract($id,root=>$tmp,signal_mode=>'hdr10',picture_mode=>'hdrCinema')->{allowed},'invalid contribution cannot partially grant AutoCal');
}
done_testing();
