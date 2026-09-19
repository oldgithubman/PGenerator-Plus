# Adversarial F3 check (agent BC): two jobs, each pre-readings series ->
# greyscale AutoCal -> post-readings series, through the REAL runner
# _stage/_run_series/_start_worker/_wait_worker/_snapshot_series/
# _calibration_greyscale_stage, the REAL webui series status route
# (webui_meter_series_status, state file redirected), the REAL daemon seed/
# replay helpers, and the REAL meter_series.sh state writer executed in bash.
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;
my $WT;BEGIN{$WT="$Bin/.."||die "set WT"}
use lib "$WT/usr/share/PGenerator";
use PGAutomation ();
require "$WT/usr/share/PGenerator/webui.pm";
$ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
my $id='f3-two-jobs';
{local @ARGV=($id,'test-token');local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/redefined/};do "$WT/usr/bin/pgen_automation_runner.pl";die $@ if $@;}
PGAutomation::ensure_store();
my $tmp=tempdir(CLEANUP=>1);
$main::_meter_series_file="$tmp/meter_series.json";
my $grey_file="$tmp/meter_lg_autocal.json";
my $run_path=PGAutomation::run_dir($id).'/run.json';
my $item_tpl={signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>1,pre_readings=>1,post_readings=>1},
  pre_series=>['greyscale-21','colors-30'],post_series=>['greyscale-21','colors-30']};
PGAutomation::write_json_atomic($run_path,{id=>$id,token=>'test-token',status=>'running',items=>[PGAutomation::clone($item_tpl),PGAutomation::clone($item_tpl)]});
PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/control.json',{request=>'none'});

