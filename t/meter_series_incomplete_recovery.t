use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

# Issue #59 pins for the series read-recovery block in
# usr/bin/meter_series.sh: an incomplete read retires the spotread child,
# re-reads the patch once at double timeout, and stops the series only if
# that fails or the per-series recovery cap is hit. The block is extracted
# from the shipped script verbatim and driven with a fake clock (the sleep
# stub advances SECONDS) so every branch is exercised without hardware.

open my $fh,'<',"$Bin/../usr/bin/meter_series.sh" or die $!;
my $source=do {local $/;<$fh>};

my ($cap)=$source=~/^INCOMPLETE_RECOVERY_MAX=(\d+)/m;
ok(defined $cap,'recovery cap constant is defined once at top level');

# Extract the block: starts at the no-reading branch after the primary read
# loop (the unique 'read timeout:' log anchor), ends at the 'done/fi' that
# closes the no-reading retry loop.
my $anchor=index($source,"] read timeout: step=");
ok($anchor>0,'read timeout log line exists');
my $start=rindex($source,"\n if [[ -z \"\$READING\" ]]; then\n",$anchor);
ok($start>0,'no-reading branch start found before the timeout log');
my $endidx=index($source,'no reading retry failed',$start);
ok($endidx>$start,'no-reading retry failure log found');
my $end=index($source,"\n  done\n fi\n",$endidx);
ok($end>$endidx,'no-reading retry loop terminator found');
my $block=substr($source,$start+1,$end-($start+1)+length("\n  done\n fi"));
ok(length($block)>500,'extracted the incomplete-read recovery block');
like($block,qr/incomplete read recovery/,'block contains the recovery log line');
for my $needle ('RETRY_TIMEOUT_SCALE=1','restart_spotread_session','INCOMPLETE_RECOVERIES','RETRY_TIMEOUT=$((RETRY_TIMEOUT * RETRY_TIMEOUT_SCALE))') {
 like($block,qr/\Q$needle\E/,"block contains $needle");
}
unlike($block,qr/kill -9|pkill/,'recovery retires the child through restart_spotread_session only');
# The doubling must be consumed for exactly one read: the scale resets to 1
# right after the multiply, so a second ordinary retry cannot inherit 2x.
my ($mult_line)= $block=~/RETRY_TIMEOUT=\$\(\(RETRY_TIMEOUT \* RETRY_TIMEOUT_SCALE\)\)(.*)/s;
like(substr($mult_line,0,80),qr/RETRY_TIMEOUT_SCALE=1/,'timeout scale resets after the multiply');

# Ordering pin: the child is retired before the scale-2 recovery read is
# armed, and READ_INCOMPLETE is cleared only after a successful restart.
my $pos_restart=index($block,'restart_spotread_session');
my $pos_scale2=index($block,'RETRY_TIMEOUT_SCALE=2');
ok($pos_restart>=0 && $pos_scale2>$pos_restart,'restart precedes the doubled-budget marking');
my $pos_clear=index($block,'READ_INCOMPLETE=0');
ok($pos_clear>$pos_restart,'READ_INCOMPLETE cleared only after the restart call');
my $pos_cap=index($block,'INCOMPLETE_RECOVERIES > INCOMPLETE_RECOVERY_MAX');
ok($pos_cap>0 && $pos_cap<$pos_restart,'recovery cap is checked before restarting');

