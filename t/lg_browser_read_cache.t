use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";
my $dir=tempdir(CLEANUP=>1);
local $ENV{PGEN_AUTOMATION_DIR}=$dir;
$main::var_dir=$dir;
mkdir "$dir/lg";
# While an automation run owns the TV, every browser picture-settings read
# spawned a TV helper on the single TV lane and queued the runner behind it.
# Reads that arrive over HTTP without the run's token are now answered from
# the last live read; in-process readers and token-bearing callers read live.
my $live_calls=0;
local *main::webui_lg_picture_settings=sub {
 my $request=JSON::PP::decode_json($_[0]||'{}');
 $live_calls++;
 my @keys=@{$request->{keys}||['pictureMode','brightness']};
 my %all=(pictureMode=>'hdrFilmMaker',brightness=>50);
 return JSON::PP::encode_json({status=>'ok',picture_settings=>{map {$_=>$all{$_}} grep {exists $all{$_}} @keys},current_input=>'hdmi4',
  generation_profile=>{capability_profile_hash=>('a' x 64)},supported_picture_keys=>[@keys],setting_contracts=>{map {$_=>{wire_key=>$_}} @keys}});
};
my $read=sub { JSON::PP::decode_json(main::webui_lg_api('/api/lg/picture-settings','POST',JSON::PP::encode_json($_[0]))) };
sub execution { my ($status,$token)=@_; open(my $fh,'>',"$dir/execution.json") or die $!; print $fh JSON::PP::encode_json({status=>$status,token=>$token,run_id=>'run-1'}); close($fh); }

my $r=$read->({keys=>['pictureMode','brightness']});
is($live_calls,1,'with no automation claim the read is live');
ok(!$r->{cached},'and not flagged as cached');
execution('running','tok-1');
$r=$read->({keys=>['pictureMode','brightness']});
is($live_calls,1,'a browser read during a run spawns nothing');
ok($r->{cached}&&$r->{automation_active},'the answer is flagged as cached during automation');
is($r->{picture_settings}{pictureMode},'hdrFilmMaker','it carries the last live values');
is($r->{current_input},'hdmi4','including the input the values were read on');
is($r->{run_id},'run-1','and names the run that owns the TV');
$r=$read->({keys=>['pictureMode'],automation_token=>'tok-1'});
is($live_calls,2,'the run\'s own token reads live');
ok(!$r->{cached},'and is not flagged');
$r=$read->({keys=>['pictureMode'],automation_token=>'tok-old'});
is($live_calls,2,'a token from another run does not bypass the cache');
ok($r->{cached},'it is served the cached values');
for my $status (qw(paused interrupted complete stopped)) {
 execution($status,'tok-1');
 $read->({keys=>['pictureMode']});
}
is($live_calls,6,'paused, interrupted and finished runs do not gate browser reads');
execution('running','tok-1');
$r=$read->({});
is_deeply([sort keys %{$r->{picture_settings}}],['brightness','pictureMode'],'a keyless read gets every remembered control');
# The runner's one-key mode reads must not shrink the capability envelope the
# Display card is later shown.
$read->({keys=>['pictureMode'],automation_token=>'tok-1'});
$r=$read->({keys=>['pictureMode','brightness']});
is_deeply([sort @{$r->{supported_picture_keys}}],['brightness','pictureMode'],'a narrow live read leaves the wider supported-key list in place');
is_deeply([sort keys %{$r->{setting_contracts}}],['brightness','pictureMode'],'and the contracts');

