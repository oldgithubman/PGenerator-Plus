use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
use PGAutomationPlan ();
require "$Bin/../usr/share/PGenerator/webui.pm";

# Real runner, file store, signal switching, mode selection, plan and restoration
# code. Only the external TV/renderer/readiness responses are simulated.
my ($run_id,$run_file,$store,@calls,%config,%modes,$profile,$input,$bad_job,$virtual,$restore_fail,$cancel,$prepares,$mode_writes,$use_real_transport,$legacy,$read_error,@checked_ids);
sub fixture {
    $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;
    PGAutomation::ensure_store();
    $run_id='whole-queue';$run_file=PGAutomation::run_dir($run_id).'/run.json';
    local @ARGV=($run_id,'test-token');
    {local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/^Subroutine .* redefined at/;};
     do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
    @calls=();%config=(signal_mode=>'sdr',eotf=>'0',primaries=>'0',colorimetry=>'2',color_format=>'0',rgb_quant_range=>'2',max_bpc=>'10',dv_map_mode=>'2');
    %modes=(sdr=>'expert1',hdr10=>'hdrCinema',dv=>'dolbyVisionCinemaBright');
    $profile='a'x64;$input='hdmi1';$bad_job=0;$virtual=0;$restore_fail=0;$cancel=0;$prepares=0;$mode_writes=0;$use_real_transport=0;$legacy=0;$read_error=0;@checked_ids=();
    my @specs=(['sdr','filmMaker'],['hdr10','hdrFilmMaker'],['dv','dolbyVisionFilmMaker'],['sdr','cinema']);
    my @items=map {main::webui_automation_normalize_item({id=>'job-'.($_+1),name=>'Job '.($_+1),signal_format=>$specs[$_][0],picture_mode=>$specs[$_][1],settings=>{},settle_seconds=>0,stages=>{calibration=>1,apply_all=>0}})} 0..$#specs;
    PGAutomation::write_json_atomic($run_file,{id=>$run_id,token=>'test-token',status=>'running',items=>\@items,queue_revision=>0});
    PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$run_id,token=>'test-token',status=>'running',pid=>0});
    PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'none'});
}
sub tv_response {
    return {status=>'error',message=>'Simulated transport read failure'} if $read_error;
    return {status=>'ok',current_input=>$input,picture_settings=>{pictureMode=>$modes{$config{signal_mode}}},
        supported_picture_keys=>['pictureMode'],virtual_picture_settings=>$virtual||$legacy,
        lg_generation=>{picture_mode_read_forbidden=>$legacy,ddc_only_white_balance=>$legacy},
        generation_profile=>{capability_profile_hash=>$profile,capability_profile_id=>'fixture',capability_library_valid=>1,capability_platform_profile_applied=>1,
            # The daemon's reply carries the whole capability table; a job must never keep it.
            settings_capabilities=>{contrast=>{min=>0,max=>100}},picture_mode_catalogue=>[{id=>'filmMaker'}]}};
}
sub fake_api {
    my ($method,$path,$payload)=@_;
    push @calls,[$method,$path,PGAutomation::clone($payload)];
    if($path eq '/api/config') {
        return {%config} if $method eq 'GET';
        return {status=>'error',message=>'Injected output restoration failure'} if $restore_fail && exists($payload->{dv_map_mode}) && $payload->{signal_mode} eq 'sdr';
        @config{keys %$payload}=values %$payload;
        return {status=>'ok'};
    }
    return {ok=>1} if $path eq '/api/ping';
    if($path eq '/api/pattern') {die 'Non-neutral preflight patch' if ($payload->{name}||'') ne 'gray50';return {status=>'ok'};}
    if($path eq '/api/lg/picture-settings') {
        return main::_api_once($method,$path,$payload,0) if $use_real_transport && $payload->{ignore_calibration_picture_mode};
        return tv_response();
    }
    if($path eq '/api/lg/picture-settings/set') {
        die 'Preflight attempted settings/LUT writes' if join(',',sort keys %{$payload->{settings}||{}}) ne 'pictureMode';
        $mode_writes++;$modes{$config{signal_mode}}=$payload->{settings}{pictureMode};return tv_response();
    }
    if($path eq '/api/automation/readiness') {
        return {status=>'ok',ready=>1,items=>$payload->{items},
            checks=>[map {{ok=>0,level=>'warning',name=>"item-$_-manual",item_number=>$_,message=>'TruMotion: verify Off'}} 0..$#{$payload->{items}}]}
            if $payload->{scope} eq 'batch';
        die 'Only one mode may be queried in its actual signal context' if @{$payload->{items}}!=1;
        $prepares++;
        my $raw=$payload->{items}[0];
        push @checked_ids,$raw->{id};
        die 'Readiness queried wrong signal context' if !$legacy && $raw->{signal_format} ne $config{signal_mode};
        die 'Readiness queried wrong picture context' if !$legacy && $raw->{picture_mode} ne $modes{$config{signal_mode}};
        if($cancel && $prepares==2) {PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'stop'});select undef,undef,undef,.55;}
        my $item=main::webui_automation_normalize_item($raw);
        $item->{tv_input}=$input;$item->{generation_profile}=tv_response()->{generation_profile};
        delete $item->{generation_profile} if $main::omit_generation_profile;
        # Real job readiness adds derived fields the intent hash does not exclude.
        $item->{panel_protection_supported}=JSON::PP::true;
        $item->{capability_profile}={hash=>$profile,id=>'fixture'};
        $item->{device_identity}={model_name=>'test LG',generation_id=>'lg2023_oled',firmware=>'test'};
        return {status=>'ok',ready=>0,checks=>[{ok=>0,level=>'error',message=>'Unsupported control in job four'}],message=>'Unsupported control in job four'} if $bad_job && $item->{id} eq 'job-4';
        return {status=>'ok',ready=>1,items=>[$item],checks=>[{ok=>1,level=>'ok',message=>'Mode-specific controls checked'},
            {ok=>1,level=>'ok',name=>'disk-space',message=>'Automation storage has '.(900-$prepares).'MB free'},
            {ok=>1,level=>'ok',name=>'meter-idle',message=>'Meter is idle'},
            {ok=>0,level=>'warning',name=>'item-0-manual',item_number=>0,message=>'TruMotion: verify Off'}]};
    }
    return {status=>'ok'} if $path eq '/api/meter/session/stop';
    die "Unexpected device operation $method $path";
}
sub run_check {
    local *main::_api=\&fake_api;
    local *main::_sleep_controlled=sub {1};
    local *main::_log=sub {};
    local *main::_ensure_lg_connection=sub {1};
    return main::_preflight_queue();
}
fixture();
my %original=%config;my %original_modes=%modes;
my $r=run_check();
ok($r->{ready},'every job passes against its actual signal and selected picture mode') or diag explain $r;
is($r->{checked_items},4,'not just the first job is live checked');
is($r->{progress_total},15,'four-job preflight includes equipment, snapshot, three checks per job and restoration');
is($r->{progress_done},15,'successful real preflight completes every reported progress operation');
is_deeply([map {$_->{status}} @{$r->{jobs}}],[('checked')x4],'all four jobs carry individual results');
# P2: the batch pass and each job pass both report a job's manual check;
# equipment checks repeated by every job pass stay global.
is_deeply([sort map {$_->{item_number}} grep {$_->{message} eq 'TruMotion: verify Off'} @{$r->{checks}}],[0,1,2,3],'each job lists its manual check once');
is(scalar(grep {$_->{message} eq 'Mode-specific controls checked'} @{$r->{checks}}),1,'an equipment check repeated by every job pass is listed once');
ok(!grep({$_->{message} eq 'Mode-specific controls checked' && defined $_->{item_number}} @{$r->{checks}}),'and is not attributed to a job');
is(scalar(grep {($_->{name}||'') eq 'disk-space'} @{$r->{checks}}),1,'an equipment check whose text varies between passes is still listed once');
# A real run keeps the TV where the check left it and owes the originals to
# its own end-of-run restoration (18 Sep 2026: restoring every signal only
# for job 1 to switch away again cost ~5 min per batch on the G3).
is_deeply(\@checked_ids,[qw(job-4 job-3 job-2 job-1)],'the last job is checked first so the check ends on job 1');
is($config{signal_mode},'sdr','the check ends on the first job\'s signal');
is($modes{sdr},'filmMaker','and on the first job\'s picture mode');
is($modes{hdr10},'hdrFilmMaker','other signals stay as the check left them');
ok($r->{restore_deferred},'restoration is handed to the batch');
like($r->{message},qr/restored when the batch finishes/,'and the result says so');
ok($r->{restored},'the restoration obligation is accounted for');
my $saved=PGAutomation::read_json_file($run_file);
ok(!$saved->{preflight_restore_required},'the check itself owes nothing');
is($saved->{preflight_restore_outcome},'deferred-to-batch','and records why');
ok($saved->{viewing_restore_required},'the batch owes the original viewing context from now on');
is_deeply([sort keys %{$saved->{mode_written_signals}}],[qw(dv hdr10 sdr)],'the mode journal keeps the check\'s marks for that restoration');
is($saved->{preflight_revision},0,'successful plan is tied to the exact queue revision');
ok(!main::webui_automation_cleanup_required($saved),'successful preflight leaves no recovery obligation');
for my $item (@{$saved->{items}}) {ok(PGAutomationPlan::matches($item,$item->{preflight_contract}),'frozen execution matches the verified plan');}
for my $item (@{$saved->{items}}) {is($item->{readiness}{scope},'queue-preflight','each job carries the check as its readiness record');}
ok(!grep({exists($_->{generation_profile}{settings_capabilities}) || exists($_->{generation_profile}{picture_mode_catalogue})} @{$saved->{items}}),'no job keeps the TV capability catalogues the readiness reply carries');
ok(!exists($saved->{preflight_result}{checks}),'the manifest keeps the verdict, not the check list');
is(scalar(@{PGAutomation::read_json_file(PGAutomation::run_dir($run_id).'/preflight-plan.json')->{result}{checks}}),scalar(@{$r->{checks}}),'the plan keeps every check');
ok(-f PGAutomation::run_dir($run_id).'/status.json','the check publishes the live status');
is(scalar(grep {$_->[1]=~/reset|lut|autocal|meter\/read/} @calls),0,'preflight sends no reset, LUT upload or meter measurement');
{
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub{1};local *main::_log=sub{};
 my $item=PGAutomation::clone($saved->{items}[0]);
 @calls=();
 ok(eval {main::_prepare_job_context(0,$item);1},'fresh job checks accept the unchanged frozen plan') or diag $@;
 is(scalar(grep {$_->[1] eq '/api/automation/readiness'} @calls),0,'job start asks for no readiness; the whole-queue check is trusted');
 is(scalar(grep {$_->[0] eq 'POST' && $_->[1] eq '/api/config'} @calls),0,'job 1 needs no output switch after the check');
 is(scalar(grep {$_->[1] eq '/api/lg/picture-settings/set'} @calls),0,'nor a picture-mode write');
 is(scalar(grep {$_->[1] eq '/api/lg/picture-settings'} @calls),1,'one identity read guards the frozen plan');
 $input='hdmi2';
 ok(!eval {main::_prepare_job_context(0,$item);1},'changed input blocks the job before settings or calibration');
 like($@,qr/stale|input|compatibility/,'input change has an actionable error');
 $input='hdmi1';$profile='b'x64;
 ok(!eval {main::_prepare_job_context(0,$item);1},'changed compatibility signature blocks the job');
 $profile='a'x64;$item->{settings}{brightness}=53;
 ok(!eval {main::_prepare_job_context(0,$item);1},'changed job options cannot reuse an old plan');
 like($@,qr/stale/,'settings change requests fresh queue preflight');
}
fixture();$bad_job=1;%original=%config;%original_modes=%modes;
$r=run_check();
ok(!$r->{ready},'an incompatible fourth job blocks the entire queue');
is($prepares,4,'the incompatible late job is discovered upfront');
is($r->{jobs}[3]{status},'blocked','specific late job is named');
is_deeply(\%modes,\%original_modes,'blocked preflight still restores every changed picture mode');
ok($r->{restored},'blocked result carries restoration confirmation');
ok(!exists(PGAutomation::read_json_file($run_file)->{preflight_revision}),'blocked queue has no executable plan');
is(scalar(grep {$_->[1]=~/reset|lut|autocal|meter\/read/} @calls),0,'late incompatibility never reaches a destructive command');
fixture();$virtual=1;
$r=run_check();
ok(!$r->{ready},'unreadable/echoed original mode blocks reversible probing');
is($mode_writes,0,'no TV mode is changed without a restorable original mode');
is(scalar(grep {$_->[0] eq 'POST' && $_->[1] eq '/api/config'} @calls),0,'no output is changed before original context can be captured');
fixture();$legacy=1;
$r=run_check();
ok($r->{ready},'reviewed legacy mode-readback limitation does not block the queue') or diag explain $r;
is($r->{verification_state},'limited','legacy result is explicitly limited rather than live-mode verified');
is($r->{checked_items},4,'legacy path still checks every pending scoped job');
is($mode_writes,0,'legacy preflight never probes picture modes it cannot restore');
is(scalar(grep {$_->[0] eq 'POST' && $_->[1] eq '/api/config'} @calls),0,'legacy preflight leaves generator output untouched');
my $legacy_context=PGAutomation::read_json_file(PGAutomation::run_dir($run_id).'/viewing-context.json');
is($legacy_context->{original}{picture_mode},'','virtual selector cannot become a restoration target');
is_deeply($legacy_context->{modes},{},'no unverified mode is saved for later restoration');
fixture();$legacy=1;$read_error=1;
$r=run_check();
ok(!$r->{ready},'a real read failure is not waived by a legacy limitation');
is($prepares,0,'failed independent input/profile read blocks before jobs');
fixture();$cancel=1;%original_modes=%modes;
$r=run_check();
ok(!$r->{ready},'cancelled preflight cannot become ready');
is($prepares,2,'Stop prevents checking the remaining jobs');
ok(!$r->{restored} && $r->{restore_skipped} eq 'stop','Stop records that original modes were not restored');
is_deeply(\%modes,{%original_modes,sdr=>'cinema',dv=>'dolbyVisionFilmMaker'},'Stop leaves modes where the interrupted checks left them');
# A check-only run restores now; a failed restoration must block it.
fixture();$restore_fail=1;
PGAutomation::with_lock($run_file,sub {$_[0]{preflight_only}=JSON::PP::true;return $_[0];});
$r=run_check();
ok(!$r->{ready} && !$r->{restored},'failed restoration blocks an otherwise compatible queue');
ok(PGAutomation::read_json_file($run_file)->{preflight_restore_required},'restoration journal obligation persists');
{
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub{1};local *main::_log=sub{};
 main::_finish('failed',{stage=>'queue-preflight',message=>'Restoration failed'});
 is(PGAutomation::read_json_file($run_file)->{status},'interrupted','failed restoration stays recoverable');
 ok(-f "$store/execution.json",'failed restoration retains exclusive device ownership');
 $restore_fail=0;
 ok(main::_restore_preflight_context(),'a later retry uses the saved restoration journal');
 ok(!PGAutomation::read_json_file($run_file)->{preflight_restore_required},'successful retry clears restoration obligation');
}
{
 my $original={settings=>{brightness=>50},picture_mode=>'cinema',signal_format=>'sdr',tv_input=>'hdmi1',capability_profile=>{hash=>'a'x64},device_identity=>{firmware=>'1'}};
 my $contract=PGAutomationPlan::contract($original);
 my $changed=PGAutomation::clone($original);$changed->{status}='running';$changed->{checkpoints}=[{name=>'item-started',status=>'done'}];
 ok(PGAutomationPlan::matches($changed,$contract),'runtime progress does not invalidate execution intent');
 $changed->{some_future_execution_option}=1;
 ok(!PGAutomationPlan::matches($changed,$contract),'future execution options invalidate old plans by default');
 $changed=PGAutomation::clone($original);$changed->{device_identity}{firmware}='2';
 ok(!PGAutomationPlan::matches($changed,$contract),'device identity changes invalidate plans');
 my $numeric={%$original,calibration=>{solve_cube_size=>17,shadow_fix=>0,target_delta_e=>0.5},delay_ms=>1000};
 my $numeric_contract=PGAutomationPlan::contract($numeric);
 my $drifted=PGAutomation::clone($numeric);
 $drifted->{calibration}={solve_cube_size=>'17',shadow_fix=>'0',target_delta_e=>'0.50'};$drifted->{delay_ms}='1000';$drifted->{settings}{brightness}='50';
 ok(PGAutomationPlan::matches($drifted,$numeric_contract),'numbers that come back as numeric strings still match the plan');
 $drifted->{calibration}{solve_cube_size}='33';
 ok(!PGAutomationPlan::matches($drifted,$numeric_contract),'a genuinely different value still invalidates the plan');
 ok(!main::_replan_exhausted(7)&&!main::_replan_exhausted(7)&&main::_replan_exhausted(7),'a job that keeps failing its claim after re-checks stops the run instead of looping');
 ok(!main::_replan_exhausted(8),'the re-check budget is per job');
 my $normalized=main::webui_automation_normalize_item({%$original,preflight_contract=>$contract});
 ok(!exists($normalized->{preflight_contract}),'HTTP input cannot forge a server preflight contract');
}