sub run_scenario {
 my %s=@_;
 my $dir=tempdir(CLEANUP=>1);
 my $b=$block;
 $b=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
 local $ENV{D}=$dir;
 $ENV{SC_RESTART}=$s{SC_RESTART};$ENV{SC_READ}=$s{SC_READ};
 $ENV{INIT_INCOMPLETE}=$s{INIT_INCOMPLETE};$ENV{INIT_COMM}=$s{INIT_COMM};
 $ENV{INIT_RECOVERIES}=$s{INIT_RECOVERIES};$ENV{SR_CMD_BASE_VAL}=$s{SR_CMD_BASE};
 $ENV{REQUIRE_RDY}=$s{REQUIRE_RDY};$ENV{NO_READ}=$s{NO_READ};
 $ENV{PARSE_OK}=defined $s{PARSE_OK} ? $s{PARSE_OK} : 1;
 my $script=<<'BASH';
OUTFILE="$D/output"; touch "$OUTFILE"
exec 3>"$D/keys"
STEP_NUM=7; IRE=100; NAME='Red 100%'; SERIES_ID=t; TOTAL=21; READINGS=''; WHITE_READING='null'
R=255; G=0; B=0; INPUT_MAX=255; i=6; IRE=100
READ_TIMEOUT=10; READ_START=$SECONDS; SECONDS=0; READ_POLL_SEC=1
PATTERN_DELAY_SEC=0; STEP_DELAY=0; STEP_PATCH_SIZE=10; SIGNAL_MODE=tv; MAX_LUMA=100
PATTERN_SIGNAL_RANGE=''; TRANSPORT_SIGNAL_RANGE=''
COMM_RETRY_SEEN=$INIT_COMM
READ_INCOMPLETE=$INIT_INCOMPLETE
INCOMPLETE_RECOVERIES=$INIT_RECOVERIES
INCOMPLETE_RECOVERY_MAX=5
SR_CMD_BASE="$SR_CMD_BASE_VAL"; REQUIRE_DEVICE_READY=$REQUIRE_RDY
NO_READING_RETRIES=$NO_READ
sleep() { SECONDS=$((SECONDS + ${1:-1})); }
series_stop_requested() { return 1; }
series_meter_read_failure_exit() { echo "FATAL: $1 [t=${RETRY_TIMEOUT:-}]"; exit 0; }
restart_spotread_session() { echo RESTART-CALLED >> "$D/events"; if [[ "$SC_RESTART" == fail ]]; then SPOTREAD_RESTART_ERROR='no device found'; return 1; fi; return 0; }
post_patch() { echo REDISPLAY >> "$D/events"; }
count_results() {
 echo count >> "$D/events"
 if [[ "$SC_READ" == ok ]] && grep -qx 'REDISPLAY' "$D/events"; then
  local n=0; [[ -f "$D/cc" ]] && n=$(cat "$D/cc")
  n=$((n+1)); echo $n > "$D/cc"
  if (( n > 1 )); then echo 1; return; fi
 fi
 echo 0
}
output_size() { wc -c < "$OUTFILE" | tr -d ' '; }
clean_output_since() { :; }
manual_ready_prompt_reason() { return 1; }
handle_series_manual_prompt() { return 1; }
read_timeout_seconds() { echo 10; }
step_timeout_stimulus() { echo x; }
parse_latest_result() { if [[ "$PARSE_OK" == 1 ]]; then echo '{"Y":1}'; fi; }
build_step_reading_json() { echo '{"reading":1}'; }
write_state_json() { cat > /dev/null; }
BASH
 $script.="\n$b\n";
 $script.=<<'BASH';
echo "DONE recoveries=$INCOMPLETE_RECOVERIES scale=$RETRY_TIMEOUT_SCALE"
BASH
 my $err=gensym; my $pid=open3(my $in,my $out,$err,'bash');
 print {$in} $script; close $in;
 my $output=do{local $/;<$out>}; my $errors=do{local $/;<$err>}; waitpid($pid,0);
 my $rc=$? >> 8;
 my $dbg=''; if(open my $f,'<',"$dir/debug.log"){$dbg=do{local $/;<$f>}}
 my $events=''; if(open my $f,'<',"$dir/events"){$events=do{local $/;<$f>}}
 return ($output,$errors,$dbg,$rc,$events);
}

my ($out,$errs,$dbg,$rc,$events)=run_scenario(
 SC_RESTART=>'ok',SC_READ=>'ok',INIT_INCOMPLETE=>1,INIT_COMM=>0,
 INIT_RECOVERIES=>0,SR_CMD_BASE=>'spotread -x',REQUIRE_RDY=>0,NO_READ=>1);
is($rc, 0, 'stall-recovery scenario harness ran') or diag($errs);
unlike($out,qr/FATAL/,'stalled read recovers without stopping the series');
like($out,qr/DONE recoveries=1/,'one recovery recorded');
is(scalar(() = $events=~/^REDISPLAY$/mg),1,'exactly one re-read after the restart');
like($dbg,qr/incomplete=1/,'timeout log line reports the incomplete flag');
like($dbg,qr/incomplete read recovery:.*recovery=1\/5/,'recovery log names the child replacement with running count');

($out,$errs,$dbg,$rc)=run_scenario(
 SC_RESTART=>'fail',SC_READ=>'fail',INIT_INCOMPLETE=>1,INIT_COMM=>0,
 INIT_RECOVERIES=>0,SR_CMD_BASE=>'spotread -x',REQUIRE_RDY=>0,NO_READ=>1);
like($out,qr/FATAL:.*could not be restarted \(no device found\)/,'failed restart on a spotread meter stops with the restart-failure message and the restart error');
unlike($out,qr/DONE/,'no continuation past the fatal exit');

($out,$errs,$dbg,$rc)=run_scenario(
 SC_RESTART=>'fail',SC_READ=>'fail',INIT_INCOMPLETE=>1,INIT_COMM=>0,
 INIT_RECOVERIES=>0,SR_CMD_BASE=>'',REQUIRE_RDY=>0,NO_READ=>1);
like($out,qr/FATAL: Meter read did not complete for Red 100%; series stopped/,'meter with no restartable child stops with the original no-restart wording');
unlike($out,qr/could not be restarted/,'no-restart path does not claim a failed restart attempt');

($out,$errs,$dbg,$rc)=run_scenario(
 SC_RESTART=>'fail',SC_READ=>'fail',INIT_INCOMPLETE=>1,INIT_COMM=>0,
 INIT_RECOVERIES=>0,SR_CMD_BASE=>'spotread -x',REQUIRE_RDY=>1,NO_READ=>1);
