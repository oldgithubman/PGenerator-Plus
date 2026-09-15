use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
my $output=`node "$Bin/js/automation_chart_targets.js" 2>&1`;
is($?,0,'shared chart target regression passes') or diag $output;
like($output,qr/PASS automation chart targets/,'gamma labels and restoration exercised');
done_testing();
