use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
# The appliance has no node (T3); skip there like the other JS-backed tests.
my $node=`sh -c 'command -v node || command -v nodejs' 2>/dev/null`;chomp $node;
plan skip_all=>'Node is required for the chart target checks' if !$node;
my $output=`"$node" "$Bin/js/automation_chart_targets.js" 2>&1`;
is($?,0,'shared chart target regression passes') or diag $output;
like($output,qr/PASS automation chart targets/,'gamma labels and restoration exercised');
done_testing();
