use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('white-read-test','test-token'); do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }

my (@logs,@polls,$payload,$pattern,$now,$sleeps,$cancel,$start_status);
local *main::time=sub {$now};
local *main::_log=sub {push @logs,$_[0]};
local *main::_sleep_controlled=sub {$now+=60;$sleeps++;return !$cancel};
local *main::_api=sub {
 my ($method,$path,$body)=@_;
 if($path eq '/api/pattern'){$pattern=$body;return {status=>'ok'}}
 if($path eq '/api/meter/read'){$payload=$body;return {status=>$start_status}}
 die "Unexpected endpoint $path" if $path ne '/api/meter/read/result';
 my $result=shift(@polls)||{status=>'measuring'};
 return ref($result) eq 'CODE' ? $result->() : $result;
};
sub reset_case {
 @logs=();@polls=();$payload=undef;$pattern=undef;$now=2000000000;$sleeps=0;$cancel=0;$start_status='measuring';$::LAST_ERROR='previous unrelated error';
}
sub complete {
 my (%extra)=@_;
 return {status=>'ok',request_id=>$payload->{request_id},readings=>[{request_id=>$payload->{request_id},timestamp=>$now,luminance=>418.3,r_code=>$payload->{patch_r},g_code=>$payload->{patch_g},b_code=>$payload->{patch_b},%extra}]};
}
for my $bits (8,10,12) {
 for my $range ('0','1') {
  reset_case();@polls=(sub {complete()});
  my $reading=main::_read_white({signal_format=>'sdr',max_bpc=>$bits,signal_range=>$range,patch_size=>10});
  my $code=$range eq '1'?235*(2**($bits-8)):2**$bits-1;
  is_deeply([@{$payload}{qw(patch_r patch_g patch_b)}],[$code,$code,$code],"$bits-bit range $range uses meter's RGB field names");
  is($payload->{input_max},2**$bits-1,'code domain preserved');
  is($payload->{ire},100,'white explicitly labelled 100%');
  is($pattern->{r},$code,'preview and meter patch agree');
  like($payload->{request_id}//'',qr/^[A-Za-z0-9_.:-]{1,96}$/,'request has a valid correlation identity');
  like($payload->{request_id}//'',qr/-2000000000000-\d+$/,'millisecond identity does not overflow on 32-bit Perl');
  is(main::_luminance($reading),418.3,'returns the actual reading, not the response envelope');
 }
}
reset_case();
@polls=(sub {my $r=complete();$r->{request_id}='old-read';$r},sub {complete(request_id=>'old-inner-read')},sub {complete(timestamp=>1999999900)},sub {complete()});
is(main::_luminance(main::_read_white({})),418.3,'ignores stale envelope, inner identity and timestamp before accepting current reading');
is($sleeps,3,'stale results do not trigger another meter request');
for my $case (
 ['empty success',sub {{status=>'ok',request_id=>$payload->{request_id},readings=>[]}},qr/no reading/],
 ['malformed reading',sub {{status=>'ok',request_id=>$payload->{request_id},readings=>['invalid']}},qr/no reading/],
 ['missing luminance',sub {complete(luminance=>undef)},qr/no luminance/],
 ['zero white',sub {complete(luminance=>0)},qr/positive/],
 ['invalid luminance',sub {complete(luminance=>'NaN')},qr/no luminance/],
 ['wrong patch',sub {complete(r_code=>128)},qr/patch/],
 ['meter error',sub {{status=>'error',message=>'Instrument disconnected'}},qr/Instrument disconnected/],
 ['cancelled read',sub {{status=>'cancelled',message=>'Read cancelled'}},qr/cancelled/],
) {
 reset_case();@polls=($case->[1]);
 ok(!defined(main::_read_white({})),"$case->[0] is not a setup reference");
 like($::LAST_ERROR,$case->[2],"$case->[0] saves an actionable failure cause");
}
reset_case();@polls=(sub {my $r=complete();delete $r->{request_id};$r});
ok(!defined(main::_read_white({})),'uncorrelated measurement cannot become setup reference');
like($::LAST_ERROR,qr/timed out/,'missing current result has a bounded timeout');
reset_case();$cancel=1;
ok(!defined(main::_read_white({})),'stop is honored while waiting');
is($sleeps,1,'stop does not continue polling');
reset_case();$start_status='idle';
ok(!defined(main::_read_white({})),'rejected start cannot consume an old result');
like($::LAST_ERROR,qr/not accepted/,'rejected start cause is retained');
done_testing();