# The readiness endpoint and every other in-process reader call
# webui_lg_picture_settings directly; only the HTTP dispatcher consults the
# cache, so none of them can be served stale values during a run.
{
 open my $fh,'<',"$Bin/../usr/share/PGenerator/webui.pm" or die $!;local $/;my $webui=<$fh>;
 my @dispatch=$webui=~/(&webui_lg_api\()/g;
 is(scalar(@dispatch),1,'webui.pm reaches the LG dispatcher from exactly one place, the HTTP router');
 like($webui,qr/sub webui_automation_readiness_data.*?&webui_lg_picture_settings\(/s,'readiness reads through the live routine, not the dispatcher');
 open $fh,'<',"$Bin/../usr/share/PGenerator/lg.pm" or die $!;my $lg=<$fh>;
 my @uses=$lg=~/(&lg_browser_picture_settings_while_automation\()/g;
 is(scalar(@uses),1,'the cache is consulted in one place');
 like($lg,qr/sub webui_lg_api .*?&lg_browser_picture_settings_while_automation\(/s,'and that place is the HTTP dispatcher');
}

# Partial reads merge only within one proven TV/input/mode/signal/category.
{
 execution('running','tok-1');
 my $remember=sub {
  my ($mode,$signal,$settings,$input,$profile)=@_;
  my $payload={picture_mode=>$mode,signal_mode=>$signal,category=>'picture'};
  my $hash=($profile||'a')x64; # scalar context: string repetition, not a 64-element list
  my $response={status=>'ok',ip=>'192.0.2.2',current_input=>$input||'hdmi4',picture_settings=>{pictureMode=>$mode,%$settings},
   generation_profile=>{capability_profile_hash=>$hash},supported_picture_keys=>[keys %$settings,'pictureMode']};
  main::lg_remember_picture_settings(JSON::PP::encode_json($response),JSON::PP::encode_json($payload));
 };
 $remember->('filmMaker','sdr',{gamma=>'2.4',brightness=>50});
 $remember->('dolbyHdrCinema','dv',{});
 my $cached=JSON::PP::decode_json(main::lg_browser_picture_settings_while_automation(JSON::PP::encode_json({signal_mode=>'dv',picture_mode=>'dolbyHdrCinema'})));
 is($cached->{picture_settings}{pictureMode},'dolbyHdrCinema','new context carries its own observed mode');
 ok(!exists $cached->{picture_settings}{gamma},'SDR gamma cannot leak into a DV mode-only read');
 ok(!grep($_ eq 'gamma',@{$cached->{supported_picture_keys}||[]}),'capability envelope does not cross signal modes either');
 $cached=JSON::PP::decode_json(main::lg_browser_picture_settings_while_automation(JSON::PP::encode_json({signal_mode=>'sdr',picture_mode=>'filmMaker'})));
 is_deeply($cached->{picture_settings},{},'an explicit other-mode request is not answered with the current-mode cache');
 # P21: the answer says whether any remembered context exists, so the Display
 # card can tell "another context" apart from "nothing read yet".
 ok(!$cached->{cache_context_available},'the other-mode request is flagged as a different context');
 ok($cached->{cache_present},'while a remembered context is reported as present');
 {
  no warnings 'redefine';
  local *main::lg_read_picture_settings_cache=sub {{}};
  my $empty=JSON::PP::decode_json(main::lg_browser_picture_settings_while_automation(JSON::PP::encode_json({signal_mode=>'sdr',picture_mode=>'filmMaker'})));
  ok(!$empty->{cache_context_available},'with no remembered values the context is unavailable');
  ok(defined($empty->{cache_present}) && !$empty->{cache_present},'and no remembered context is reported present');
 }
 $remember->('dolbyHdrCinema','dv',{brightness=>49});
 $remember->('dolbyHdrCinema','dv',{},'hdmi1');
 $cached=JSON::PP::decode_json(main::lg_browser_picture_settings_while_automation('{}'));
 ok(!exists $cached->{picture_settings}{brightness},'same mode on a different input has a separate cache');
 $remember->('dolbyHdrCinema','dv',{brightness=>48},'hdmi1');
 $remember->('dolbyHdrCinema','dv',{},'hdmi1','b');
 $cached=JSON::PP::decode_json(main::lg_browser_picture_settings_while_automation('{}'));
 ok(!exists $cached->{picture_settings}{brightness},'a changed compatibility profile cannot reuse old readings');
}
done_testing();
