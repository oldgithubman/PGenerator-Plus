use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
my $node=`command -v node 2>/dev/null`;chomp $node;
plan skip_all=>'Node unavailable' if(!$node);
my $out=`"$node" "$Bin/js/lg_logical_controls.js" 2>&1`;
is($? >> 8,0,'logical panel aliases and verification evidence classifications pass') or diag($out);
done_testing();
