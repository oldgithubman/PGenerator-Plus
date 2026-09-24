use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
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
 my ($series,$total,$range,$r,$g,$b,$imax,$ire,$path_prefix)=@_;
 my $script="set -u\nSERIES_ID='$series'\nTOTAL='$total'\nPATTERN_SIGNAL_RANGE='$range'\n"
  .$functions."\nread_timeout_seconds \"\$(step_timeout_stimulus '$r' '$g' '$b' '$imax' '$ire')\"\n";
 # Feed via stdin (the extracted helpers contain single quotes, so bash -c
 # quoting would collide; same open3 pattern as t/meter_series_identity.t).
 my $err=gensym;
 my $run = sub {
  local $ENV{PATH} = defined($path_prefix) ? "$path_prefix:$ENV{PATH}" : $ENV{PATH};
  my $pid=open3(my $in,my $out,$err,'bash');
  print {$in} $script;close $in;
  my $got=do {local $/;<$out>};my $errors=do {local $/;<$err>};waitpid($pid,0);
  ($got,$errors);
 };
 my ($got,$errors)=$run->();
 is($? >> 8,0,'helper harness runs cleanly') or diag $errors;
 # The PATH-prefix case asserts the guard path is silent (no spurious
 # stderr from [[ -gt ]] on odd numerics), so pin stderr there.
 is($errors,'','harness stderr is clean: '.$errors) if defined $path_prefix;
 chomp($got);
 return $got;
}

sub stimulus {
 my ($series,$range,$r,$g,$b,$imax,$ire,$path_prefix)=@_;
 my $script="set -u\nSERIES_ID='$series'\nTOTAL=107\nPATTERN_SIGNAL_RANGE='$range'\n"
  .$functions."\nstep_timeout_stimulus '$r' '$g' '$b' '$imax' '$ire'\n";
 my $err=gensym;
 my $run = sub {
  local $ENV{PATH} = defined($path_prefix) ? "$path_prefix:$ENV{PATH}" : $ENV{PATH};
  my $pid=open3(my $in,my $out,$err,'bash');
  print {$in} $script;close $in;
  my $got=do {local $/;<$out>};my $errors=do {local $/;<$err>};waitpid($pid,0);
  ($got,$errors);
 };
 my ($got,$errors)=$run->();
 is($? >> 8,0,'stimulus harness runs cleanly') or diag $errors;
 is($errors,'','stimulus harness stderr is clean: '.$errors);
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

# The stimulus is clamped to [0,100] like the webui.pm achromatic inference:
# over-range codes read 100, below-black legal-range codes read 0.
is(stimulus('colors_test','',300,300,300,255,0),'100.000','over-range codes clamp to 100');
is(stimulus('colors_test',1,5,5,5,255,0),'0.000','legal-range code under black clamps to 0');

# input_max = 0 must take the ire fallback, not divide (awk would coerce to
# im=255 and hide a regressed guard; ire 50 vs a derived 0 separates them).
is(timeout('colors_test',107,'',128,128,128,0,50),30,'input_max 0 falls back to ire');
is(stimulus('colors_test','',128,128,128,0,50),'50','input_max 0 stimulus is the raw ire');

# Scientific-notation input_max passes is_number but used to make
# [[ -gt ]] print 'value too great for base' to stderr; float_le is silent.
# stimulus() asserts empty stderr on every run, so the second assertion
# pins the no-log-noise property.
is(timeout('colors_test',107,'',255,255,255,'1e3',0),30,'sci-notation input_max reaches the ladder');
is(stimulus('colors_test','',255,255,255,'1e3',0),'25.500','sci-notation input_max derives from codes silently');

# An awk failure (empty output) must not hand read_timeout_seconds an empty
# argument (which ${1:-0} would silently read as 0 -> 90 s for a bright
# patch). Shadow awk with a stub that dies silently: ire 50 distinguishes
# the fallback (profile bump 30) from an empty argument (90).
my $stub_dir = tempdir(CLEANUP => 1);
open my $stub,'>',"${stub_dir}/awk" or die $!;
print {$stub} "#!/bin/sh\nexit 1\n";
close $stub;
chmod 0755,"${stub_dir}/awk";
is(stimulus('colors_test','',255,255,255,255,50,$stub_dir),'50','awk failure falls back to ire, silently');
is(timeout('colors_test',107,'',255,255,255,255,50,$stub_dir),30,'bright patch with dead awk keeps profile bump, not 90s');

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
