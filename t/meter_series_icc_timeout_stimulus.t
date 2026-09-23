use strict;
use warnings;
use FindBin qw($Bin);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;

# PR #39 round two: ICC profile steps carry ire:index (position, not light
# level) because readings are keyed by ire, so read_timeout_seconds must be
# fed a stimulus derived from the drive codes for colors_* series. Extracting
# the real bash helpers and pinning the matrix here mirrors the timeout
# selection without USB or a display.
open my $fh,'<',"$Bin/../usr/bin/meter_series.sh" or die $!;
my $source=do {local $/;<$fh>};close $fh;
my @functions;
for my $name (qw(is_number float_le step_timeout_stimulus read_timeout_seconds)) {
 my ($f)=$source=~/^($name\(\) \{.*?^\})/ms;
 die "Missing production function $name" if !$f;
 push @functions,$f;
}
my $functions=join("\n",@functions);

sub timeout {
 my ($series,$total,$range,$r,$g,$b,$imax,$ire)=@_;
 my $script="set -u\nSERIES_ID='$series'\nTOTAL='$total'\nPATTERN_SIGNAL_RANGE='$range'\n"
  .$functions."\nread_timeout_seconds \"\$(step_timeout_stimulus '$r' '$g' '$b' '$imax' '$ire')\"\n";
 # Feed via stdin (the extracted helpers contain single quotes, so bash -c
 # quoting would collide; same open3 pattern as t/meter_series_identity.t).
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');
 print {$in} $script;close $in;
 my $got=do {local $/;<$out>};my $errors=do {local $/;<$err>};waitpid($pid,0);
 is($? >> 8,0,'helper harness runs cleanly') or diag $errors;
 chomp($got);
 return $got;
}

# ICC colors_* series (>=100 steps): the low-grey ladder gets its tolerance
# from drive codes, and bright patches no longer inherit it from a low index.
is(timeout('colors_test',107,'',255,255,255,255,0),30,'white at index 0 gets the profile bump, not 90s');
is(timeout('colors_test',107,'',0,0,0,255,1),90,'black code 0 gets 90s');
is(timeout('colors_test',107,'',3,3,3,255,5),70,'Grey 1 (code 3/255, ~1.2%) gets 70s');
is(timeout('colors_test',107,'',10,10,10,255,17),70,'Grey 4 (code 10/255) gets 70s despite index 17');
is(timeout('colors_test',107,'',13,13,13,255,21),30,'Grey 5 (code 13/255, 5.1%) gets 30s');
is(timeout('colors_test',107,'',255,0,0,255,2),30,'Red 100 at index 2 no longer gets 70s');
is(timeout('colors_test',175,'',12,12,12,1023,40),70,'HDR 12-bit near-black code 12/1023 gets 70s');
# Limited/legal range maps 16..235 into stimulus.
is(timeout('colors_test',107,1,16,16,16,255,7),90,'legal-range black code 16 reads 0% -> 90s');
is(timeout('colors_test',107,1,235,235,235,255,8),30,'legal-range white code 235 reads 100% -> 30s');
# Malformed codes must not produce awk garbage; fall back to the ire argument.
# ire 50 distinguishes: awk-coerced garbage would read code 0 -> 90s, while
# the fallback ire 50 lands in the profile-sized colors_* branch (30s).
is(timeout('colors_test',107,'',q{x},q{y},q{z},255,50),30,'non-numeric codes fall back to ire');

# Non-ICC series keep the untouched ire ladder.
is(timeout('greyscale_manual',21,'',3,3,3,255,'0.8'),90,'greyscale ire 0.8 -> 90');
is(timeout('greyscale_manual',21,'',3,3,3,255,'1.18'),70,'greyscale ire 1.18 -> 70');
is(timeout('greyscale_manual',21,'',16,16,16,255,'6.27'),20,'greyscale ire 6.27 -> 20');
is(timeout('greyscale_manual',21,'',128,128,128,255,50),10,'greyscale ire 50 -> 10');
is(timeout('colors_test',50,'',13,13,13,255,21),20,'colors below the 100-step threshold uses the 20s rung');

# Every read_timeout_seconds call site in the series loops must receive the
# code-derived stimulus, not the raw (possibly index-valued) ire. A call site
# reverted to "$IRE" re-opens the AVS abort on real ICC runs.
my @call_lines = grep {/read_timeout_seconds /} split /\n/, $source;
@call_lines = grep {!/^read_timeout_seconds\(\)/} @call_lines;
ok(scalar(@call_lines) >= 5,'at least five read_timeout_seconds call sites present');
for my $line (@call_lines) {
 like($line,q{/step_timeout_stimulus/},'call site derives stimulus: '.substr($line,0,90));
}

done_testing();
