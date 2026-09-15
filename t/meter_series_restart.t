use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

open my $fh,'<',"$Bin/../usr/bin/meter_series.sh" or die $!;
my $source=do {local $/;<$fh>};
my ($restart)=$source=~/^(restart_spotread_session\(\) \{.*?^\})/ms;
ok($restart,'extract actual restart function without running the hardware worker');
unlike($restart,qr/kill -9|pkill -9/,'integration switch uses graceful retirement rather than unconditional SIGKILL');
for my $scenario ('ready','recover','fail') {
 my $dir=tempdir(CLEANUP=>1);
 my $function=$restart;
 $function=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
 local $ENV{RESTART_TEST_DIR}=$dir;
 local $ENV{RESTART_TEST_SCENARIO}=$scenario;
 my $script=<<'BASH';
set -o pipefail
OUTFILE="$RESTART_TEST_DIR/output"
CMDPIPE="$RESTART_TEST_DIR/pipe"
SR_CMD_BASE='fake-reader -x -Y R:24'
CURRENT_LOW_LIGHT_MODE=off
REQUIRE_DEVICE_READY=0
METER_SERIES_FD_OPEN=0
SERIES_ID=test
STEP_NUM=2
NAME='0%'
TOTAL=21
series_stop_requested() { return 1; }
series_cancel_exit() { exit 90; }
refresh_cal_prompt() { return 1; }
sleep() { command sleep 0.01; }
json_escape() { printf '%s' "$1"; }
write_state_json() { command cat >> "$RESTART_TEST_DIR/states"; }
series_quit_spotread() {
 printf 'quit\n' >> "$RESTART_TEST_DIR/events"
 if [[ "$METER_SERIES_FD_OPEN" == 1 ]]; then exec 3>&-; METER_SERIES_FD_OPEN=0; fi
 if [[ -n "$BG_PID" ]]; then wait "$BG_PID" 2>/dev/null || true; fi
 rm -f "$OUTFILE" "$CMDPIPE"
}
script() {
 local n=0
 [[ -f "$RESTART_TEST_DIR/attempts" ]] && read -r n < "$RESTART_TEST_DIR/attempts"
 n=$((n+1)); printf '%s\n' "$n" > "$RESTART_TEST_DIR/attempts"
 printf 'spawn %s %s\n' "$n" "$*" >> "$RESTART_TEST_DIR/events"
 if [[ "$RESTART_TEST_SCENARIO" == fail || ( "$RESTART_TEST_SCENARIO" == recover && "$n" == 1 ) ]]; then
  printf 'Instrument initialisation failed: Communications failure\n'
 else
  printf 'Press a key to take a reading:\n'
 fi
 command cat >/dev/null
}
BASH
 $script.=$function."\n".<<'BASH';
restart_spotread_session a
result=$?
printf 'result=%s mode=%s detail=%s\n' "$result" "$CURRENT_LOW_LIGHT_MODE" "$SPOTREAD_RESTART_ERROR"
series_quit_spotread
cat "$RESTART_TEST_DIR/events" "$RESTART_TEST_DIR/states"
BASH
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');
 print {$in} $script;close $in;
 my $output=do {local $/;<$out>};my $errors=do {local $/;<$err>};waitpid($pid,0);
 is($? >> 8,0,"$scenario harness exits cleanly") or diag($errors);
 like($output,qr/quit\nspawn 1 .* -Y a/,'graceful close precedes reopen with the requested integration flag');
 if($scenario eq 'fail') {
  like($output,qr/result=1 mode=off detail=.*Communications failure/,'permanent failure preserves driver cause and leaves old mode unchanged');
 } else {
  like($output,qr/result=0 mode=a detail=\n/,'ready reader commits requested mode and clears stale errors');
 }
 my $attempts=()=$output=~/^spawn /mg;
 is($attempts,$scenario eq 'ready'?1:2,"$scenario has a bounded attempt count");
 like($output,qr/Preparing meter integration for 0% \(attempt 1\/2\)/,'meter preparation is published as live progress');
}
my ($sample)=$source=~/^(capture_series_average_sample\(\) \{.*?^\})/ms;
my ($quit)=$source=~/^(series_quit_spotread\(\) \{.*?^\})/ms;
ok($sample && $quit,'extract production retry and quit protocol functions');
for my $scenario ('recover','fail','quit') {
 my $dir=tempdir(CLEANUP=>1);
 local $ENV{RESTART_TEST_DIR}=$dir;local $ENV{RESTART_TEST_SCENARIO}=$scenario;
 my $functions="$sample\n$quit";
 $functions=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
 my $script=<<'BASH';
OUTFILE="$RESTART_TEST_DIR/output"
CMDPIPE="$RESTART_TEST_DIR/unused-pipe"
touch "$OUTFILE"
exec 3>"$RESTART_TEST_DIR/keys"
METER_SERIES_FD_OPEN=1
BG_PID=''
key_count() { wc -c < "$RESTART_TEST_DIR/keys" | tr -d ' '; }
output_size() { echo 0; }
series_stop_requested() { return 1; }
sleep() { :; }
nonblack_zero_reading() { return 1; }
parse_latest_result() { echo valid-measurement; }
manual_ready_prompt_reason() { return 1; }
count_results() {
 if [[ "$RESTART_TEST_SCENARIO" == recover && $(key_count) == 3 ]]; then echo 1; else echo 0; fi
}
clean_output_since() {
 if [[ "$RESTART_TEST_SCENARIO" == quit ]]; then
  echo 'Spot read stopped at user request! Hit Esc or Q to give up, any other key to retry:'
 elif [[ $(key_count) == 2 ]]; then
  echo 'Hit ESC or Q to exit, any other key to take a reading:'
 else
  echo 'Spot read failed due to communication problem. Any other key to retry:'
 fi
}
pgrep() { [[ $(key_count) -lt 2 ]]; }
pkill() { echo UNEXPECTED-FORCED-KILL; }
record_series_cancel_usb_suppression() { :; }
BASH
 $script.=$functions."\n".<<'BASH';
if [[ "$RESTART_TEST_SCENARIO" == quit ]]; then
 series_quit_spotread
 echo "quit-keys=$(key_count)"
else
 capture_series_average_sample 2
 result=$?
 echo "sample-result=$result keys=$(key_count) parsed=$SERIES_AVERAGE_PARSED"
fi
BASH
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;
 my $output=do{local $/;<$out>};my $errors=do{local $/;<$err>};waitpid($pid,0);
 is($? >> 8,0,"$scenario protocol harness exits cleanly") or diag($errors);
 if($scenario eq 'quit') {
  like($output,qr/quit-keys=2/,'normal quit answers the driver confirmation before closing FIFO');
  unlike($output,qr/UNEXPECTED-FORCED-KILL/,'responsive reader needs no forced termination');
 } elsif($scenario eq 'recover') {
  like($output,qr/sample-result=0 keys=3 parsed=valid-measurement/,'one trigger, error acknowledgement and one retry trigger recover the reading');
 } else {
  like($output,qr/sample-result=1 keys=3 parsed=\n/,'a second communication failure stops without extra triggers or stale data');
 }
}
done_testing();
