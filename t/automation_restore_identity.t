# Regression for PR 14 test report P16 (round 4) and P22 H-restore-hash: when
# the TV changes under a batch, restoration is abandoned with a warning and
# the TV released, whatever the new source shows; an unchanged TV is never
# abandoned because of one odd read; and an unreachable TV stays a retryable
# failure. The mock refuses scoped TV requests exactly as the helper does once
# the saved input or compatibility hash no longer matches.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
# _apply_signal waits up to 35 s of wall time for a refused TV read; skew the
# clock inside it only, so those cases finish in well under a second.
# The runner imports Time::HiRes::time, so wrap that before it is loaded.
our $skew=0;
BEGIN {
 require Time::HiRes;
 my $real=\&Time::HiRes::time;
 no warnings 'redefine';
 *Time::HiRes::time=sub { $main::skew+=20 if ((caller(1))[3]||'') eq 'main::_apply_signal'; return $real->()+$main::skew; };
}
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

our ($app_id,$partial_profile,$store,$run_file,%config,%modes,$hash,$input,$mode_override,@refused,@writes,$unscoped,$odd_read_at,$fail_read_at,$tv_down,$after_scoped_read,$on_final_pattern,$readiness_die,@logged);
sub tv {
 # A built-in app is reported the way the helper does: no HDMI input, only the app id.
 return {status=>'ok',current_input=>(defined($app_id) ? '' : $input),(defined($app_id) ? (current_app_id=>$app_id) : ()),
  picture_settings=>{pictureMode=>$mode_override//$modes{$config{signal_mode}}},supported_picture_keys=>['pictureMode'],
  lg_generation=>{picture_mode_read_forbidden=>JSON::PP::false},
  generation_profile=>($partial_profile
   ? {capability_profile_hash=>'e'x64,capability_profile_id=>'fallback',capability_library_valid=>1,capability_platform_profile_applied=>0}
   : {capability_profile_hash=>$hash,capability_profile_id=>'x',capability_library_valid=>1,capability_platform_profile_applied=>1})};
}
sub setup_run {
 my ($name)=@_;
 $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 (my $slug=$name)=~s{[^A-Za-z0-9]+}{-}g;my $run_id="identity-$slug";$run_file=PGAutomation::run_dir($run_id).'/run.json';
 {local @ARGV=($run_id,'test-token');local $SIG{__WARN__}=sub{};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
 %config=(signal_mode=>'sdr',eotf=>'0',primaries=>'0',colorimetry=>'2',color_format=>'0',rgb_quant_range=>'2',max_bpc=>'10',dv_map_mode=>'2');
 %modes=(sdr=>'expert1',hdr10=>'hdrCinema');$hash='a'x64;$input='hdmi1';
 ($app_id,$partial_profile,$mode_override,$odd_read_at,$fail_read_at,$tv_down,$unscoped,$after_scoped_read,$on_final_pattern)=(undef,0,undef,0,0,0,0,undef,undef);@refused=();@writes=();
 my @items=map {main::webui_automation_normalize_item({id=>"j$_",name=>"J$_",signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',settings=>{},settle_seconds=>0,stages=>{calibration=>1,apply_all=>0}})} 0;
 PGAutomation::write_json_atomic($run_file,{id=>$run_id,token=>'test-token',status=>'running',items=>\@items,queue_revision=>0});
 PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$run_id,token=>'test-token',status=>'running',pid=>0});
 PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'none'});
 *main::_api=sub {
  my ($m,$p,$pl)=@_;
  if($p eq '/api/config'){return {%config} if $m eq 'GET';@config{keys %$pl}=values %$pl;return {status=>'ok'};}
  return {ok=>1} if $p eq '/api/ping';
  if($p eq '/api/pattern'){
   # Only the final restore shows the pattern without a job's max_luma.
   $on_final_pattern->() if $on_final_pattern && !exists($pl->{max_luma});
   return {status=>'ok'};
  }
  return {status=>'ok'} if $p eq '/api/meter/session/stop';
  if($p=~m{^/api/lg/}){
   return {status=>'error',message=>'TV unreachable'} if $tv_down;
   # The runner scopes a job's requests to its saved input (a signal switch
   # reads the TV with the job's tv_input and picture_mode); the helper
   # refuses those once the input differs.
   if(($pl->{tv_input}||'') ne '' && $pl->{tv_input} ne $input){push @refused,'input';return {status=>'error',error_code=>'lg-input-context-changed',message=>'The active TV input changed or could not be confirmed.'};}
   # Identity and mode reads carry no picture_mode selector.
   if($p eq '/api/lg/picture-settings' && !defined($pl->{picture_mode})){
    $unscoped++;
    return {status=>'error',message=>'Timed out reading the TV'} if $fail_read_at && $unscoped==$fail_read_at;
    if($odd_read_at && $unscoped==$odd_read_at){my $r=tv();$r->{generation_profile}{capability_profile_hash}='c'x64;return $r;}
   }
   if($p eq '/api/lg/picture-settings' && defined($pl->{picture_mode}) && $after_scoped_read){
    my $r=tv();my $hook=$after_scoped_read;$after_scoped_read=undef;$hook->();return $r;
   }
  }
  return tv() if $p eq '/api/lg/picture-settings';
  if($p eq '/api/lg/picture-settings/set'){push @writes,"$config{signal_mode}=$pl->{settings}{pictureMode}";$modes{$config{signal_mode}}=$pl->{settings}{pictureMode};return tv();}
  if($p eq '/api/automation/readiness'){
   return {status=>'ok',ready=>1,checks=>[],items=>$pl->{items}} if $pl->{scope} eq 'batch';
   die $readiness_die if defined($readiness_die);
   my $it=main::webui_automation_normalize_item($pl->{items}[0]);$it->{tv_input}=$input;$it->{capability_profile}={hash=>$hash,id=>'x'};$it->{generation_profile}=tv()->{generation_profile};
   return {status=>'ok',ready=>1,items=>[$it],checks=>[]};
  }
  die "unexpected $m $p";
 };
 *main::_sleep_controlled=sub{1};*main::_log=sub{push @logged,$_[0]};*main::_log_action=sub{};*main::_ensure_lg_connection=sub{1};
}
sub scenario {
 my ($name,$setup)=@_;
 setup_run($name);
 ok(main::_preflight_queue()->{ready},"$name: the queue check passes and saves the viewing context");
 # A job then selects HDR10 and changes its mode, as _select_item_picture_mode journals it.
 $config{signal_mode}='hdr10';$modes{hdr10}='hdrFilmMaker';
 PGAutomation::with_lock($run_file,sub {$_[0]{viewing_restore_required}=JSON::PP::true;$_[0]{mode_written_signals}={hdr10=>{job=>JSON::PP::true}};return $_[0];});
 @writes=();@refused=();$unscoped=0;
 $setup->();
 main::_finish('complete');
 return PGAutomation::read_json_file($run_file);
}

my $run=scenario('unchanged',sub {});
is($run->{status},'complete','unchanged TV: the batch completes');
is($run->{viewing_restore_outcome},'verified','unchanged TV: the original modes are verified');
is_deeply(\@writes,['hdr10=hdrCinema'],'unchanged TV: the HDR10 mode is put back');

for my $case (
 [firmware=>sub {$hash='b'x64},qr/compatibility profile changed/],
 ['same-format input'=>sub {$input='hdmi2'},qr/TV input changed \(hdmi1 to hdmi2\)/],
 ['SDR source while the generator outputs HDR10'=>sub {$input='hdmi2';$mode_override='expert1'},qr/TV input changed/],
 ['built-in app'=>sub {$input='';$app_id='com.webos.app.netflix';$mode_override='standard'},qr/TV input changed \(hdmi1 to app:com\.webos\.app\.netflix\)/],
 ['firmware, first identity read fails'=>sub {$hash='b'x64;$fail_read_at=1},qr/compatibility profile changed/],
 ['input, first identity read fails'=>sub {$input='hdmi2';$fail_read_at=1},qr/TV input changed/],
 # The signal switch itself is refused because the TV changed: confirmed, not retried.
 ['SDR source, first identity read fails'=>sub {$input='hdmi2';$mode_override='expert1';$fail_read_at=1},qr/TV input changed/],
 # The generator is already on HDR10, so no switch happens; the first scoped
 # read is the readback of the restoring mode write, and the TV moves to an
 # app right after it, before the independent verification read.
 ['app after the mode write'=>sub {$after_scoped_read=sub {$input='';$app_id='com.webos.app.netflix';$mode_override='standard'}},qr/TV input changed \(hdmi1 to app:com\.webos\.app\.netflix\)/],
 # Every signal restored, then the profile changes as the final pattern shows.
 ['profile change at the final check'=>sub {$on_final_pattern=sub {$hash='d'x64}},qr/compatibility profile changed/],
) {
 my ($name,$setup,$why)=@$case;
 $run=scenario($name,$setup);
 is($run->{status},'complete-with-warnings',"$name: the batch completes with a warning instead of parking");
 is($run->{viewing_restore_outcome},'abandoned-tv-changed',"$name: restoration is abandoned because the TV changed");
 ok(!$run->{viewing_restore_required},"$name: nothing is left owed");
 ok(!-f "$store/execution.json","$name: the TV is released");
 if($name eq 'app after the mode write') {
  is_deeply(\@writes,['hdr10=hdrCinema'],"$name: the mode written before the TV changed stands; nothing more is written");
 } elsif($name !~ /final check/) {
  is_deeply(\@writes,[],"$name: no picture mode is written to the changed TV");
 }
 like(join(' ',@{$run->{warnings}||[]}),$why,"$name: the warning names the change");
 cmp_ok(scalar(@refused),'<=',20,"$name: no long loop of refused TV requests");
}

for my $at (1..4) {
 $run=scenario("odd read $at",sub {$odd_read_at=$at});
 is($run->{viewing_restore_outcome},'verified',"unchanged TV with one odd hash on identity read $at: restoration still completes");
 is_deeply(\@writes,['hdr10=hdrCinema'],"unchanged TV with one odd hash on identity read $at: the mode is restored");
}

# A partial profile read (model table not applied, so a fallback hash) on an
# unchanged TV is never mistaken for a changed TV.
$run=scenario('partial profile read',sub {$partial_profile=1});
isnt($run->{viewing_restore_outcome}||'','abandoned-tv-changed','partial profile read: an unchanged TV is not abandoned');
ok($run->{viewing_restore_required} || ($run->{viewing_restore_outcome}||'') eq 'verified','partial profile read: the restore stays owed or verifies');
is_deeply(\@writes,[],'partial profile read: no mode is written from an unconfirmed identity');

$run=scenario('unreachable',sub {$tv_down=1});
ok($run->{viewing_restore_required},'unreachable TV: restoration stays owed for Retry cleanup');
isnt($run->{viewing_restore_outcome}||'','abandoned-tv-changed','unreachable TV: an unreadable TV is never treated as a changed one');
ok(-f "$store/execution.json",'unreachable TV: ownership is kept');

# P28 (round 4): an exception inside the queue check reaches the operator
# without the runner's file and line, on one line, while the raw text with its
# location is kept in the check and runner.log for diagnosis.
{
 setup_run('queue check crash');
 @logged=();
 local $readiness_die="Readiness helper crashed\nwhile reading the TV";
 my $result=main::_preflight_queue();
 my ($check)=grep {($_->{name}||'') eq 'queue-preflight-job'} @{$result->{checks}};
 ok(!$result->{ready},'a crashing job check blocks the queue');
 like($check->{message},qr/\AReadiness helper crashed \| while reading the TV\z/,'the job check shows the reason on one line without a location');
 like($check->{raw_exception},qr/Readiness helper crashed \| while reading the TV at \S+ line \d+/,'the raw exception with its location is kept in the check');
 ok((grep {/queue preflight job 1 failed: Readiness helper crashed .*\[raw: .* line \d+/} @logged),'and runner.log records it with the raw location');
 my ($plain,$raw)=main::_clean_exception("Bad value at /usr/bin/pgen_automation_runner.pl line 12, <STDIN> line 3.\n");
 is($plain,'Bad value','the filehandle form of the location is stripped too');
 like($raw,qr/line 12, <STDIN> line 3\.\z/,'while the raw form keeps it');
 ($plain,$raw)=main::_clean_exception("Already clean\n");
 is($raw,$plain,'a message without a location has no separate raw copy');
}
done_testing();
