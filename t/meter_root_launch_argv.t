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
use Test::More;
my $WT;BEGIN{require FindBin;$WT="$FindBin::Bin/.."}
use lib "$WT/usr/share/PGenerator";
use PGAutomation ();
use threads; use threads::shared;
{ local $SIG{__WARN__}=sub{}; for my $m (qw(variables.pm command.pm)) { do "$WT/usr/share/PGenerator/$m"; die "$m: $@" if $@; } }
require "$WT/usr/share/PGenerator/webui.pm";
my $tmp=tempdir(CLEANUP=>1);
$ENV{PGEN_AUTOMATION_DIR}="$tmp/automation";PGAutomation::ensure_store();
$main::_meter_series_file="$tmp/meter_series.json";
our @LAUNCH;
local *main::webui_meter_series_alive=sub {0};
local *main::webui_meter_session_alive=sub {0};
local *main::webui_meter_session_stop_only=sub {1};
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
# sudoers shape: argv[0..2] must be the literal authorized prefix, no env
is_deeply([@{$argv}[0..2]],['sudo','/bin/bash','/usr/bin/meter_series.sh'],
 'argv[0..2] match the NOPASSWD rule "/bin/bash /usr/bin/meter_series.sh *" with no env prefix');
ok(scalar(@$argv)==42,'all 39 worker positional args plus the sudo/bash/script prefix still travel as one argv');
my ($bad)=(grep {defined && /\n/} @$argv);
ok(!defined $bad,'no launched argument contains a newline');
($bad)=(grep {/\0/} @$argv);
ok(!defined $bad,'no launched argument contains a NUL');
# The producers sanitise upstream: shell metacharacters from the hostile
# body must not reach argv at all.
($bad)=(grep {defined && /['$();`|&]/} @$argv);
ok(!defined $bad,'no shell metacharacter survives the producer chain into argv') or diag explain $argv;

# A value that IS safe to pass verbatim (printables incl. quotes) must NOT
# be mangled by the launcher: it is the argv boundary that protects it.
# Direct check on the real launcher with a recording exec, below, needs a
# subprocess; the validator assertion above pins the same rule.

done_testing();
