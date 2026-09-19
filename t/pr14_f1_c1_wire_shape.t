# Adversarial F1 check (agent BC). Independent fixture: exact C1 wire shape
# for a pictureMode read (top-level flag ABSENT, virtual_picture_settings true,
# lg_generation.picture_mode_read_forbidden true, guessed DDC pictureMode).
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use Test::More;
my $WT;BEGIN{$WT="$Bin/.."||die "set WT"}
use lib "$WT/usr/share/PGenerator";
use PGAutomation ();
use PGAutomationPlan ();
require "$WT/usr/share/PGenerator/webui.pm";

my ($store,$run_id,$run_file,@calls,%config,$shape,$prepares,%modes,$guess);
sub fixture {
    my (%o)=@_;
    $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
    $run_id='c1-wire';$run_file=PGAutomation::run_dir($run_id).'/run.json';
    local @ARGV=($run_id,'test-token');
    {local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/redefined/};do "$WT/usr/bin/pgen_automation_runner.pl";die $@ if $@;}
    @calls=();$prepares=0;
    %config=(signal_mode=>'hdr10',eotf=>'2',primaries=>'2',colorimetry=>'9',color_format=>'0',rgb_quant_range=>'2',max_bpc=>'10',dv_map_mode=>'2');
    %modes=(sdr=>'expert1',hdr10=>'hdrCinema',dv=>'dolbyHdrCinema');
    $shape=$o{shape}||'c1';$guess=$o{guess}||'hdrStandardGuess';
    my @specs=@{$o{specs}||[['hdr10','hdrFilmMaker'],['sdr','filmMaker'],['dv','dolbyVisionFilmMaker']]};
    my @items=map {main::webui_automation_normalize_item({id=>"job-$_",name=>"Job $_",signal_format=>$specs[$_][0],picture_mode=>$specs[$_][1],settings=>{},settle_seconds=>0,stages=>{calibration=>1,apply_all=>0}})} 0..$#specs;
    PGAutomation::write_json_atomic($run_file,{id=>$run_id,token=>'test-token',status=>'running',items=>\@items,queue_revision=>0,finish_policy=>'restore-original',%{$o{run}||{}}});
    PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$run_id,token=>'test-token',status=>'running',pid=>0});
    PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'none'});
}
sub profile {
    my %p=(capability_profile_hash=>'c'x64,capability_profile_id=>'lg/effective/W21O/platform/test',
        capability_library_valid=>JSON::PP::true,capability_platform_profile_applied=>JSON::PP::true,picturemode_readable=>JSON::PP::false);
    $p{capability_library_valid}=JSON::PP::false if $shape eq 'c1-invalid-library';
    $p{capability_platform_profile_applied}=JSON::PP::false if $shape eq 'c1-no-platform';
    $p{picturemode_readable}=JSON::PP::true if $shape eq 'modern';
    return \%p;
}
sub read_response {
    my ($payload)=@_;
    my $gen={generation_id=>'lg2021_oled',ddc_only_white_balance=>JSON::PP::true,picture_mode_read_forbidden=>JSON::PP::true,platform_year=>2021};
    if ($shape eq 'modern') {
        return {status=>'ok',current_input=>'hdmi1',current_input_checked=>JSON::PP::true,
            picture_settings=>{pictureMode=>$modes{$config{signal_mode}}},supported_picture_keys=>['pictureMode'],
            lg_generation=>{generation_id=>'lg2023_oled',picture_mode_read_forbidden=>JSON::PP::false,ddc_only_white_balance=>JSON::PP::false},
            generation_profile=>profile()};
    }
    # Real DDC branch: pictureMode is the resolver's GUESS, never native.
    my $r={status=>'ok',current_input=>'hdmi1',current_input_checked=>JSON::PP::true,
        picture_settings=>{pictureMode=>($payload->{picture_mode}||$guess),whiteBalanceMethod=>'22'},
        supported_picture_keys=>[],unsupported_picture_keys=>{},
        virtual_picture_settings=>JSON::PP::true,lg_generation=>$gen,generation_profile=>profile(),
        message=>'LG white-balance settings are represented through PGenerator DDC state on this LG generation.'};
    if ($shape eq 'legacy-top') {delete $r->{lg_generation};delete $r->{virtual_picture_settings};$r->{picture_mode_read_forbidden}=JSON::PP::true;}
    if ($shape eq 'legacy-top-virtual') {delete $r->{lg_generation};$r->{picture_mode_read_forbidden}=JSON::PP::true;}
    if ($shape eq 'empty-noflag') {$r={status=>'ok',current_input=>'hdmi1',picture_settings=>{},supported_picture_keys=>[],generation_profile=>profile(),lg_generation=>{picture_mode_read_forbidden=>JSON::PP::false}};}
    if ($shape eq 'virtual-noflag') {$r->{lg_generation}{picture_mode_read_forbidden}=JSON::PP::false;}
    if ($shape eq 'flag-status-error') {$r->{status}='error';$r->{message}='Simulated helper failure';}
    if ($shape eq 'flag-bad-input') {$r->{current_input}='';}
    if ($shape eq 'flag-bad-hash') {$r->{generation_profile}{capability_profile_hash}='';}
    return $r;
}
my $mode_writes=0;
sub fake_api {
    my ($method,$path,$payload)=@_;
    push @calls,[$method,$path,PGAutomation::clone($payload)];
    if($path eq '/api/config') {return {%config} if $method eq 'GET';@config{keys %$payload}=values %$payload;return {status=>'ok'};}
    return {ok=>1} if $path eq '/api/ping';
    return {status=>'ok'} if $path eq '/api/pattern';
    return read_response($payload) if $path eq '/api/lg/picture-settings';
    if($path eq '/api/lg/picture-settings/set') {
        $mode_writes++;
        $modes{$config{signal_mode}}=$payload->{settings}{pictureMode} if $shape eq 'modern';
        return {%{read_response($payload)},status=>'ok',manual_confirmation_required=>JSON::PP::true,picture_mode_verified=>JSON::PP::false,
            verification_state=>'acknowledged_unverified',applied=>{pictureMode=>$payload->{settings}{pictureMode}},
            picture_settings=>{pictureMode=>$payload->{settings}{pictureMode}}} if $shape ne 'modern';
        return read_response($payload);
    }
    if($path eq '/api/automation/readiness') {
        return {status=>'ok',ready=>1,checks=>[],items=>$payload->{items}} if $payload->{scope} eq 'batch';
        $prepares++;
        my $item=main::webui_automation_normalize_item($payload->{items}[0]);
        $item->{tv_input}='hdmi1';$item->{generation_profile}=profile();
        $item->{capability_profile}={hash=>'c'x64,id=>'fixture'};
        $item->{device_identity}={model_name=>'OLED65C1PUB',generation_id=>'lg2021_oled',firmware=>'53.45'};
        return {status=>'ok',ready=>1,items=>[$item],checks=>[{ok=>1,level=>'ok',message=>'scoped ok'}]};
    }
    return {status=>'ok'} if $path eq '/api/meter/session/stop';
    die "Unexpected device operation $method $path";
}
sub run_check {
    local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};local *main::_ensure_lg_connection=sub {1};
    return main::_preflight_queue();
}
sub posts { my ($re)=@_; return scalar grep {$_->[0] eq 'POST' && $_->[1]=~$re} @calls; }