# Actual _main orchestration. The handshake is stubbed only in this test; the
# separate launcher test exercises its real process/locking/acceptance path.
for my $scenario (qw(blocked check-only run)) {
 fixture();$bad_job=$scenario eq 'blocked';
 PGAutomation::with_lock($run_file,sub {$_[0]{preflight_only}=1 if $scenario eq 'check-only';return $_[0];});
 my $executed=0;
 local *PGAutomationLaunch::worker_handshake=sub {return 1;};
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub{1};local *main::_log=sub{};
 local *main::_run_item=sub {
  $executed++;
  is($prepares,4,'all jobs were live checked before the first calibration stage');
  my ($number,$item)=@_;$item->{status}='complete';
  main::_update_run(sub {$_[0]{items}[$number]=$item;});return 1;
 };
 ok(eval {main::_main();1},"$scenario actual runner main completes without unexpected device commands") or diag $@;
 is($executed,$scenario eq 'run'?4:0,"$scenario executes calibration only after the entire queue passed and execution was requested");
 is(PGAutomation::read_json_file($run_file)->{status},$scenario eq 'blocked'?'failed':'complete',"$scenario terminal status reflects the actual outcome");
 ok(!-f "$store/execution.json","$scenario safely restored run releases its own claim");
}
fixture();$r=run_check();
{
 local *main::_log=sub{};
 PGAutomation::with_lock($run_file,sub {$_[0]{queue_revision}=1;return $_[0];});
 my ($claimed,$changed)=main::_claim_queue_item(0);
 ok($changed,'an edit between optimistic check and claim cannot bypass preflight');
 isnt($claimed->{items}[0]{status}||'queued','running','unverified revision is not claimed for execution');
 PGAutomation::with_lock($run_file,sub {$_[0]{queue_revision}=0;$_[0]{items}[0]{settings}{brightness}=56;return $_[0];});
 ($claimed,$changed)=main::_claim_queue_item(0);
 ok($changed,'even a changed option without a revision bump is rejected');
 ok(!defined($claimed->{preflight_revision}),'changed intent forces full preflight on the next loop');
 # A Pause during job 1 leaves the job carrying what its own stages measured.
 # That must not throw away the whole-queue check the Resume just reused (P13),
 # while a TV that changed underneath still forces a re-check.
 PGAutomation::with_lock($run_file,sub {
  $_[0]{queue_revision}=0;$_[0]{preflight_revision}=0;
  my $item=$_[0]{items}[0];
  $item->{settings}{brightness}=50;
  $item->{preflight_contract}=PGAutomationPlan::contract($item);
  $item->{checkpoints}=[{name=>'panel-light-settled',status=>'done'}];
  $item->{status}='queued';
  $item->{target_luminance}=411.328618;
  $item->{calibration}{headroom_target_luminance}=511.144543231037;
  return $_[0];});
 ($claimed,$changed)=main::_claim_queue_item(0);
 ok(!$changed,'a resumed job keeps the reused queue check despite its own measured values');
 is($claimed->{items}[0]{status},'running','the resumed job is admitted for execution');
 is($claimed->{preflight_revision},0,'and the verified plan revision survives the claim');
 PGAutomation::with_lock($run_file,sub {$_[0]{items}[0]{status}='queued';$_[0]{items}[0]{tv_input}='hdmi2';return $_[0];});
 ($claimed,$changed)=main::_claim_queue_item(0);
 ok($changed,'a resumed job on a different TV input still forces a full re-check');
 ok(!defined($claimed->{preflight_revision}),'and drops the verified plan revision');
 PGAutomation::with_lock($run_file,sub {
  my $item=$_[0]{items}[0];
  $item->{tv_input}=$item->{preflight_contract}{tv_input};$item->{status}='queued';
  $_[0]{preflight_revision}=0;delete $item->{checkpoints};
  $item->{target_luminance}=411.328618;
  return $_[0];});
 ($claimed,$changed)=main::_claim_queue_item(0);
 ok($changed,'a job that never started is still held to its exact frozen intent');
 PGAutomation::with_lock($run_file,sub {$_[0]{items}=[{name=>'Already done',status=>'complete'}];return $_[0];});
 @calls=();$r=run_check();
 ok($r->{ready},'a resumed run with no pending jobs can finish without re-calibrating');
 is(scalar @calls,0,'already complete queue needs no mode switching or TV reads');
}
{
 my $calls=0;
 local *main::webui_automation_start=sub {$calls++;ok($_[0]{preflight_only},'Check Readiness creates a check-only owned run');return '{"status":"started","run_id":"check-only"}';};
 my $r=PGAutomation::decode_json(main::webui_automation_api('/api/automation/readiness','POST','{"scope":"queue","items":[]}'));
 is($r->{error_code},'preflight-consent-required','API requires consent before switching modes for a check');
 is($calls,0,'no preflight run launched without consent');
 $r=PGAutomation::decode_json(main::webui_automation_api('/api/automation/readiness','POST','{"scope":"queue","confirm_mode_switches":true,"items":[]}'));
 is($calls,1,'explicit consent reaches owned preflight startup');
 $r=PGAutomation::decode_json(main::webui_automation_api('/api/automation/readiness','POST','{"scope":"job","automation_token":"forged"}'));
 is($r->{error_code},'automation-owner-mismatch','a forged token cannot request internal live job probing');
}
fixture();$use_real_transport=1;
{
 local *HTTP::Tiny::request=sub {
  my ($client,$method,$url,$options)=@_;
  # Runs in the real transport subprocess. Capture the encoded request rather
  # than inspecting a pre-transport mock which would miss context injection.
  PGAutomation::append_line_locked("$store/independent-requests.ndjson",$options->{content}."\n");
  return {success=>1,status=>200,content=>PGAutomation::encode_json(tv_response())};
 };
 $r=run_check();
 ok($r->{ready},'whole preflight also passes through the actual scoped HTTP transport');
 my @requests=map {PGAutomation::decode_json($_)} split /\n/,PGAutomation::read_raw("$store/independent-requests.ndjson");
 ok(@requests>4,'independent snapshots reached the actual transport multiple times');
 is(scalar(grep {exists($_->{picture_mode}) || exists($_->{expected_tv_input})} @requests),0,'snapshot reads never inherit the queued mode or a guessed input');
 is(scalar(grep {!$_->{ignore_calibration_picture_mode}} @requests),0,'every snapshot explicitly ignores cached calibration selection');
}

