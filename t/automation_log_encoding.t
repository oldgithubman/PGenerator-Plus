use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Encode qw(decode FB_CROAK);
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('log-encoding-test','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
for my $message ("Generating 33\x{b3} cube", "Target \x{394}E 0.5", 'Plain ASCII status') {
 my $bytes='';
 {local *STDERR;open(STDERR,'>',\$bytes) or die $!;main::_log($message);}
 my $decoded=eval {decode('UTF-8',$bytes,FB_CROAK)};
 is($@,'','runner emits valid UTF-8 bytes');
 like($decoded,qr/\Q$message\E\n$/,'activity-log decoding retains the exact status text');
}
done_testing();
