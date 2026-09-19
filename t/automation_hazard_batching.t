use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();

# Every helper call is a fresh TV session (3-14 s on the G3). The old walk
# asked one key per category per call: 14 calls a job, 13 refusals.
my $refused='500 Application error: Some keys are not allowed for the request.';
my %tv=(   # category => { key => value } the TV exposes there
 picture=>{energySaving=>'off'},
 screenSaver=>{screenSaverTimeout=>'never'},
 general=>{autoPowerOff=>'off',noSignalPowerOff=>'on'},
);
my (@calls,$offline);
local *main::webui_lg_picture_settings=sub {
 my $request=PGAutomation::decode_json($_[0]);
 push @calls,[$request->{category},[sort @{$request->{keys}}]];
 return PGAutomation::encode_json({status=>'error',message=>'Unable to connect to LG WebOS TV at 1.2.3.4'}) if $offline;
 my $exposed=$tv{$request->{category}}||{};
 my @ok=grep {exists $exposed->{$_}} @{$request->{keys}};
 return PGAutomation::encode_json({status=>@ok?'ok':'error',supported_picture_keys=>\@ok,
  picture_settings=>{map {$_=>$exposed->{$_}} @ok},
  unsupported_picture_keys=>{map {$_=>"$refused ( $_ )"} grep {!exists $exposed->{$_}} @{$request->{keys}}},
  lg_generation=>{model_name=>'OLED55G36LA'}});
};
my $item={name=>'SDR Filmmaker',signal_format=>'sdr',picture_mode=>'filmMaker',
 device_identity=>{model_name=>'OLED55G36LA',firmware=>'23.25.55',webos_release=>'9.2.2'}};
my $summary=sub { join(' ',map {$_->{key}.'@'.$_->{category}} sort {$a->{key} cmp $b->{key}} @{$_[0]}) };

my $hazards=main::webui_automation_probe_item_hazards($item,'',sub {},0);
is($summary->($hazards),'autoPowerOff@general energySaving@picture noSignalPowerOff@general screenSaverTimeout@screenSaver','first job finds every exposed control in its first working category');
is(scalar(@calls),6,'an unknown TV costs one call per category, not one per key and category');
is_deeply($calls[0],['picture',['aiPicture','energySaving']],'keys sharing a category are read together');
is_deeply($calls[-1],['general',['autoPowerOff','noSignalPowerOff','screenSaver']],'only still-unknown keys reach the last category');
is($hazards->[0]{value},'off','live values still come from the TV');

@calls=();
$hazards=main::webui_automation_probe_item_hazards($item,'',sub {},1);
is($summary->($hazards),'autoPowerOff@general energySaving@picture noSignalPowerOff@general screenSaverTimeout@screenSaver','second job gets the same controls');
is(scalar(@calls),3,'a remembered TV is asked only where each control was last seen');
ok(!grep({grep({$_ eq 'aiPicture' || $_ eq 'screenSaver'} @{$_->[1]})} @calls),'controls the TV refused everywhere are not asked for again');

# The TV moves a control: the remembered category is refused, the others are searched again.
delete $tv{general}{autoPowerOff};$tv{power}={autoPowerOff=>'off'};@calls=();
$hazards=main::webui_automation_probe_item_hazards($item,'',sub {},0);
like($summary->($hazards),qr/autoPowerOff\@power/,'a refused remembered category falls back to the full search');
@calls=();main::webui_automation_probe_item_hazards($item,'',sub {},0);
ok(grep({$_->[0] eq 'power'} @calls) && !grep({$_->[0] eq 'general' && grep({$_ eq 'autoPowerOff'} @{$_->[1]})} @calls),'the new category is remembered');

# Transport failures are unknowns, never remembered as absences.
my $other={%$item,device_identity=>{model_name=>'OLED65C4',firmware=>'1.0',webos_release=>'9'}};
$offline=1;@calls=();
$hazards=main::webui_automation_probe_item_hazards($other,'',sub {},0);
is(scalar(@$hazards),0,'an unreachable TV exposes nothing');
$offline=0;@calls=();
$hazards=main::webui_automation_probe_item_hazards($other,'',sub {},0);
is(scalar(@calls),6,'after a transport failure the next check asks every category again');
is(scalar(@$hazards),4,'and finds the controls');

# No identity, no memo: still batched, never remembered.
my $anonymous={%$item,device_identity=>{}};
@calls=();main::webui_automation_probe_item_hazards($anonymous,'',sub {},0);
@calls=();main::webui_automation_probe_item_hazards($anonymous,'',sub {},0);
is(scalar(@calls),6,'a TV without an identity is probed in full each time');
my $memo=PGAutomation::read_json_file(main::webui_automation_hazard_memo_path());
is_deeply([sort keys %$memo],['OLED55G36LA|23.25.55|9.2.2','OLED65C4|1.0|9'],'memo is keyed by model and firmware only');
# webOS phrases a whole-category refusal differently; it must still count as the TV's answer.
{
 my $g3={%$item,device_identity=>{model_name=>'OLED55G36LA',firmware=>'23.25.60',webos_release=>'9.2.2'}};
 local *main::webui_lg_picture_settings=sub {
  my $request=PGAutomation::decode_json($_[0]);push @calls,[$request->{category},[sort @{$request->{keys}}]];
  return PGAutomation::encode_json({status=>'error',message=>'LG TV did not return picture settings',supported_picture_keys=>[],
   unsupported_picture_keys=>{map {$_=>"500 Application error: category, $request->{category} doesn't support the key(s): $_"} @{$request->{keys}}}});
 };
 @calls=();main::webui_automation_probe_item_hazards($g3,'',sub {},0);
 is(scalar(@calls),6,'a TV that refuses every category is asked once per category');
 @calls=();main::webui_automation_probe_item_hazards($g3,'',sub {},0);
 is(scalar(@calls),0,'and is never asked again while the firmware is unchanged');
}
my $single=main::webui_automation_probe_hazard($item,'energySaving','picture','');
is($single->{value},'off','single-key probe still works for existing callers');
done_testing();
