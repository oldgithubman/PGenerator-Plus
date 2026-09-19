use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use Test::More;

ok(defined(do "$Bin/../usr/sbin/pgenerator-lg"),'TV helper loads') or die $@;
my $dir=tempdir(CLEANUP=>1);
local $ENV{PGEN_AUTOMATION_DIR}=$dir;
local $main::DIAG_LOG_PATH="$dir/last-write.log";
# An unwritable diagnostic destination must not poison stdout or stderr:
# the daemon combines both when it decodes the helper's JSON response.
make_path("$dir/runs/trace/items/0/diagnostics.ndjson");
local *main::request_from_env=sub {{action=>'picture_get',ip=>'192.0.2.1',calibration_trace=>{run=>'trace',job=>1,op=>'request-1'}}};
local *main::lg_picture_get_workflow=sub {
 PGCalibrationLog::event('TV','test',{status=>'response'});
 return {status=>'ok',brightness=>50};
};
my ($out,$err)=('','');
{
 local *STDOUT; open STDOUT,'>',\$out or die $!;
 local *STDERR; open STDERR,'>',\$err or die $!;
 main::main();
}
is($err,'','diagnostic failure does not contaminate the helper response');
is_deeply(decode_json($out),{status=>'ok',brightness=>50},'TV response remains intact');
open my $fh,'<',"$dir/last-write.log" or die $!;
like(do {local $/;<$fh>},qr/diagnostics-unavailable.*Diagnostics unavailable/,'diagnostic loss is recorded locally');
is_deeply($PGCalibrationLog::CONTEXT,{},'helper invocation restores prior context');
done_testing();
