use strict;
use warnings;
use FindBin qw($Bin);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;
for my $case (
 ['accepted','{"status":"ok","pattern":"patch"}',0,1],
 ['HTTP failure','HTTP 503',22,0],
 ['timeout','Timed out',28,0],
 ['JSON failure','{"status":"error","message":"Renderer busy"}',0,0],
 ['invalid JSON','<!doctype html>',0,0],
 ['stale stop','{"status":"ok","pattern":"stop"}',0,0],
 ['superseded','{"status":"ok","pattern":"patch","unchanged":true}',0,0],
 ['unescaped message',q({"status":"error","message":"Failed \"quoted\" request\nagain"}),0,0],
) {
 local $ENV{ACK_RESPONSE}=$case->[1];local $ENV{ACK_EXIT}=$case->[2];
 my $pid=open3(my $in,my $out,my $err=gensym,'bash');
 print {$in} "source '$Bin/../usr/bin/pgen_meter_pattern.sh'\n";
 print {$in} <<'BASH';
curl() { printf '%s' "$ACK_RESPONSE"; return "$ACK_EXIT"; }
if meter_post_local_patch http://localhost/api '{}'; then echo accepted; else meter_pattern_error_json read-123; fi
BASH
 close $in;my $output=do{local $/;<$out>};my $errors=do{local $/;<$err>};waitpid($pid,0);
 is($?>>8,0,"$case->[0]: helper completes") or diag $errors;
 if($case->[3]) {like($output,qr/^accepted/,"$case->[0]: measurement may proceed")}
 else {
  require JSON::PP;my $error=eval {JSON::PP::decode_json($output)};
  ok($error,"$case->[0]: valid JSON error") or diag $output;
  is($error->{error_code},'pattern-request-failed',"$case->[0]: explicit pattern failure");
  is($error->{request_id},'read-123',"$case->[0]: associated with the correct read");
 }
}
done_testing();
