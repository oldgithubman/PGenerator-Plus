use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use JSON::PP;
use Test::More;
require "$Bin/../usr/share/PGenerator/lg.pm";
my $dir=tempdir(CLEANUP=>1);
local $ENV{PGEN_AUTOMATION_DIR}=$dir;
my ($calibration,$running,$calls)=(0,0,0);
{
 no warnings 'redefine';
 local *main::lg_load_clients=sub {return {calibration_mode=>$calibration}};
 local *main::webui_meter_series_alive=sub {return $running};
 local *main::verify_lg_panel_light=sub {
  $calls++;
  open(my $other,'>>',"$dir/execution.lock") or die $!;
  ok(!flock($other,LOCK_EX|LOCK_NB),'queue start lock stays held throughout verification');
  return {status=>'ok'};
 };
 my $run=sub {decode_json(main::webui_lg_verify_panel_light(encode_json($_[0])))};
 is($run->({})->{status},'error','explicit confirmation is required');
 $calibration=1;
 like($run->({confirm_reversible_test=>1})->{message},qr/Exit calibration/,'calibration mode blocks the test');
 $calibration=0;$running=1;
 like($run->({confirm_reversible_test=>1})->{message},qr/active meter/,'active meter blocks the test');
 $running=0;
 open(my $busy,'>>',"$dir/execution.lock") or die $!;
 flock($busy,LOCK_EX) or die $!;
 like($run->({confirm_reversible_test=>1})->{message},qr/state is changing/,'concurrent queue claim blocks verification without waiting');
 close $busy;
 is($calls,0,'all guards stop before any test execution');
 is($run->({confirm_reversible_test=>1})->{status},'ok','idle confirmed test can run');
 open(my $after,'>>',"$dir/execution.lock") or die $!;
 ok(flock($after,LOCK_EX|LOCK_NB),'queue lock releases after verification returns');
}
done_testing();
