use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

open my $fh, '<', "$Bin/../usr/bin/meter_session.sh" or die $!;
my $source = do { local $/; <$fh> };
my ($cleanup) = $source =~ /^(cleanup\(\) \{.*?^\})/ms;
my ($quit) = $source =~ /^(stop_spotread_child\(\) \{.*?^\})/ms;
ok($cleanup, 'extract production cleanup without starting hardware');
my ($respawn) = $source =~ /^(respawn_spotread \(\) \{.*?^\})/ms;
ok($quit, 'shared quit protocol exists');
like($cleanup, qr/stop_spotread_child/, 'Stop uses the shared quit protocol');
is(scalar(() = $respawn =~ /stop_spotread_child/g), 2, 'integration changes and failed startup retries use the same quit protocol');
unlike($respawn, qr/printf "Q"|pkill -9/, 'respawn cannot bypass the shared shutdown handshake');
for my $scenario (qw(confirm direct wedged closed stale simulator)) {
 my $dir = tempdir(CLEANUP => 1);
 local $ENV{QUIT_TEST_DIR} = $dir;
 local $ENV{QUIT_SCENARIO} = $scenario;
 my $script = <<'BASH';
OUTFILE="$QUIT_TEST_DIR/output"
CMDPIPE="$QUIT_TEST_DIR/pipe"
CMD_FIFO="$QUIT_TEST_DIR/commands"
PID_FILE="$QUIT_TEST_DIR/pid"
CONFIG_FILE="$QUIT_TEST_DIR/config"
READY_FILE="$QUIT_TEST_DIR/ready"
STARTUP_READY_FILE="$QUIT_TEST_DIR/start-ready"
BG_PID=123456789
touch "$OUTFILE" "$CMD_FIFO" "$PID_FILE" "$CONFIG_FILE" "$READY_FILE" "$STARTUP_READY_FILE"
exec 3>"$QUIT_TEST_DIR/keys"
exec 4>"$CMD_FIFO"
[[ "$QUIT_SCENARIO" == closed ]] && { BG_PID=''; exec 3>&-; }
[[ "$QUIT_SCENARIO" == stale ]] && printf 'any other key to retry:' > "$OUTFILE"
log() { printf '%s\n' "$*" >> "$QUIT_TEST_DIR/events"; }
companion_show_alignment() { :; }
key_count() { wc -c < "$QUIT_TEST_DIR/keys" | tr -d ' '; }
output_size() { wc -c < "$OUTFILE" | tr -d ' '; }
clean_output_since() { tail -c +$(($1 + 1)) "$OUTFILE"; }
alive() {
 [[ -f "$QUIT_TEST_DIR/killed" || "$QUIT_SCENARIO" == closed ]] && return 1
 case "$QUIT_SCENARIO" in
  direct) [[ $(key_count) -lt 1 ]] ;;
  confirm|simulator) [[ $(key_count) -lt 2 ]] ;;
  *) return 0 ;;
 esac
}
sleep() {
 if [[ "$QUIT_SCENARIO" == confirm || "$QUIT_SCENARIO" == simulator ]] && [[ $(key_count) == 1 ]]; then
  printf 'Spot read stopped at user request! Hit Esc or Q to give up, any other key to retry:' > "$OUTFILE"
 fi
}
kill() {
 if [[ "$1" == -0 ]]; then alive; else log "FORCED kill $*"; touch "$QUIT_TEST_DIR/killed"; fi
}
pgrep() {
 if [[ "$QUIT_SCENARIO" == simulator ]]; then [[ "$*" == '-x spotread_sim' ]] && alive
 else [[ "$*" == '-x spotread' ]] && alive; fi
}
pkill() { log "FORCED pkill $*"; touch "$QUIT_TEST_DIR/killed"; }
wait() { log reaped; return 0; }
BASH
 $script .= ($quit || '')."\n$cleanup\n".<<'BASH';
cleanup
printf 'keys=%s\n' "$(key_count)"
[[ -f "$CMD_FIFO" || -f "$PID_FILE" || -f "$READY_FILE" ]] && echo LEFTOVER-SESSION
cat "$QUIT_TEST_DIR/events"
BASH
 my $err = gensym;
 my $pid = open3(my $in, my $out, $err, 'bash');
 print {$in} $script; close $in;
 my $output = do { local $/; <$out> };
 my $errors = do { local $/; <$err> };
 waitpid($pid, 0);
 is($? >> 8, 0, "$scenario cleanup finishes") or diag($errors);
 unlike($output, qr/LEFTOVER-SESSION/, "$scenario releases session markers");
 if ($scenario eq 'confirm' || $scenario eq 'simulator') {
  like($output, qr/keys=2\b/, "$scenario answers the fresh quit confirmation");
  unlike($output, qr/FORCED/, "$scenario exits without terminating a responsive driver");
 } elsif ($scenario eq 'wedged' || $scenario eq 'stale') {
  like($output, qr/keys=1\b/, "$scenario does not invent a confirmation from old output");
  like($output, qr/FORCED/, "$scenario retains bounded forced cleanup");
 } else {
  like($output, $scenario eq 'closed' ? qr/keys=0\b/ : qr/keys=1\b/, "$scenario sends only necessary commands");
  unlike($output, qr/FORCED/, "$scenario needs no force");
 }
}
done_testing();
