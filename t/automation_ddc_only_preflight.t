use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";

# Regression for the ddc_only preflight lockout found on an OLED65C1PUB
# (lg2021_oled, webOS 6.5.3): pgenerator-lg reports picture_mode_read_forbidden
# permanently for that generation, and _preflight_read_mode treated that
# architectural ban like a transient failure -- dying before any job was
# checked, so the queue could never start. The fix returns an explicitly
# unverified context instead: mode probing and the mode-dependent part of
# restoration are skipped, the generator output and input still restore, and
# the reduced guarantee is recorded as a warning. Real runner/store/signal/
# restoration code; only TV/renderer/readiness responses are simulated.

my ($store,$run_id,$run_file,@calls,%config,$mode_ok);
sub fixture {
    $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;
    PGAutomation::ensure_store();
    $run_id='ddc-preflight';$run_file=PGAutomation::run_dir($run_id).'/run.json';
    local @ARGV=($run_id,'test-token');
    {local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/^Subroutine .* redefined at/;};
     do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
    @calls=();%config=(signal_mode=>'hdr10',eotf=>'1',primaries=>'9',colorimetry=>'9',color_format=>'0',
        rgb_quant_range=>'2',max_bpc=>'12',dv_map_mode=>'2');
    PGAutomation::write_json_atomic($run_file,{id=>$run_id,token=>'test-token',status=>'running',
        items=>[main::webui_automation_normalize_item({id=>'job-1',name=>'HDR10 Filmmaker',
            signal_format=>'hdr10',picture_mode=>'hdrFilmMaker',settings=>{},settle_seconds=>0,
            stages=>{calibration=>1,apply_all=>0}})],queue_revision=>0});
    PGAutomation::write_json_atomic("$store/execution.json",
        {owner=>'automation',run_id=>$run_id,token=>'test-token',status=>'running',pid=>0});
    PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'none'});
}

# A banned panel: the independent no-echo read (ignore_calibration_picture_mode)
# never answers a mode, while the requested-mode read echoes the requested
# selector back — that echo is what lets _apply_signal's readiness loop pass on
# a real C1 while preflight's no-echo read stays empty.
sub banned_response {
    # Like a real lg2021 panel: the key itself is answered (DDC path), only
    # the independent no-echo readback is foreclosed.
    return {status=>'ok',current_input=>'hdmi1',picture_settings=>{},
        picture_mode_read_forbidden=>JSON::PP::true,
        supported_picture_keys=>['pictureMode'],
        generation_profile=>{capability_profile_hash=>'b'x64,capability_profile_id=>'fixture',
            capability_library_valid=>1,capability_platform_profile_applied=>1}};
}
sub fake_api {
    my ($method,$path,$payload)=@_;
    push @calls,[$method,$path,PGAutomation::clone($payload)];
    if($path eq '/api/config') {
        return {%config} if $method eq 'GET';
        @config{keys %$payload}=values %$payload;
        return {status=>'ok'};
    }
    return {ok=>1} if $path eq '/api/ping';
    return {status=>'ok'} if $path eq '/api/pattern';
    if($path eq '/api/lg/picture-settings') {
        my $r=banned_response();
        $r->{picture_settings}={pictureMode=>$payload->{picture_mode}}
            if !$payload->{ignore_calibration_picture_mode} && ($payload->{picture_mode}||'') ne '';
        return $r;
    }
    if($path eq '/api/lg/picture-settings/set') {
        # The mode write is still attempted and accepted without readback.
        die 'Only pictureMode may be written during preflight'
            if join(',',sort keys %{$payload->{settings}||{}}) ne 'pictureMode';
        return banned_response();
    }
    if($path eq '/api/automation/readiness') {
        return {status=>'ok',ready=>1,checks=>[],items=>$payload->{items}} if $payload->{scope} eq 'batch';
        my $item=main::webui_automation_normalize_item($payload->{items}[0]);
        $item->{tv_input}='hdmi1';$item->{generation_profile}=banned_response()->{generation_profile};
        $item->{capability_profile}={hash=>'b'x64,id=>'fixture'};
        $item->{device_identity}={model_name=>'OLED65C1PUB',generation_id=>'lg2021_oled',firmware=>'test'};
        return {status=>'ok',ready=>1,items=>[$item],checks=>[{ok=>1,level=>'ok',message=>'Mode-specific controls checked'}]};
    }
    return {status=>'ok'} if $path eq '/api/meter/session/stop';
    die "Unexpected device operation $method $path";
}

fixture();
my $result;
{
    local *main::_api=\&fake_api;
    local *main::_sleep_controlled=sub {1};
    local *main::_log=sub {};
    local *main::_ensure_lg_connection=sub {1};
    $result=eval { main::_preflight_queue() };
}
ok($result,'whole-queue preflight completes on an architectural-read-ban panel (was: die before any job check)');
my @names=map {$_->{name}//''} @{$result->{checks}||[]};
ok(!(grep {/queue-preflight-context/} @names),'no queue-preflight-context error; the read ban no longer aborts setup');
is($result->{ready},1,'queue is ready');
is($result->{checked_items},1,'the pending job was actually checked (was 0/1 before the fix)');
my $context=PGAutomation::read_json_file(PGAutomation::run_dir($run_id).'/preflight-context.json');
is(ref($context),'HASH','preflight context saved');
is($context->{original}{verified},0,'saved original context is explicitly unverified');
is($context->{original}{picture_mode},'','no mode claimed on a banned panel');
is($context->{original}{mode_read_forbidden},JSON::PP::true,'the ban itself is recorded in the context');
is($context->{original}{tv_input},'hdmi1','the input is still captured and restorable');
is($result->{mode_restoration},'skipped-read-ban','mode restoration marked skipped-read-ban');
my ($warn)=grep {($_->{name}//'') eq 'queue-preflight-mode-restore'} @{$result->{checks}};
ok($warn && ($warn->{level}//'') eq 'warning','reduced restoration guarantee recorded as a warning, not silence');
is($result->{restored},1,'generator output and input restoration still completed');
my ($mode_write)=grep {$_->[1] eq '/api/lg/picture-settings/set'} @calls;
ok($mode_write,'picture-mode write still attempted (accepted without readback, labelled unverified)');

# A transient missing mode WITHOUT the ban flag must stay fatal: an empty
# pictureMode with no forbidden flag means the read failed, and nothing may
# proceed pretending the mode is merely unknown-but-permanent.
fixture();
sub broken_api {
    my ($method,$path,$payload)=@_;
    if($path eq '/api/config') {return {%config} if $method eq 'GET';@config{keys %$payload}=values %$payload;return {status=>'ok'};}
    return {ok=>1} if $path eq '/api/ping';
    if($path eq '/api/lg/picture-settings') {
        my $r=banned_response();$r->{picture_mode_read_forbidden}=JSON::PP::false;return $r;
    }
    return {status=>'ok'} if $path eq '/api/pattern';
    die "Unexpected operation $method $path";
}
my $broken=eval {
    local *main::_api=\&broken_api;
    local *main::_sleep_controlled=sub {1};
    local *main::_log=sub {};
    local *main::_ensure_lg_connection=sub {1};
    main::_preflight_queue();
};
ok(defined($broken) && !$broken->{ready} && !(grep {($_->{name}//"") eq "queue-preflight-job"} @{$broken->{checks}}), "a mode read that fails without the ban flag stays fatal at snapshot (context check, no job checked)");
is($broken->{checked_items},0,"no job runs under a fatal non-ban read failure");;

done_testing();
