use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('mode-skip-test','test-token'); local $SIG{__WARN__}=sub {}; do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
# A real run always has a manifest; mode writes are journalled in it (P14).
PGAutomation::ensure_store();
PGAutomation::write_json_atomic(PGAutomation::run_dir('mode-skip-test').'/run.json',{id=>'mode-skip-test',token=>'test-token',status=>'running',items=>[{}]});
# A picture mode the TV already reports on the expected input is confirmed
# by that independent read; no write, no settle, no second read.
my (@calls,@checks,@settles,@logs);
local *main::_log=sub {push @logs,$_[0]};
local *main::_sleep_controlled=sub {push @settles,$_[0];1};
local *main::_append_setting_check=sub {push @checks,{%{$_[2]},checkpoint=>$_[1]};1};
my %tv=(pictureMode=>'filmMaker',input=>'hdmi4',virtual=>0);
local *main::_api=sub {
 my ($method,$path,$p)=@_;
 push @calls,{path=>$path,payload=>$p};
 if($path eq '/api/lg/picture-settings/set'){ $tv{pictureMode}=$p->{settings}{pictureMode} if $p->{settings}{pictureMode}; return {status=>'ok'}; }
 return {status=>'ok',picture_settings=>{pictureMode=>$tv{pictureMode}},current_input=>$tv{input},
  ($tv{virtual}?(virtual_picture_settings=>JSON::PP::true):())};
};
sub item { return {signal_format=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi4',settle_seconds=>8,settings=>{},stages=>{calibration=>0}}; }
sub reset_fixture { @calls=();@checks=();@settles=();@logs=();%tv=(pictureMode=>'filmMaker',input=>'hdmi4',virtual=>0); }

reset_fixture();
ok(main::_select_item_picture_mode(0,item(),'c4'),'an already active mode is accepted');
is(scalar(@calls),1,'one read and nothing else');
is($calls[0]{path},'/api/lg/picture-settings','the read is a picture-settings read');
ok($calls[0]{payload}{ignore_calibration_picture_mode},'the read ignores the saved calibration mode');
ok(!exists($calls[0]{payload}{picture_mode}),'the read asks for no picture mode, so nothing can be echoed');
is_deeply(\@settles,[],'no settle');
is($checks[0]{checkpoint},'c4-mode','the readback is recorded as the mode verification');
is($checks[0]{operation},'readback','recorded as a readback, not a write');
ok(grep({/already active on hdmi4; confirmed by readback, no mode write needed/} @logs),'the skipped write is announced');

reset_fixture();$tv{pictureMode}='cinema';
ok(main::_select_item_picture_mode(0,item(),'c4'),'a different mode is written');
is_deeply([map {$_->{path}} @calls],['/api/lg/picture-settings','/api/lg/picture-settings/set','/api/lg/picture-settings'],'read, write, then the independent confirm read');
is_deeply(\@settles,[8],'a real write settles');

reset_fixture();$tv{virtual}=1;
main::_select_item_picture_mode(0,item(),'c4');
ok(scalar(grep {$_->{path} eq '/api/lg/picture-settings/set'} @calls),'virtual settings never count as verified, so the write happens');

reset_fixture();$tv{input}='hdmi3';
main::_select_item_picture_mode(0,item(),'c4');
ok(scalar(grep {$_->{path} eq '/api/lg/picture-settings/set'} @calls),'a different input forces the write');

reset_fixture();
my $no_input=item();delete $no_input->{tv_input};
main::_select_item_picture_mode(0,$no_input,'c4');
ok(scalar(grep {$_->{path} eq '/api/lg/picture-settings/set'} @calls),'without a confirmed input the write happens');

# A caller that already holds an independent no-echo read passes it in.
reset_fixture();
ok(main::_select_item_picture_mode(0,item(),'queue-preflight',{picture_mode=>'filmMaker',tv_input=>'hdmi4',signal_format=>'sdr',settle_seconds=>1,stages=>{calibration=>0},no_echo=>1,verified=>1,current_input=>'hdmi4'}),'a stamped preflight snapshot is accepted as the pre-read');
is(scalar(@calls),0,'no extra read');
reset_fixture();
ok(main::_select_item_picture_mode(0,item(),'job-start',main::_mode_read_from_response({status=>'ok',picture_settings=>{pictureMode=>'filmMaker'},current_input=>'hdmi4'})),'a normalised response is accepted');
is(scalar(@calls),0,'no extra read either');
reset_fixture();
main::_select_item_picture_mode(0,item(),'job-start',{picture_mode=>'filmMaker',current_input=>'hdmi4'});
is($calls[0]{path},'/api/lg/picture-settings','an unrecognised pre-read shape is ignored and a fresh no-echo read is made');
reset_fixture();
main::_select_item_picture_mode(0,item(),'job-start',item());
is($calls[0]{path},'/api/lg/picture-settings','an automation item, which has the same fields, is never mistaken for a readback');

# The no-echo reads clear the item context so the daemon cannot echo the
# queued selector into the answer.
{
 open my $fh,'<',"$Bin/../usr/bin/pgen_automation_runner.pl" or die $!;local $/;my $source=<$fh>;
 for my $name (qw(_read_active_mode _freeze_job_lg_context _preflight_read_mode)) {
  my ($body)=$source=~/sub \Q$name\E\s*\{(.*?)\n\}/s;
  like($body,qr/\$ACTIVE_ITEM\s*=\s*undef;.*?_api\(/s,"$name clears the item context before its read");
  like($body,qr/ignore_calibration_picture_mode\s*=>\s*JSON::PP::true/,"$name ignores the saved calibration mode");
 }
}

for my $nested (0,1) {
 my $response={status=>'ok',current_input=>'hdmi4',picture_settings=>{pictureMode=>'filmMaker'}};
 if($nested) {$response->{lg_generation}={picture_mode_read_forbidden=>JSON::PP::true};}
 else {$response->{picture_mode_read_forbidden}=JSON::PP::true;}
 ok(!main::_mode_read_from_response($response)->{verified},"mode echo with nested=$nested read ban is never independent verification");
}
ok(main::_mode_read_from_response({status=>'ok',current_input=>'hdmi4',picture_settings=>{pictureMode=>'filmMaker'},
 lg_generation=>{ddc_only_white_balance=>1}})->{verified},'DDC-only white balance is not implicitly a mode-read prohibition');
{
 local *main::_api=sub {{status=>'ok',current_input=>'hdmi4',picture_settings=>{pictureMode=>'filmMaker'},
  supported_picture_keys=>[],lg_generation=>{picture_mode_read_forbidden=>JSON::PP::true},
  generation_profile=>{capability_library_valid=>1,capability_platform_profile_applied=>1,picturemode_readable=>0}}};
 my $check=main::_read_and_verify_settings(0,item(),'c1');
 is($check->{verified},'unverifiable','settings verification recognises a nested ban without claiming the echo is verified');
}
done_testing();
