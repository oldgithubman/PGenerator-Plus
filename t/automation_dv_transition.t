use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
{local @ARGV=('transition-test','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my ($map,$cancel,@calls,@logs);
local *main::_log_action=sub {push @logs,$_[0]};
local *main::_sleep_controlled=sub {push @calls,['settle',$_[0]];!$cancel};
local *main::_api=sub {
 my ($method,$path,$body)=@_;push @calls,[$method,$path];
 if($path eq '/api/config') {$map=$body->{dv_map_mode} if $method eq 'POST';return {status=>'ok',dv_map_mode=>$map};}
 return {status=>'ok'} if $path eq '/api/ping'||$path eq '/api/pattern';
 die "Unexpected $path";
};
sub reset_fixture {$map='1';$cancel=0;@calls=();@logs=();}
reset_fixture();
ok(main::_set_dv_map({signal_format=>'dv'},'2'),'Relative transition succeeds');
is_deeply($calls[-1],['settle',8],'waits for TV after renderer and pattern are ready');
like(join(' ',@logs),qr/Relative.*TV signal acquisition.*map ready/,'transition has meaningful progress');
reset_fixture();$cancel=1;
ok(!main::_set_dv_map({signal_format=>'dv'},'2'),'Stop interrupts transition settle');
unlike(join(' ',@logs),qr/map ready/,'cancelled transition never reports ready');
reset_fixture();$map='2';
ok(main::_set_dv_map({signal_format=>'dv'},'2'),'unchanged map skips restart');
is(scalar @calls,1,'no extra wait on unchanged map');
reset_fixture();
ok(main::_set_dv_map({signal_format=>'sdr'},'2'),'SDR unchanged');
is(scalar @calls,0,'SDR has no DV API calls');
done_testing();