# ---- S1: exact C1 shape, guessed mode compatible with the active HDR10 signal
fixture(shape=>'c1',guess=>'hdrStandard');$mode_writes=0;
my $r=run_check();
ok($r->{ready},'S1 C1 wire shape: whole-queue preflight ready') or diag explain $r->{checks};
is($r->{verification_state},'limited','S1 limited verification state');
is_deeply([map {$_->{status}} @{$r->{jobs}}],[('checked-limited')x3],'S1 every job checked-limited');
is($r->{checked_items},3,'S1 all 3 jobs checked');
is($mode_writes,0,'S1 no picture-mode write during limited preflight');
is(posts(qr{^/api/config$}),0,'S1 no generator signal change during limited preflight');
is(posts(qr{picture-settings/set|reset|lut|autocal}),0,'S1 no TV writes of any kind');
my $pc=PGAutomation::read_raw(PGAutomation::run_dir($run_id).'/preflight-context.json');
my $vc=PGAutomation::read_raw(PGAutomation::run_dir($run_id).'/viewing-context.json');
unlike($pc,qr/hdrStandard/,'S1 guessed DDC mode not recorded in preflight context');
unlike($vc,qr/hdrStandard/,'S1 guessed DDC mode not recorded in viewing context');
my $vcj=PGAutomation::decode_json($vc);
is_deeply($vcj->{modes},{},'S1 viewing context has no per-signal restoration modes');
is($vcj->{mode_readback_unavailable},1,'S1 viewing context marked mode_readback_unavailable');
ok(!PGAutomation::read_json_file($run_file)->{preflight_restore_required},'S1 no preflight restoration obligation left');
my $plan=PGAutomation::read_json_file(PGAutomation::run_dir($run_id).'/preflight-plan.json');
like($plan->{result}{message}||'',qr/limited scoped checks/,'S1 saved message states limited verification');
# ---- S1b: guessed mode INCOMPATIBLE with signal (SDR guess on HDR10)
fixture(shape=>'c1',guess=>'cinema');$mode_writes=0;
$r=run_check();
ok($r->{ready},'S1b guessed incompatible DDC mode does not block limited path') or diag explain $r->{checks};
# ---- viewing restoration after a limited run (finish)
{
 fixture(shape=>'c1',guess=>'hdrStandard');$r=run_check();
 $config{signal_mode}='dv';$config{max_bpc}='8';
 PGAutomation::with_lock($run_file,sub {$_[0]{viewing_restore_required}=JSON::PP::true;return $_[0];});
 @calls=();$mode_writes=0;
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
 ok(main::_restore_preflight_context('viewing'),'S1c limited viewing restoration succeeds');
 is($config{signal_mode},'hdr10','S1c original generator signal restored');
 is($mode_writes,0,'S1c no guessed picture mode written during restoration');
 is(PGAutomation::read_json_file($run_file)->{viewing_restore_outcome},'output-restored-mode-unavailable','S1c limited outcome recorded');
}
# ---- S2: legacy top-level-only shapes
for my $s (qw(legacy-top legacy-top-virtual)) {
 fixture(shape=>$s);$mode_writes=0;$r=run_check();
 ok($r->{ready},"S2 $s limited path ready") or diag explain $r->{checks};
 is($r->{verification_state},'limited',"S2 $s limited");
 is($mode_writes,0,"S2 $s no mode writes");
}
# ---- S3..S8 must stay fatal
for my $s (qw(c1-invalid-library c1-no-platform empty-noflag virtual-noflag flag-status-error flag-bad-input flag-bad-hash)) {
 fixture(shape=>$s);$mode_writes=0;$r=run_check();
 ok(!$r->{ready},"S3 $s is fatal (not ready)");
 is($prepares,0,"S3 $s no job checked");
 is($mode_writes,0,"S3 $s no mode write");
 is(posts(qr{^/api/config$}),0,"S3 $s no signal change");
 ok((grep {($_->{name}||'') eq 'queue-preflight-context'} @{$r->{checks}}),"S3 $s reports queue-preflight-context error");
}
# ---- S9: modern readable path still probes, restores and verifies
fixture(shape=>'modern',specs=>[['sdr','filmMaker'],['hdr10','hdrFilmMaker']]);
my %orig_modes=%modes;my %orig_config=%config;$mode_writes=0;
$r=run_check();
ok($r->{ready},'S9 modern path ready') or diag explain $r->{checks};
is_deeply([map {$_->{status}} @{$r->{jobs}}],[qw(checked checked)],'S9 modern jobs are checked (not limited)');
ok($mode_writes>=2,'S9 modern path probes modes');
# A real run keeps the TV on the first job's signal and mode; the batch's
# end-of-run restoration owes the originals.
ok($r->{restore_deferred},'S9 modern restoration is handed to the batch');
is($config{signal_mode},'sdr','S9 modern check ends on the first job\'s signal');
is($modes{sdr},'filmMaker','S9 modern check ends on the first job\'s mode');
ok(PGAutomation::read_json_file($run_file)->{viewing_restore_required},'S9 modern batch owes the original viewing context');
ok($r->{restored},'S9 modern restoration obligation is accounted for');
# ---- S9b: modern read that echoes virtual on restoration read must fail
{
 fixture(shape=>'modern',specs=>[['sdr','filmMaker']]);$r=run_check();
 ok($r->{ready},'S9b setup');
 PGAutomation::with_lock($run_file,sub {$_[0]{viewing_restore_required}=JSON::PP::true;return $_[0];});
 $modes{hdr10}='hdrVivid';
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
 $shape='modern';
 my $ok=main::_restore_preflight_context('viewing');
 ok($ok,'S9b modern viewing restoration rewrites original mode');
 is($modes{hdr10},'hdrCinema','S9b original HDR10 mode restored');
}
# ---- S10: _prepare_job_context job start on C1 after limited preflight
{
 fixture(shape=>'c1',specs=>[['hdr10','hdrFilmMaker']]);$r=run_check();
 ok($r->{ready},'S10 setup ready');
 my $saved=PGAutomation::read_json_file($run_file);
 my $item=PGAutomation::clone($saved->{items}[0]);
 @calls=();$mode_writes=0;
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub{1};local *main::_log=sub{};local *main::_ensure_lg_connection=sub {1};
 my $ok=eval {main::_prepare_job_context(0,$item);1};
 ok($ok,'S10 C1 job start selects mode via accepted write and passes') or diag $@;
 is($mode_writes,1,'S10 exactly one accepted picture-mode write at job start');
 ok(PGAutomation::read_json_file($run_file)->{viewing_restore_required},'S10 viewing restoration obligation journalled at job start');
}
done_testing();
