#!/usr/bin/perl
# Issue #53 review follow-up: handler-level pins for the meter-session and
# CCSS-create launches through webui_launch_detached_root.
#
# The series route, the validator, and the launcher's own exec contract are
# pinned in t/meter_root_launch_argv.t; these two sites are the other half
# of the fix. Per site we pin:
#  1. the captured argv shape (sudo, "--" option boundary, authorized
#     program, hostile printables preserved byte-identically);
#  2. the refusal branch: when the launcher returns 0 the handler answers
#     an explicit error, records exactly one launch attempt (a refused
#     launch is never retried), leaves NO phantom "starting" state behind,
#     and runs no stop/pkill teardown (the worker never existed).
#
# Hostile values use neutral marker tokens, never real shell verbs. The
# launcher is ALWAYS stubbed here: the real one execs sudo, which in the
# test environment would block on a password prompt (its exec contract is
# pinned without sudo in t/meter_root_launch_argv.t's subprocess section).
# The CCSS-create handler's two pre-launch shell probes are stubbed via
# webui.pm's named wrappers (webui_python_runner_bin /
# webui_meter_detect_probe_json) — backticks cannot be hooked from a test
# (CORE::GLOBAL::qx never intercepted them; the override feature is gone
# from Perl), which is why those probes exist as named subs at all. The
# $_ccss_create_* path constants are package globals for the same reason
# (same precedent as $_meter_read_file).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use Test::More;
my $WT;BEGIN{require FindBin;$WT="$FindBin::Bin/.."}
use lib "$WT/usr/share/PGenerator";
use PGAutomation ();
use threads; use threads::shared;
{ local $SIG{__WARN__}=sub{}; for my $m (qw(variables.pm command.pm)) { do "$WT/usr/share/PGenerator/$m"; die "$m: $@" if $@; } }
# The CCSS-create handler shell-probes python and the meter wrapper before
# launching, and tears stray workers down with system(). Backticks cannot be
# hooked from a test (CORE::GLOBAL::qx does not intercept them; the override
# feature was removed from Perl), so webui.pm wraps the two probes in named
# subs (webui_python_runner_bin / webui_meter_detect_probe_json) and we stub
# those. system() is still glob-hooked so teardown pkill never really runs.
BEGIN {
 our (@SYS);
 *CORE::GLOBAL::system = sub { push @main::SYS, join(' ',@_); return 0; };
}
my $tmp=tempdir(CLEANUP=>1);
$ENV{PGEN_AUTOMATION_DIR}="$tmp/automation";PGAutomation::ensure_store();
# $var_dir resolves the module's lexical directory constants while the
# do/require below runs, so it must be set BEFORE loading webui.pm
# (t/idle_card_runtime.t precedent).
$main::var_dir="$tmp/var";
mkdir $main::var_dir;
require "$WT/usr/share/PGenerator/webui.pm";
# &log is resolved at runtime in main (log.pm is only ever loaded into the
# daemon's namespace chain; tests never load it). A silent stub keeps the
# handlers' logging inert.
sub log (@) { }

# ---- shared stubs (assigned AFTER the require so webui.pm's own
# definitions do not overwrite them) ----
local *main::lg_automation_guard_json=sub {''};
local *main::webui_meter_session_alive=sub {0};
local *main::webui_meter_stop=sub {1};
local *main::webui_meter_session_stop=sub {1};
local *main::webui_pattern_stop_guard_clear=sub {};
local $main::_meter_wrapper="$tmp/spotread_wrapper.sh";
local $main::_meter_read_file="$tmp/meter_read.json";
# Probe stubs: python resolves; the detect probe returns one spectro on
# port 1 (matches webui.pm's strict meter-row regex).
local *main::webui_python_runner_bin=sub {"/usr/bin/python3\n"};
local *main::webui_meter_detect_probe_json=sub {'{"port_num":"1","port":"/dev/ttyUSB0","usb_id":"0765:6003","name":"i1 Pro 3","meter_type":"spectro"}'};

# ================= meter session start =================
our @LAUNCH;
local *main::webui_launch_detached_root=sub { push @LAUNCH,[@_]; return 0; };
my $ret=main::webui_meter_session_start("lcd'; \"id\" #","/path/prof.ccss","60",0,"cfgjson","sdr","250","1",0,0,"","1931_2","local","");
is(scalar(@LAUNCH),1,'session: exactly one launch attempt; a refused launch is not retried');
my $argv=$LAUNCH[0];
is_deeply([@{$argv}[0..3]],['sudo','--','/bin/bash','/usr/bin/meter_session.sh'],
 'session: sudo + "--" option boundary + authorized meter_session.sh prefix');
ok((grep {!ref && $_ eq "lcd'; \"id\" #"} @$argv),'session: printable-hostile display_type reaches argv verbatim (the argv boundary protects it; no escaping layer)');
is(scalar(@$argv),17,'session: full 14 worker positional args plus the sudo/--/bash/script prefix');
ok(!$ret,'session: refusal returns false (boolean contract: both callers in webui_meter_read test if(!&webui_meter_session_start(...)); a truthy JSON string would look like a successful start)');
# The refusal reaches the UI through the read-state file: on false the
# caller builds its reply with webui_meter_session_start_error_json, which
# echoes the explicit error state written by the refusal branch.
my $caller_json=main::webui_meter_session_start_error_json("cfgjson");
my $r=eval { PGAutomation::decode_json($caller_json) };
is($r->{status},'error','session: caller-side error helper answers an explicit error');
like($r->{message},qr/refused/i,'session: error message names the refusal');
# The phantom-start bug: the handler writes {"status":"starting"} before
# launching; a refusal must replace it or the UI polls a start that never
# happened.
my $state="";
if(open(my $fh,"<",$main::_meter_read_file)) { local $/ = undef; $state=<$fh>; close($fh); }
like($state,qr/"status"\s*:\s*"error"/,'session: read-state replaced with error after refusal');
unlike($state,qr/"status"\s*:\s*"starting"/,'session: no phantom starting state left behind');

