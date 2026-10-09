use strict;
use warnings;
use FindBin qw($Bin);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

use File::Temp qw(tempfile);

open my $fh,'<',"$Bin/../usr/bin/meter_series.sh" or die $!;
my $source=do {local $/;<$fh>};
my ($block)=$source=~/^( if \[\[ -z "\$READING" \]\]; then\n  echo "\[\$\(date[^\n]*read timeout:.*?)^  PATCH_NO_READING_RETRIES=/ms;
ok($block,'extract the incomplete-read decision block from the series loop');
like($source,qr/RETRY_TIMEOUT=\$\(\(RETRY_TIMEOUT \* RETRY_TIMEOUT_SCALE\)\)/,'re-read budget is scaled by the recovery factor');
unlike($block,qr/kill -9|pkill/,'recovery retires the child through restart_spotread_session only');

# scenario => [READ_INCOMPLETE, REQUIRE_DEVICE_READY, SR_CMD_BASE, restart_ok]
my %cases=(
 recover   =>[1,0,'reader',1],
 restartfail=>[1,0,'reader',0],
 spectro   =>[1,1,'reader',1],
 nocmd     =>[1,0,'',1],
 unusable  =>[0,0,'reader',1],
);
for my $name (sort keys %cases) {
 my ($inc,$ready,$cmd,$ok)=@{$cases{$name}};
 my $script=<<"BASH";
READING=""; STEP_NUM=3; IRE=100; READ_TIMEOUT=10; READ_START=\$SECONDS; NAME='White 100%'
READ_INCOMPLETE=$inc; REQUIRE_DEVICE_READY=$ready; SR_CMD_BASE='$cmd'; COMM_RETRY_SEEN=0
restart_ok=$ok
restart_spotread_session() { echo restart-called; return \$((1-restart_ok)); }
series_meter_read_failure_exit() { echo "EXIT: \$1"; exit 7; }
BASH
 $script.="main() {\n$block\n fi\n echo \"scale=\$RETRY_TIMEOUT_SCALE incomplete=\$READ_INCOMPLETE comm=\$COMM_RETRY_SEEN\"\n}\n";
 $script=~s{/tmp/meter_series_debug\.log}{/dev/null}g;
 $script.="main\n";
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;
 my $output=do{local $/;<$out>};my $errors=do{local $/;<$err>};waitpid($pid,0);
 my $rc=$? >> 8;
 if($name eq 'recover') {
  is($rc,0,'recover: series continues');
  like($output,qr/restart-called\nscale=2 incomplete=0 comm=1/,'recover: child restarted once, re-read gets doubled budget') or diag($output,$errors);
 } elsif($name eq 'restartfail') {
  is($rc,7,'restartfail: series stops');
  like($output,qr/restart-called\nEXIT: .*could not be restarted/,'restartfail: stops with restart message');
 } elsif($name eq 'spectro' || $name eq 'nocmd') {
  is($rc,7,"$name: series stops");
  unlike($output,qr/restart-called/,"$name: no restart attempted");
  unlike($output,qr/could not be restarted/,"$name: message does not claim a restart was tried");
 } else {
  is($rc,0,'unusable: ordinary retry path');
  like($output,qr/^scale=1 incomplete=0/m,'unusable: no restart, normal budget');
  unlike($output,qr/restart-called/,'unusable: child not restarted');
 }
}

# Second harness: run the recovered block through the retry loop to the end.
my ($loop)=$source=~/^( if \[\[ -z "\$READING" \]\]; then\n  echo "\[\$\(date[^\n]*read timeout:.*?^  done\n fi\n)(?=\n if \[\[ -n "\$READING" \]\] && nonblack_zero_reading)/ms;
ok($loop,'extract the decision block plus its retry loop');
like($source,qr/^NO_READING_RETRIES=1$/m,'ordinary no-reading retries default to one');
my ($pre,$post)=split /RETRY_TIMEOUT=\$\(\(RETRY_TIMEOUT \* RETRY_TIMEOUT_SCALE\)\)/,$loop,2;
like($pre,qr/RETRY_TIMEOUT=\$\(read_timeout_seconds/,'scale is applied after the base timeout is computed');

# scenario => [re-read completes, result parses]
my %loops=(
 reread_ok   =>[1,1],
 reread_stall=>[0,1],
 reread_bad  =>[1,0],
);
for my $name (sort keys %loops) {
 my ($completes,$parses)=@{$loops{$name}};
 my ($lfh,$log)=tempfile(UNLINK=>1);close $lfh;
 my $script=<<"BASH";
READING=""; STEP_NUM=3; IRE=100; READ_TIMEOUT=10; READ_START=\$SECONDS; NAME='White 100%'
READ_INCOMPLETE=1; REQUIRE_DEVICE_READY=0; SR_CMD_BASE='reader'; COMM_RETRY_SEEN=0
exec 3>/dev/null; : > $log.polls
NO_READING_RETRIES=1; PATTERN_DELAY_SEC=0; STEP_DELAY=0; READ_POLL_SEC=0
R=1;G=1;B=1;i=3;READINGS="";WHITE_READING=null;SERIES_ID=x
completes=$completes; parses=$parses; posts=0; POLLS=$log.polls
restart_spotread_session() { return 0; }
series_meter_read_failure_exit() { echo "EXIT: \$1 timeout=\$RETRY_TIMEOUT posts=\$posts"; exit 7; }
write_state_json() { cat >/dev/null; }
post_patch() { posts=\$((posts+1)); }
sleep() { SECONDS=\$((SECONDS+1)); }
count_results() { echo x >> \$POLLS; if (( completes )) && (( \$(wc -l < \$POLLS) > 1 )); then echo 2; else echo 1; fi; }
output_size() { echo 0; }
clean_output_since() { :; }
series_stop_requested() { return 1; }
read_timeout_seconds() { echo 10; }
step_timeout_stimulus() { echo 1; }
manual_ready_prompt_reason() { return 1; }
parse_latest_result() { (( parses )) && echo parsed; }
build_step_reading_json() { echo '{"ok":1}'; }
BASH
 (my $body=$loop)=~s{/tmp/meter_series_debug\.log}{$log}g;
 $script.="main() {\n$body\n echo \"done reading=\$READING timeout=\$RETRY_TIMEOUT posts=\$posts\"\n}\nmain\n";
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;
 my $output=do{local $/;<$out>};my $errors=do{local $/;<$err>};waitpid($pid,0);
 my $rc=$? >> 8;
 open my $lf,'<',$log or die $!;my $dbg=do{local $/;<$lf>};
 if($name eq 'reread_ok') {
  is($rc,0,'reread_ok: series continues') or diag($output,$errors);
  like($output,qr/done reading=\{"ok":1\} timeout=20 posts=1/,'reread_ok: one re-read at twice the budget');
  my @tries=$dbg=~/no reading retry: .*retry=(\d+)\/(\d+)/g;
  is("@tries",'1 1','reread_ok: exactly one retry iteration');
 } elsif($name eq 'reread_stall') {
  is($rc,7,'reread_stall: series stops when the re-read does not complete');
  like($output,qr/EXIT: Meter retry did not complete for White 100%.* timeout=20 posts=1/,'reread_stall: stops after a single re-read at twice the budget') or diag($output,$errors);
 } else {
  is($rc,7,'reread_bad: series stops when the re-read does not parse');
  like($output,qr/EXIT: Meter retry returned an unparseable result/,'reread_bad: unparseable message');
 }
}
done_testing();
