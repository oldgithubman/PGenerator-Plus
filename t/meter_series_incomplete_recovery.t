use strict;
use warnings;
use FindBin qw($Bin);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

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
done_testing();
