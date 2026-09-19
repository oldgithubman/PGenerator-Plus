use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP qw(decode_json);

sub timings {
 my ($script)=@_;
 open my $fh,'-|','bash','-c','source "$1"; '.$script,'timing-test',"$Bin/../usr/bin/pgen_meter_timing.sh" or die $!;
 local $/; my $out=<$fh>; close $fh;
 is($?,0,'timing helper exits cleanly');
 return $out;
}
my $result=timings(q{
 meter_clock_ms() { METER_CLOCK_MS=1000; }
 meter_timing_start
 METER_PATTERN_DONE_MS=1120
 METER_SETTLE_DONE_MS=2920
 meter_clock_ms() { METER_CLOCK_MS=4321; }
 meter_timing_finish
 printf '%s' "$METER_TIMING_JSON"
});
is_deeply(decode_json($result),{pattern_ms=>120,settle_ms=>1800,measurement_ms=>1401,total_ms=>3321},
 'phase timings add up to the entire read');
for my $start (0,5000) {
 my $result=timings('METER_READ_STARTED_MS='.$start.q{;
 METER_PATTERN_DONE_MS=1120; METER_SETTLE_DONE_MS=2920
 meter_clock_ms() { METER_CLOCK_MS=4321; }
 meter_timing_finish
 printf '%s' "$METER_TIMING_JSON"
 });
 is_deeply(decode_json($result),{},'missing or unordered clock samples do not advertise false timings');
}
like(timings('meter_clock_ms; printf "%s" "$METER_CLOCK_MS"'),qr/^[1-9]\d+$/,
 'platform monotonic clock supplies milliseconds');
done_testing();
