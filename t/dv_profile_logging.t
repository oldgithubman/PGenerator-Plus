use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);

my $dir=tempdir(CLEANUP=>1);
local $ENV{PGEN_AUTOMATION_DIR}=$dir;
make_path("$dir/runs/fixture/items/0");
open my $config,'>',"$dir/config.json" or die $!;
print $config encode_json({fixture_mode=>1,fixture_white_y=>500,
 automation_worker_id=>'dv-fixture',automation_token=>'never-log-this-token',
 calibration_trace=>{run=>'fixture',job=>1,stage=>'volume-done'}});
close $config;
# Exercise the real worker without a meter, TV or daemon. Its mutable state
# must still leave a durable sequence of measurements and a terminal event.
my $pid=fork(); die $! if !defined $pid;
if (!$pid) {
 open STDERR,'>',"$dir/worker.log" or die $!;
 exec $^X,"$Bin/../usr/bin/meter_lg_dv_profile.pl","$dir/config.json","$dir/state.json","$dir/stop";
 die $!;
}
waitpid($pid,0);
is($?,0,'fixture worker completes');
sub slurp {open my $fh,'<',$_[0] or die $!;local $/;return <$fh>}
is(decode_json(slurp("$dir/state.json"))->{status},'complete','instrumented worker retains its result');
my $raw=slurp("$dir/runs/fixture/items/0/diagnostics.ndjson");
my @events=map {decode_json($_)} split /\n/,$raw;
my @reads=grep {$_->{event} eq 'measurement-end'} @events;
is_deeply([map {$_->{patch}} @reads],[qw(black white red green blue)],'every DV patch is retained in order');
is(scalar(grep {($_->{worker}||'') eq 'dv-fixture' && $_->{job}==1 && $_->{stage} eq 'volume-done'} @reads),5,
 'all readings retain worker and stage identity');
is($reads[1]{luminance},500,'white luminance is retained');
is($events[-1]{status},'complete','terminal state survives beyond the mutable status file');
unlike($raw,qr/never-log-this-token/,'worker credentials stay out of the artifact');
my $log=slurp("$dir/worker.log");
like($log,qr/\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\] Measured white \| x [\d.]+; y [\d.]+ \| Y 500\.0000 cd\/m2/,
 'archived text log contains a readable measured result with UTC time');
like($log,qr/Dolby Vision profile measured\n\z/,'text log preserves completion');
done_testing();