for my $limited (0,1) {
 fixture();$legacy=$limited;my %saved_config=%config;my %saved_modes=%modes;
 $r=run_check();ok($r->{ready},'viewing restoration fixture passed preflight');
 is(PGAutomation::read_json_file($run_file)->{items}[0]{preflight_contract}{limited}?1:0,$limited,'P24: a limited preflight marks its plan contracts as limited');
 # Simulate the calibration workflow selecting its final signal/mode.
 $config{signal_mode}='dv';$config{max_bpc}='8';$modes{dv}='dolbyVisionFilmMaker';$modes{sdr}='filmMaker';
 # The workflow's mode writes are journalled against their signals (P14),
 # alongside the marks the queue check left there.
 PGAutomation::with_lock($run_file,sub {$_[0]{viewing_restore_required}=1;$_[0]{mode_written_signals}{$_}{job}=JSON::PP::true for qw(dv sdr);return $_[0];});
 @calls=();
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
 ok(main::_restore_preflight_context('viewing'),'run-level original output restoration succeeds');
 is_deeply({map {$_=>$config{$_}} keys %saved_config},\%saved_config,'original generator transport is restored after calibration, not only after preflight');
 my $restored=PGAutomation::read_json_file($run_file);
 ok(!$restored->{viewing_restore_required},'confirmed restoration clears its own obligation');
 if($limited) {
  is(scalar(grep {$_->[1] eq '/api/lg/picture-settings/set'} @calls),0,'legacy restoration never writes a guessed original picture mode');
  is($restored->{viewing_restore_outcome},'output-restored-mode-unavailable','legacy restoration labels its limited evidence');
 } else {
  is_deeply(\%modes,\%saved_modes,'readable per-signal original picture modes are restored');
 }
 is(scalar(grep {$_->[1]=~/reset|lut|autocal/} @calls),0,'viewing restoration never overwrites newly calibrated LUTs');
}
# Stop between the check and job 1 keeps the current modes and signal too.
{
 fixture();my %saved_config=%config;my %saved_modes=%modes;
 ok(run_check()->{ready},'stop window: the queue was checked');
 my %current_config=%config;my %current_modes=%modes;
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
 main::_finish('stopped',{stage=>'queue-preflight',message=>'Automation stopped'});
 my $stopped=PGAutomation::read_json_file($run_file);
 is($stopped->{status},'stopped','stop window: the run stops cleanly');
 is_deeply(\%modes,\%current_modes,'stop window: modes stay where the check left them');
 is_deeply(\%config,\%current_config,'stop window: the generator output stays unchanged');
 ok(!$stopped->{viewing_restore_required},'stop window: nothing is left owed');
}
# Stop takes the same short path regardless of the normal finish policy.
{
 fixture();my %saved_modes=%modes;
 PGAutomation::with_lock($run_file,sub {$_[0]{finish_policy}='keep-last';return $_[0];});
 ok(run_check()->{ready},'keep-last: the queue was checked');
 # Job 1 (SDR) ran and selected its mode; HDR10 and DV were only checked.
 PGAutomation::with_lock($run_file,sub {$_[0]{mode_written_signals}{sdr}{job}=JSON::PP::true;return $_[0];});
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
 @calls=();
 main::_finish('stopped',{stage=>'item',message=>'Automation stopped'});
 my $kept=PGAutomation::read_json_file($run_file);
 is($modes{sdr},'filmMaker','keep-last: the mode a job selected is kept');
 is($modes{hdr10},'hdrFilmMaker','keep-last Stop does not revisit HDR10');
 is($modes{dv},'dolbyVisionFilmMaker','keep-last Stop does not revisit DV');
 is($config{signal_mode},'sdr','keep-last: the generator returns to the output the last job left');
 is($kept->{viewing_restore_outcome},'skipped-on-stop','keep-last Stop records skipped restoration');
 ok(!$kept->{viewing_restore_required},'keep-last: nothing is left owed');
}
{
 # When every checked signal was later selected by a job there is nothing to
 # return, and the TV is not touched at all.
 fixture();
 PGAutomation::with_lock($run_file,sub {$_[0]{finish_policy}='keep-last';return $_[0];});
 ok(run_check()->{ready},'keep-last, all selected: the queue was checked');
 PGAutomation::with_lock($run_file,sub {$_[0]{mode_written_signals}{$_}{job}=JSON::PP::true for qw(sdr hdr10 dv);return $_[0];});
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
 @calls=();
 main::_finish('complete');
 my $kept=PGAutomation::read_json_file($run_file);
 is($kept->{status},'complete','keep-last, all selected: the batch completes');
 is($kept->{viewing_restore_outcome},'kept-last','keep-last, all selected: the outcome is recorded');
 is(scalar(grep {$_->[1]=~m{^/api/(?:config|lg/|pattern)} && !($_->[0] eq 'GET' && $_->[1] eq '/api/config')} @calls),0,'keep-last, all selected: no output switch, TV read or mode write at the end');
}
{
    # With job 1 already complete the batch pass numbers pending jobs from 0;
    # they must still be reported against their queue position.
    fixture();
    PGAutomation::with_lock($run_file,sub {$_[0]{items}[0]{status}='complete';return $_[0];});
    my $partial=run_check();
    ok($partial->{ready},'a queue with a completed first job still passes');
    is_deeply([sort map {$_->{item_number}} grep {$_->{message} eq 'TruMotion: verify Off'} @{$partial->{checks}}],[1,2,3],'manual checks name the pending jobs by queue position, once each, and never the completed job');
}
# P13: reuse a still-valid whole-queue check on Resume, or straight after a
# passing Check Readiness for the same queue on the same TV.
sub reuse_for {
    my ($file)=@_;
    local *main::_api=\&fake_api;
    local *main::_sleep_controlled=sub {1};
    local *main::_log=sub {};local *main::_log_action=sub {};
    local *main::_ensure_lg_connection=sub {1};
    return main::_reusable_preflight(PGAutomation::read_json_file($file));
}
{
    fixture();
    ok(run_check()->{ready},'resume fixture: the queue was checked');
    PGAutomation::with_lock($run_file,sub {$_[0]{resumed_at}=time();return $_[0];});
    my ($walks,$writes)=($prepares,$mode_writes);
    my $reused=reuse_for($run_file);
    ok($reused && $reused->{reused},'a resume on the same TV with an unchanged queue reuses the check');
    is($prepares,$walks,'no job is walked through its mode again');
    is($mode_writes,$writes,'and no picture mode is written');
    like(PGAutomation::read_json_file($run_file)->{preflight_result}{message},qr/earlier whole-queue check still applies/,'the reuse is visible in the run');
    ok(!exists(PGAutomation::read_json_file($run_file)->{preflight_result}{checks}),'and puts no check list back into the manifest');
    ok(scalar(@{PGAutomation::read_json_file("$store/preflight.json")->{checks}||[]})>0,'while the visible status keeps the checks');
    unlike(PGAutomation::read_json_file($run_file)->{preflight_result}{message},qr/rechecked/,'and no longer promises a per-job recheck');
    PGAutomation::with_lock($run_file,sub {$_[0]{preflight_result}{completed_at}-=3*24*3600;return $_[0];});
    ok(reuse_for($run_file),'a resume days later still reuses it: the queue and the TV identity decide, not the clock');
    $profile='b'x64;
    ok(!reuse_for($run_file),'a changed compatibility profile forces the full check');
    $profile='a'x64;$input='hdmi2';
    ok(!reuse_for($run_file),'a changed input forces the full check');
    $input='hdmi1';
    PGAutomation::with_lock($run_file,sub {$_[0]{queue_revision}=1;return $_[0];});
    ok(!reuse_for($run_file),'an edited queue forces the full check');
    PGAutomation::with_lock($run_file,sub {$_[0]{queue_revision}=0;delete $_[0]{resumed_at};return $_[0];});
    ok(!reuse_for($run_file),'a fresh start without a readiness result runs the full check');
}
for my $case ('same','mode-changed','queue-changed','stale','output-changed') {
    fixture();
    my $pristine=PGAutomation::read_json_file($run_file)->{items};
    PGAutomation::with_lock($run_file,sub {$_[0]{preflight_only}=JSON::PP::true;return $_[0];});
    ok(run_check()->{ready},"$case: Check Readiness passed");
    ok(-f "$store/last-readiness.json","$case: a passing Check Readiness leaves a single-use pointer");
    my $second="batch-$case";my $second_file=PGAutomation::run_dir($second).'/run.json';
    my $items=PGAutomation::clone($pristine);
    $items->[1]{picture_mode}='hdrCinema' if $case eq 'queue-changed';
    PGAutomation::write_json_atomic($second_file,{id=>$second,token=>'second-token',status=>'running',items=>$items,queue_revision=>0});
    PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$second,token=>'second-token',status=>'running',pid=>0});
    {local @ARGV=($second,'second-token');local $SIG{__WARN__}=sub {};do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
    $modes{sdr}='cinema' if $case eq 'mode-changed';
    $config{max_bpc}='12' if $case eq 'output-changed';
    PGAutomation::with_lock("$store/last-readiness.json",sub {$_[0]{completed_at}-=3600;return $_[0];}) if $case eq 'stale';
    my $walks=$prepares;
    my $adopted=reuse_for($second_file);
    ok(!-f "$store/last-readiness.json","$case: the pointer is consumed");
    if ($case ne 'same') {
        ok(!$adopted,"$case: the readiness result is not reused");
        next;
    }
    ok($adopted && ($adopted->{reused_from}||'') eq $run_id,'Run queue straight after Check Readiness reuses its whole-queue check');
    is($prepares,$walks,'no job is walked again');
    my $saved=PGAutomation::read_json_file($second_file);
    ok(ref($saved->{items}[0]{preflight_contract}) eq 'HASH','the batch adopts the checked plan contracts');
    is($saved->{preflight_revision},0,'the adopted plan is tied to the queue revision');
    my $adopted_plan=PGAutomation::read_json_file(PGAutomation::run_dir($second).'/preflight-plan.json');
    ok(ref($adopted_plan) eq 'HASH' && @{$adopted_plan->{result}{checks}||[]}>0,'the batch keeps its own copy of the plan and its checks');
    # A Resume of that batch reads the check list from there.
    PGAutomation::with_lock($second_file,sub {$_[0]{resumed_at}=time();return $_[0];});
    my $resumed=reuse_for($second_file);
    ok($resumed && $resumed->{reused} && @{$resumed->{checks}||[]}>0,'a resume of an adopted batch still lists the checks');
    ok(scalar(@{PGAutomation::read_json_file("$store/preflight.json")->{checks}||[]})>0,'and keeps them in the visible status');
    ok(-f PGAutomation::run_dir($second).'/viewing-context.json','the original viewing context is kept for restoration');
    is(PGAutomation::read_json_file("$store/preflight.json")->{run_id},$second,'the startup status names the batch that reused the check');
}
{
    # F1-n (P22): the limited branch drops a job's saved TV context before its
    # readiness pass, so stale identity cannot survive when readiness omits it.
    fixture();$legacy=1;$main::omit_generation_profile=1;
    PGAutomation::with_lock($run_file,sub {$_[0]{items}[0]{generation_profile}={capability_profile_hash=>'stale-context'};return $_[0];});
    ok(run_check()->{ready},'a limited preflight with stale saved job context passes');
    isnt((PGAutomation::read_json_file($run_file)->{items}[0]{generation_profile}||{})->{capability_profile_hash}||'','stale-context','the stale generation profile is not carried into the checked plan');
    $main::omit_generation_profile=0;
}
{
    # A global check that fails only in a later job's pass is kept, and the
    # job it stopped is still named by its own queue-preflight-job error.
    fixture();
    my $real=\&fake_api;
    local *main::_api=sub {
        my ($method,$path,$payload)=@_;
        my $reply=$real->(@_);
        if($path eq '/api/automation/readiness' && ($payload->{scope}||'') eq 'job' && ($payload->{items}[0]{id}||'') eq 'job-3') {
            return {status=>'blocked',ready=>0,checks=>[{ok=>0,level=>'error',name=>'meter-idle',message=>'Stop the active meter operation before starting automation'}],message=>'Startup blocked'};
        }
        if($path eq '/api/automation/readiness' && ($payload->{scope}||'') eq 'job' && ($payload->{items}[0]{id}||'') eq 'job-4') {
            return {status=>'blocked',ready=>0,checks=>[{ok=>0,level=>'error',name=>'meter-idle',message=>'A guided meter series is running'}],message=>'Startup blocked'};
        }
        return $reply;
    };
    local *main::_sleep_controlled=sub {1};local *main::_log=sub {};local *main::_ensure_lg_connection=sub {1};
    my $late=main::_preflight_queue();
    ok(!$late->{ready},'a global failure in a later job pass blocks the queue');
    ok(grep({($_->{name}||'') eq 'meter-idle' && !$_->{ok}} @{$late->{checks}}),'the failing global check is listed despite an earlier passing one');
    is(scalar(grep {($_->{name}||'') eq 'meter-idle' && !$_->{ok}} @{$late->{checks}}),2,'a different failure reason in a later job pass is listed too');
    ok(grep({($_->{name}||'') eq 'queue-preflight-job' && ($_->{item_number}//-1)==2} @{$late->{checks}}),'and the stopped job is named');
}
# P22 guards on the runner main flow (H-complete-warnings, H-main-terminal,
# H-preflight-fail-hazards).
{
    fixture();
    local *PGAutomationLaunch::worker_handshake=sub {1};
    local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
    local *main::_run_item=sub {my ($number,$item)=@_;$item->{status}='complete-with-warnings';$item->{warnings}=['check me'];main::_update_run(sub {$_[0]{items}[$number]=$item;});return 1;};
    ok(eval {main::_main();1},'a batch whose jobs warn runs to the end') or diag $@;
    is(PGAutomation::read_json_file($run_file)->{status},'complete-with-warnings','and finishes complete-with-warnings, not complete');
    my $calls=0;
    local *main::_api=sub {$calls++;die 'a finished run must not touch devices'};
    ok(eval {main::_main();1},'starting the runner on a complete-with-warnings run returns');
    is($calls,0,'without any device call');
}
{
    fixture();
    my $restores=0;my $real_restore=\&main::_restore_run_hazards;
    local *PGAutomationLaunch::worker_handshake=sub {1};
    local *main::_api=\&fake_api;local *main::_sleep_controlled=sub {1};local *main::_log=sub {};
    local *main::_restore_run_hazards=sub {$restores++;$real_restore->(@_)};
    local *main::_run_item=sub {
        my ($number,$item)=@_;$item->{status}='complete';
        # The queue is edited mid-batch and the new plan fails its re-check.
        main::_update_run(sub {$_[0]{items}[$number]=$item;$_[0]{queue_revision}=($_[0]{queue_revision}||0)+1;});
        $bad_job=1;return 1;
    };
    ok(eval {main::_main();1},'a batch whose edited queue fails its re-check stops') or diag $@;
    is(PGAutomation::read_json_file($run_file)->{status},'failed','the batch fails');
    ok($restores>0,'and protective settings are restored before it finishes');
    $bad_job=0;
}
done_testing();
