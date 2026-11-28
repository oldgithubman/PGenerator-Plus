# Issue #53: the meter session / series / CCSS-create workers are launched
# shell-free (webui_launch_detached_root) so request-derived values travel
# as exec() argv instead of shell text. Two layers are pinned here:
#  1. webui_root_argv_arg_ok refuses control characters (the one class of
#     byte that still matters: sudo globs argv for the NOPASSWD rule).
#  2. the REAL handlers put hostile values in argv verbatim or neutralise
#     them upstream — the producers already strip quotes and $(), so these
#     assertions are GREEN on day one by design. They are regression
#     guards for a future unvalidated addition to the argv list, not
#     red-green proof of a live vulnerability (see issue #53).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use Time::HiRes ();
use Test::More;
my $WT;BEGIN{require FindBin;$WT="$FindBin::Bin/.."}
use lib "$WT/usr/share/PGenerator";
use PGAutomation ();
use threads; use threads::shared;
{ local $SIG{__WARN__}=sub{}; for my $m (qw(variables.pm command.pm)) { do "$WT/usr/share/PGenerator/$m"; die "$m: $@" if $@; } }
require "$WT/usr/share/PGenerator/webui.pm";
# Capture the REAL launcher before the file-scoped `local *stub` below
# replaces it: the subprocess pins near the end of this file run INSIDE
# that scope, so a plain call would hit the stub and silently pin nothing.
my $REAL_LAUNCHER = \&main::webui_launch_detached_root;
# &log is resolved at runtime in main (log.pm is only ever loaded into the
# daemon's namespace chain; tests never load it). A silent stub keeps the
# refusal-path logging inert.
sub log (@) { }
my $tmp=tempdir(CLEANUP=>1);
$ENV{PGEN_AUTOMATION_DIR}="$tmp/automation";PGAutomation::ensure_store();
$main::_meter_series_file="$tmp/meter_series.json";
our @LAUNCH;
local *main::webui_meter_series_alive=sub {0};
local *main::webui_meter_session_alive=sub {0};
local *main::webui_meter_session_stop_only=sub {1};
# webui_meter_stop() runs on this route before launching; its real body
# issues sudo pkill teardowns. Stub it (t/meter_ccss_root_launch_handlers.t
# precedent) so the test never invokes sudo: nothing is alive to stop here
# anyway, and the stubbed *_alive probes above keep that true.
local *main::webui_meter_stop=sub {1};
local *main::webui_meter_pattern_stop_guard_set=sub {};
local *main::lg_automation_guard_json=sub {''};
local *main::webui_launch_detached_root=sub { push @LAUNCH,[@_]; return 1; };
local *main::webui_meter_series_ready_cleanup=sub {};
local *main::webui_meter_series_stop_cleanup=sub {};

# ---- validator ----
ok(main::webui_root_argv_arg_ok("plain-value"),'plain value passes');
ok(main::webui_root_argv_arg_ok(""),'empty value passes (blank positional args are legitimate)');
ok(main::webui_root_argv_arg_ok("'root' \$(reboot) `id` ;|&*()<>\\\\"),
   'shell metacharacters PASS validation: they are inert in exec() argv — that is the whole point of the fix');
ok(!main::webui_root_argv_arg_ok("new\nline"),'newline refused (breaks the sudoers glob join)');
ok(!main::webui_root_argv_arg_ok("nul\x00byte"),'NUL refused');
ok(!main::webui_root_argv_arg_ok("tab\there"),'tab refused (also a sudoers glob whitespace)');
ok(!main::webui_root_argv_arg_ok("esc\x1b[0m"),'escape refused');
ok(main::webui_root_argv_arg_ok(undef),'undef coerces to empty and passes');