unlike($out,qr/could not be restarted/,'device-ready meters also keep the original wording');

($out,$errs,$dbg,$rc)=run_scenario(
 SC_RESTART=>'ok',SC_READ=>'ok',INIT_INCOMPLETE=>1,INIT_COMM=>0,
 INIT_RECOVERIES=>5,SR_CMD_BASE=>'spotread -x',REQUIRE_RDY=>0,NO_READ=>1);
like($out,qr/FATAL:.*after 5 recoveries/,'recovery cap stops a flaky-meter series');
unlike($out,qr/DONE/,'cap scenario stops before continuing');

($out,$errs,$dbg,$rc)=run_scenario(
 SC_RESTART=>'ok',SC_READ=>'fail',INIT_INCOMPLETE=>1,INIT_COMM=>0,
 INIT_RECOVERIES=>0,SR_CMD_BASE=>'spotread -x',REQUIRE_RDY=>0,NO_READ=>1);
like($out,qr/FATAL: Meter retry did not complete/,'re-read failing again still stops the series (bounded)');
like($out,qr/FATAL: Meter retry did not complete.*\[t=20\]/,'recovery read gets the doubled budget');

($out,$errs,$dbg,$rc)=run_scenario(
 SC_RESTART=>'ok',SC_READ=>'fail',INIT_INCOMPLETE=>0,INIT_COMM=>1,
 INIT_RECOVERIES=>0,SR_CMD_BASE=>'spotread -x',REQUIRE_RDY=>0,NO_READ=>1);
like($out,qr/FATAL: Meter retry did not complete/,'completed-but-unusable read still takes the ordinary retry path');
unlike($dbg,qr/incomplete read recovery/,'ordinary no-reading path performs no child restart');
like($out,qr/FATAL: Meter retry did not complete.*\[t=10\]/,'ordinary retry keeps the base timeout (scale 1)');

($out,$errs,$dbg,$rc)=run_scenario(
 SC_RESTART=>'ok',SC_READ=>'ok',PARSE_OK=>0,INIT_INCOMPLETE=>1,INIT_COMM=>0,
 INIT_RECOVERIES=>0,SR_CMD_BASE=>'spotread -x',REQUIRE_RDY=>0,NO_READ=>1);
like($out,qr/FATAL: Meter retry returned an unparseable result/,'re-read that completes but does not parse stops the series');

# Restart progress label: stall recovery republishes the wait under its own
# name so the operator is not told the low-light integration is switching.
my ($restart)=$source=~/^(restart_spotread_session\(\) \{.*?^\})/ms;
ok($restart,'extract restart function for label test');
for my $mode ('reason','plain') {
 my $dir=tempdir(CLEANUP=>1);
 my $fn=$restart;
 $fn=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
 local $ENV{D2}=$dir;
 local $ENV{LABEL_MODE}=$mode;
 my $script=<<'BASH';
OUTFILE="$D2/output"; CMDPIPE="$D2/pipe"
SR_CMD_BASE='fake-reader'; CURRENT_LOW_LIGHT_MODE=off; REQUIRE_DEVICE_READY=0
METER_SERIES_FD_OPEN=0; SERIES_ID=t; STEP_NUM=7; NAME='Red 100%'; TOTAL=21
if [[ "$LABEL_MODE" == reason ]]; then SPOTREAD_RESTART_REASON='Recovering stalled meter read for Red 100%'; fi
series_stop_requested() { return 1; }
series_cancel_exit() { exit 90; }
refresh_cal_prompt() { return 1; }
sleep() { command sleep 0.01; }
json_escape() { printf '%s' "$1"; }
write_state_json() { command cat >> "$D2/states"; }
series_quit_spotread() {
 if [[ "$METER_SERIES_FD_OPEN" == 1 ]]; then exec 3>&-; METER_SERIES_FD_OPEN=0; fi
 rm -f "$OUTFILE" "$CMDPIPE"
}
script() { printf 'Press a key to take a reading:\n'; command cat >/dev/null; }
BASH
 $script.=$fn."\n";
 $script.=<<'BASH';
restart_spotread_session
cat "$D2/states"
BASH
 my $err=gensym; my $pid=open3(my $in,my $out2,$err,'bash');
 print {$in} $script; close $in;
 my $o=do{local $/;<$out2>}; my $e=do{local $/;<$err>}; waitpid($pid,0);
 is($? >> 8,0,"$mode label harness exits cleanly") or diag($e);
 if($mode eq 'reason') {
  like($o,qr/Recovering stalled meter read for Red 100% \(attempt 1\/2\)/,'stall recovery publishes the recovery-labelled progress');
  unlike($o,qr/Preparing meter integration/,'stall recovery does not claim an integration switch');
 } else {
  like($o,qr/Preparing meter integration for Red 100% \(attempt 1\/2\)/,'integration-mode switch keeps its original progress label');
 }
}

done_testing();
