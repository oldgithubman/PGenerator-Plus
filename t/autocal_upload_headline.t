# Regression for PR 14 test report P25: the 1D DPG upload headline leads with
# the point's own result, never a worst-case value that reads as a failure.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
{local @ARGV=();local $SIG{__WARN__}=sub {};require "$Bin/../usr/bin/meter_lg_autocal.pl";}
my $h=\&main::autocal_dpg_upload_headline;
is($h->('HDR20','7%',8,8,1,0.99,0.691,'run max',23.787,0.5),
 'HDR20 1D DPG 7% 8/8 uploaded (point dE=0.990, best=0.691, run max=23.787, target<=0.50)',
 'the report example reads as the point result with its best, and labels the run-wide worst');
is($h->('HDR20','7%',3,8,1,0.2,0.25,'run max',1,0.5),
 'HDR20 1D DPG 7% 3/8 uploaded (point dE=0.200, best=0.200, run max=1.000, target<=0.50)',
 'a stale best that is worse than the point is never shown');
is($h->('SDR26','10%',1,8,1,undef,undef,'anchor max',0.4,0.5),
 'SDR26 1D DPG 10% 1/8 uploaded (point dE=n/a, best=n/a, anchor max=0.400, target<=0.50)',
 'a missing dE prints n/a, never -1');
is($h->('SDR26','10%',2,8,0,0.8,0.5,'anchor max',0.9,0.5),
 'SDR26 1D DPG 10% 2/8 upload failed after retries (point dE=0.800, anchor max=0.900)',
 'the failure headline also leads with the point');
is($h->('HDR20','50%',4,8,1,undef,0.3,'run max',2,0.5),
 'HDR20 1D DPG 50% 4/8 uploaded (point dE=0.300, best=0.300, run max=2.000, target<=0.50)',
 'without a point reading the best stands in for it');
done_testing();