# ---- production shell functions
open my $fh,'<',"$WT/usr/bin/meter_series.sh" or die;my $src=do{local $/;<$fh>};close $fh;
my @fn;for my $n (qw(series_state_claim_lost load_series_identity_meta write_state_json)) {my ($f)=$src=~/^($n\(\) \{.*?^\})/ms;die "missing $n" if !$f;push @fn,$f;}
my $functions=join("\n",@fn);$functions=~s{/tmp/meter_series_debug\.log}{$tmp/debug.log}g;
sub shell_worker {
    my ($series_id,@payloads)=@_;
    my $script="set -e\nSTATE_FILE='$main::_meter_series_file'\nSERIES_ID='$series_id'\nSERIES_META_JSON=''\nSERIES_META_LOADED=''\nSERIES_WORKER_META_JSON=''\nchown() { :; }\n$functions\n";
    $script.="write_state_json <<'PAYLOAD'\n$_\nPAYLOAD\n" for @payloads;
    my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;my $o=do{local $/;<$out>};my $e=do{local $/;<$err>};waitpid($pid,0);
    die "shell worker failed: $e" if $?;
}
my ($job,@posts,%mode)=(0);
my $series_n=0;my $pending;my $grey_pending;my @grey_posts;my @adopted;
my $series_alive=1;
local *main::webui_meter_series_alive=sub {$series_alive};
local *main::_active_item_number=sub {$job};
local *main::_log=sub {};local *main::_log_action=sub {};
local *main::_sleep_controlled=sub {1};
local *main::_set_dv_map=sub {1};
local *main::_worker_process_alive=sub {0};
sub series_start {
    my ($payload)=@_;
    my $body=PGAutomation::encode_json({%$payload,automation_token=>'test-token'});
    push @posts,PGAutomation::worker_id($payload);
    my $replayed=PGAutomation::worker_replay_json($body,$main::_meter_series_file);
    return PGAutomation::decode_json($replayed) if $replayed ne '';
    if ($mode{drop_post_once}) {$mode{drop_post_once}=0;return {status=>'error',_transport_error=>1,error_code=>'daemon-unreachable',message=>'request never reached daemon'};}
    my $sid="s".(++$series_n);
    my ($type,$points)=$payload->{type} eq 'colors'?('colors',30):('greyscale',21);
    my $init=qq({"status":"running","series_id":"$sid","current_step":0,"total_steps":$points,"current_name":"","readings":[],"low_light_mode":"off","requested_sample_count":1,"type":"$type","points":$points,"selection_run":false,"signal_mode":"sdr","target_gamma":"bt1886","max_luma":100,"dv_map_mode":"none","dv_interface":"none","calibration_target_context":{"white_nits":100}});
    $init=PGAutomation::seed_worker_state_json($init,$body);
    PGAutomation::write_atomic($main::_meter_series_file,$init,0666) or die;
    $pending=$sid;
    if ($mode{lose_reply_once}) {$mode{lose_reply_once}=0;return {status=>'error',_transport_error=>1,error_code=>'daemon-unreachable',message=>'reply lost'};}
    return {status=>'started',series_id=>$sid};
}
my $phase=0;my @seen_status_ids;
sub series_status {
    if ($mode{stale_first_poll}) {$mode{stale_first_poll}=0;return PGAutomation::decode_json(main::webui_meter_series_status(0));}
    if ($pending) {
        my $sid=$pending;
        $phase++;
        if ($phase==2) {
            shell_worker($sid,qq({"status":"running","series_id":"$sid","current_step":1,"total_steps":21,"current_name":"step","readings":[{"Y":1}],"white_reading":null}));
        } elsif ($phase==3) {
            undef $pending;$phase=0;
            my $with_points=$series_n%2;
            shell_worker($sid,$with_points
              ? qq({"status":"complete","series_id":"$sid","type":"greyscale","points":21,"current_step":21,"total_steps":21,"current_name":"Done","readings":[{"Y":1},{"Y":2}],"white_reading":{"Y":100}})
              : qq({"status":"complete","series_id":"$sid","current_step":21,"total_steps":21,"current_name":"Done","readings":[{"Y":1},{"Y":2}],"white_reading":{"Y":100}}));
        }
    }
    my $r=PGAutomation::decode_json(main::webui_meter_series_status(0));
    push @seen_status_ids,[$r->{status},PGAutomation::worker_id($r)];
    return $r;
}
sub grey_start {
    my ($payload)=@_;my $body=PGAutomation::encode_json($payload);
    push @grey_posts,PGAutomation::worker_id($payload);
    my $replayed=PGAutomation::worker_replay_json($body,$grey_file);
    return PGAutomation::decode_json($replayed) if $replayed ne '';
    my $init=PGAutomation::seed_worker_state_json('{"status":"running","autocal":true,"current_step":0,"total_steps":0,"current_name":"Starting LG Auto Cal...","message":"Starting","readings":[]}',$body);
    PGAutomation::write_atomic($grey_file,$init,0666) or die;
    $grey_pending=PGAutomation::decode_json($body);
    return {status=>'started'};
}
sub grey_status {
    if ($grey_pending) {
        # Worker write_state: stamp_worker_state with the config the daemon persisted.
        my $state={status=>'complete',autocal=>JSON::PP::true,final_1d_lut_upload_verified=>JSON::PP::true,message=>'done'};
        PGAutomation::stamp_worker_state($state,$grey_pending);undef $grey_pending;
        PGAutomation::write_json_atomic($grey_file,$state,0666) or die;
    }
    return PGAutomation::read_json_file($grey_file)||{status=>'idle'};
}
local *main::_api=sub {
    my ($m,$p,$payload)=@_;
    return {status=>'ok',connected=>1,disconnected=>0} if $p eq '/api/lg/status';
    return series_start($payload) if $p eq '/api/meter/series' && $m eq 'POST';
    return series_status() if $p eq '/api/meter/series/status';
    return grey_start($payload) if $p eq '/api/meter/lg-autocal' && $m eq 'POST';
    # The wait loop polls the summary view (?view=summary&after=N) and reads
    # the plain path once at the end; this stand-in serves the same state
    # for both, which the runner tolerates.
    return grey_status() if $p =~ m{^/api/meter/lg-autocal/status(?:\?|$)};
    die "unexpected $m $p";
};
# Real artifact copier reads fixed /tmp paths only when state undef; keep it
# on the supplied state by pointing its grey default at our file.
my @ids;
for my $n (0,1) {
    $job=$n;my $item=PGAutomation::clone($item_tpl);$item->{item_number}=$n;
    ok(main::_stage($n,$item,'pre-readings-done',sub {main::_run_series($n,$item,'pre')}),"job $n pre-readings stage succeeds") or diag $main::LAST_ERROR;
    ok(main::_stage($n,$item,'greyscale-done',sub {main::_calibration_greyscale_stage($n,$item)}),"job $n greyscale AutoCal stage succeeds") or diag $main::LAST_ERROR;
    ok(main::_stage($n,$item,'post-readings-done',sub {main::_run_series($n,$item,'post')}),"job $n post-readings after AutoCal succeeds (F3)") or diag $main::LAST_ERROR;
    for my $phase (qw(pre post)) {for my $key (qw(greyscale-21 colors-30)) {
        my $snap=PGAutomation::read_json_file(PGAutomation::item_dir($id,$n)."/$phase/$key.json")||{};
        is($snap->{status},'complete',"job $n $phase $key snapshot saved");
        like($snap->{automation_worker_id}||'',qr/^\Q$id\E-$n-/,"job $n $phase $key snapshot carries its attempt id");
        push @ids,$snap->{automation_worker_id};
    }}
}
my %u;$u{$_}++ for @ids,@grey_posts;
is(scalar(@ids)+scalar(@grey_posts),10,'8 series + 2 AutoCal attempts observed');
is(scalar(keys %u),10,'every series and AutoCal worker got a fresh id');
is(scalar(@posts),8,'each series was POSTed exactly once');
is(scalar(grep {$_->[0] eq 'running'} @seen_status_ids),16,'runner observed seeded and worker-rewritten running states for all 8 series');
is(scalar(grep {$_->[1] eq ''} @seen_status_ids),0,'every status poll (first poll and worker rewrites) carried an attempt id');