# ================= CCSS-create start =================
# Preconditions the handler checks before it assembles argv: helper
# executables present, no job alive, custom storage available. The
# $_ccss_create_* paths are package globals (see webui.pm) precisely so
# they localize to temp fixtures here.
for my $tool (qw(ccxxmake ccss_create.py ccss_create_patch.sh)) {
 open(my $tfh,">","$tmp/$tool"); print $tfh "#!/bin/sh\nexit 0\n"; close($tfh);
 chmod 0755,"$tmp/$tool";
}
local $main::_ccss_create_ccxxmake_bin="$tmp/ccxxmake";
local $main::_ccss_create_runner="$tmp/ccss_create.py";
local $main::_ccss_create_patch_cmd="$tmp/ccss_create_patch.sh";
local $main::_ccss_create_state_file="$tmp/ccss_state.json";
local $main::_ccss_create_pid_file="$tmp/ccss.pid";
local $main::_ccss_create_log_file="$tmp/ccss.log";
local $main::_ccss_create_continue_file="$tmp/ccss.cont";
local $main::_custom_ccss_dir="$tmp/custom";
local $main::_custom_ccss_legacy_dir="$tmp/custom-legacy";
local *main::_webui_ensure_custom_storage_dir=sub {1};
local *main::_webui_ccss_create_alive=sub {0};

my $name_ok="it's \"MKMARK\" \$() profile";
my $body_ok=PGAutomation::encode_json({name=>$name_ok, display_type=>'lcd', profiling_meter_port=>"1"});
our @CL;
local *main::webui_launch_detached_root=sub { push @CL,[@_]; return 0; };
my $cr=eval { PGAutomation::decode_json(main::webui_ccss_create_start($body_ok)) };
is(ref($cr),'HASH','ccss-create: answer is parseable JSON');
is($cr->{status},'error','ccss-create: refusal answers an explicit error');
like($cr->{message},qr/refused/i,'ccss-create: error message names the refusal') or diag(explain($cr));
is(scalar(@CL),1,'ccss-create: exactly one launch attempt recorded');
my $cargv=$CL[0];
is($cargv->[0],'sudo','ccss-create: launched via sudo');
is($cargv->[1],'--','ccss-create: "--" option boundary immediately after sudo');
is($cargv->[2],'/usr/bin/python3','ccss-create: python runner is the sudoers-authorized interpreter');
is($cargv->[3],$main::_ccss_create_runner,'ccss-create: authorized ccss_create.py runner follows');
my ($di)=grep { defined $cargv->[$_] && $cargv->[$_] eq "--display-name" } 0..$#{$cargv};
ok(defined $di,'ccss-create: --display-name present');
is($cargv->[$di+1],$name_ok,'ccss-create: hostile display name reaches argv byte-identically (the old hand-rolled escape is gone)');
ok(!(grep {defined && !ref && /\n|\x00/} @$cargv),'ccss-create: no control characters in argv');
is($cargv->[-2],'--continue-file','ccss-create: continue file remains the final flag pair');
# The localized custom storage roots must be honored: _custom_ccss_dir /
# _custom_ccss_legacy_dir are package globals (webui.pm) precisely so this
# localization is real, not dead. Reverting them to file-scoped my silently
# sends --output-path back to the $var_dir-derived lexical and this fails.
my ($oi)=grep { defined $cargv->[$_] && $cargv->[$_] eq "--output-path" } 0..$#{$cargv};
ok(defined $oi && $cargv->[$oi+1]=~m{^\Q$tmp\E/custom/},
 'ccss-create: --output-path lands under the test-localized custom dir (package globals honored)');
# State after refusal: the handler must leave the error state, not the
# "starting" state it wrote just before launching.
my $cstate="";
if(open(my $cfh,"<",$main::_ccss_create_state_file)) { local $/ = undef; $cstate=<$cfh>; close($cfh); }
like($cstate,qr/"status"\s*:\s*"error"/,'ccss-create: state file carries the error after refusal');

# A name carrying a newline must not reach the launcher as a spawned argv
# element: the refusal point may be the handler's own validator or the
# launcher's control-char gate (both are pinned), but the answer must be an
# error and no phantom job may survive.
my $nl_name=$name_ok; $nl_name=~s/MKMARK/MK\nMARK/;
my $body_nl=PGAutomation::encode_json({name=>$nl_name, display_type=>'lcd', profiling_meter_port=>"1"});
our @RL;
local *main::webui_launch_detached_root=sub { push @RL,[@_]; return 0; };
my $rn=eval { PGAutomation::decode_json(main::webui_ccss_create_start($body_nl)) };
is($rn->{status},'error','ccss-create: newline name answered with an error (launch refused)');
if(scalar(@RL)) {
 my ($di2)=grep { defined $RL[0][$_] && $RL[0][$_] eq "--display-name" } 0..$#{$RL[0]};
 ok(defined $di2 && $RL[0][$di2+1]=~/\n/,'ccss-create: newline reached the launcher boundary untouched (refused there, not re-encoded here)');
} else {
 ok(1,'ccss-create: handler refused the newline before the launcher (validator path)');
}
done_testing();