# ---- real series handler: hostile payload through the full parse path ----
# signal_mode is deliberately NOT hostile here: webui_pattern_signal_mode
# strips it to [a-z0-9] but an unknown residue (e.g. "sdrmkmark") makes
# webui_signal_code_policy die pre-existing to this change. The remaining
# fields exercise the quote/$ paths that used to reach the shell string.
my $hostile=PGAutomation::encode_json({
 type=>'greyscale',points=>21,
 display_type=>"lcd'; reboot #",
 ccss_override=>"evil'; \$(id) '.ccss",
 max_luma=>"1000'; poweroff",
 observer=>"1931_2', evil",
 pattern_provider=>"companion'; reboot",
 measurement_meter_usb_id=>"1234:abcd', x",
 delay_ms=>"10'; id; '",
});
my $r=eval {PGAutomation::decode_json(main::webui_meter_series_start($hostile))};
diag($@) if $@;
is($r->{status},'started','hostile payload still answers through the normal route') or diag explain $r;
is(scalar(@LAUNCH),1,'exactly one launch captured');
my $argv=$LAUNCH[0];
# sudoers shape: sudo's option boundary, then the literal authorized prefix,
# no env
is_deeply([@{$argv}[0..3]],['sudo','--','/bin/bash','/usr/bin/meter_series.sh'],
 'argv[0]="sudo", argv[1]="--" option boundary, argv[2..3] match the NOPASSWD rule "/bin/bash /usr/bin/meter_series.sh *" with no env prefix');
ok(scalar(@$argv)==43,'sudo + "--" + the 39 worker positional args plus the bash/script prefix still travel as one argv');
my ($bad)=(grep {defined && /\n/} @$argv);
ok(!defined $bad,'no launched argument contains a newline');
($bad)=(grep {/\0/} @$argv);
ok(!defined $bad,'no launched argument contains a NUL');
# The producers sanitise upstream: shell metacharacters from the hostile
# body must not reach argv at all.
($bad)=(grep {defined && /['$();`|&]/} @$argv);
ok(!defined $bad,'no shell metacharacter survives the producer chain into argv') or diag explain $argv;

# ---- real launcher subprocess pins (no stubbing; exec LIST is exercised) ----
# The handler pins above prove WHAT the producers hand the launcher. These
# prove the launcher's own contract: hostile printables arrive byte-identical
# (exec() never interprets them) and a control character is refused BEFORE
# anything spawns. Recording script prints its argv so we see exactly what
# exec() received. argv[0] is the recorder directly, not "sudo": the real
# launcher would exec sudo here, and sudo has no NOPASSWD rule for the test
# payload (it would block on a password prompt). sudo adds nothing to the
# exec contract under test — argv is argv.
{
 my $rec="$tmp/record_argv.sh";
 # The launcher redirects worker stdout to /dev/null, so the recorder must
 # write its file itself: $1 is the destination, the rest is recorded argv.
 open(my $rf,">",$rec); print $rf "#!/bin/bash\ndst=\"\$1\"\nshift\nprintf '%s\\n' \"\$@\" > \"\$dst\"\n"; close($rf);
 chmod 0755,$rec;
 my $out="$tmp/recorded.out";
 my $rc=$REAL_LAUNCHER->($rec,$out,"it's \"MKMARK\" \$() x","semi;colon","pipe|and >","-dash-initial");
 is($rc,1,'real launcher: printable-hostile argv accepted');
 my $seen="";
 for(1..50) { if(-s $out) { open(my $fh,"<",$out); local $/ = undef; $seen=<$fh>; close($fh); last; } Time::HiRes::sleep(0.1); }
 my @seen=split(/\n/,$seen,-1);
 is($seen[0],"it's \"MKMARK\" \$() x",'quotes/dollar/parens arrive byte-identical (no shell interpretation)');
 is($seen[1],'semi;colon','semicolons arrive as literal argv');
 is($seen[2],'pipe|and >','pipes and redirects arrive as literal argv, not shell syntax');
 is($seen[3],'-dash-initial','a dash-initial value reaches the WORKER as data (the sudo "--" boundary pinned by the handler tests keeps sudo from ever parsing it as an option)');
 # Refusal BEFORE spawn: control char in argv -> return 0, nothing executed.
 # (argv[0] is back to "sudo" here, but it never matters: the validator
 # refuses before the fork, so nothing is ever exec'd.)
 my $out2="$tmp/recorded2.out";
 my $rc2=$REAL_LAUNCHER->("sudo","--","/bin/bash",$rec,"new\nline","$out2");
 is($rc2,0,'real launcher: newline in argv refused');
 Time::HiRes::sleep(0.4);
 ok(!-e $out2,'refusal spawned nothing (validator runs before the fork)');
}

done_testing();
