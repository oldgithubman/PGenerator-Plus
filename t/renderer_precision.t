use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

sub read_file {
 open my $fh, '<', $_[0] or die "$!";
 local $/;
 return <$fh>;
}
my $tmp=tempdir(CLEANUP=>1);
my @compiler=split /\s+/,($ENV{CXX}||'c++');
sub compile {
 my ($file,$output)=@_;
 my $pid=fork();
 die "fork: $!" if(!defined $pid);
 if(!$pid) {
  open STDOUT,'>',"$tmp/compiler.log" or die $!;
  open STDERR,'>&',\*STDOUT or die $!;
  exec @compiler,'-std=c++11','-O0',"-I$Bin/../src/pattern_generator/src",$file,'-o',$output;
  exit 127;
 }
 waitpid($pid,0);
 return $?==0;
}
open my $probe,'>',"$tmp/probe.cpp" or die $!;
print $probe "int main(){return 0;}\n";
close $probe;
plan skip_all=>'No working C++ compiler' unless compile("$tmp/probe.cpp","$tmp/probe");

my $source=read_file("$Bin/../src/pattern_generator/src/ofApp.cpp");
my @methods;
for my $name (qw(setColor normalizeSourceValue setBackground clearBackground restoreBackground shader_begin shader_end)) {
 my @found=$source=~/(^(?:void|int) ofApp::\Q$name\E\([^)]*\)\s*\{.*?^\})/msg;
 die "Missing method $name" unless @found;
 push @methods,$found[-1]; # shader_begin also has an inactive historical copy
}
my $header=read_file("$Bin/../src/ofxRPI4Window/src/ofxRPI4Window.h");
my ($required)=$header=~/(static bool usesColourShader\(\) \{.*?^    \})/ms;
ok(defined($required),'extract the real shader-selection predicate');
my $fixture=read_file("$Bin/fixtures/renderer_precision.cpp");
$fixture=~s{// COLOUR_SHADER_PREDICATE}{$required};
$fixture=~s{// REAL_PRECISION_METHODS}{join("\n",@methods)}e;
open my $cpp,'>',"$tmp/precision.cpp" or die $!;
print $cpp $fixture;
close $cpp;
my $built=compile("$tmp/precision.cpp","$tmp/precision");
ok($built,'compile actual colour, background and uniform-upload methods') or diag(read_file("$tmp/compiler.log"));
SKIP: {
 skip 'fixture did not compile',1 unless $built;
 is(system("$tmp/precision"),0,'all codes, RGB range conversion, surround replay, images and DV inputs');
}
done_testing();