# ---- stale status from previous attempt is rejected
{
    $job=1;my $item=PGAutomation::clone($item_tpl);$item->{item_number}=1;$item->{post_series}=['greyscale-21'];
    my $file=PGAutomation::item_dir($id,1).'/post/greyscale-21.json';my $before=PGAutomation::read_raw($file);
    # daemon accepts but has not yet seeded: status still holds previous attempt
    local *main::_api=sub {
        my ($m,$p,$payload)=@_;
        return {status=>'ok',connected=>1} if $p eq '/api/lg/status';
        return {status=>'started'} if $p eq '/api/meter/series' && $m eq 'POST';
        return PGAutomation::decode_json(main::webui_meter_series_status(0)) if $p eq '/api/meter/series/status';
        die "unexpected $p";
    };
    ok(!main::_run_series(1,$item,'post'),'stale previous-attempt status is rejected');
    is($main::LAST_ERROR_CODE,'worker-identity-mismatch','rejection is worker-identity-mismatch');
    is(PGAutomation::read_raw($file),$before,'stale status does not overwrite saved snapshot');
}
# ---- lost start reply: adopted when id matches, no second launch
{
    $job=0;@posts=();my $item=PGAutomation::clone($item_tpl);$item->{post_series}=['colors-30'];
    $mode{lose_reply_once}=1;
    ok(main::_run_series(0,$item,'post'),'lost reply with matching seeded id is adopted') or diag $main::LAST_ERROR;
    is(scalar(@posts),1,'adopted attempt not POSTed twice');
    # request never reached daemon: probe shows previous attempt -> not adopted, re-POST same id
    @posts=();$mode{drop_post_once}=1;
    ok(main::_run_series(0,$item,'post'),'never-delivered start is re-sent and then runs') or diag $main::LAST_ERROR;
    is(scalar(@posts),2,'second POST happened');
    is($posts[0],$posts[1],'re-sent POST keeps the same attempt id');
}
# ---- a running FOREIGN worker must not be adopted after a lost reply
{
    $job=0;my $item=PGAutomation::clone($item_tpl);
    PGAutomation::write_atomic($main::_meter_series_file,PGAutomation::encode_json({status=>'running',automation_worker_id=>'someone-else',type=>'greyscale',points=>21}),0666);
    my $n=0;
    local *main::_api=sub {
        my ($m,$p,$payload)=@_;
        return {status=>'ok',connected=>1} if $p eq '/api/lg/status';
        if ($p eq '/api/meter/series' && $m eq 'POST') {$n++;return {status=>'error',_transport_error=>1,error_code=>'daemon-unreachable',message=>'lost'};}
        return PGAutomation::decode_json(main::webui_meter_series_status(0)) if $p eq '/api/meter/series/status';
        die "unexpected $p";
    };
    my $r=main::_start_worker('/api/meter/series','/api/meter/series/status',{type=>'greyscale',points=>21});
    isnt($r->{status},'started','foreign running worker is never adopted');
    is($n,6,'bounded start attempts (6)');
}
done_testing();
