use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
do "$Bin/../usr/bin/meter_lg_autocal.pl"; die $@ if $@;
local *main::write_state=sub {};
local *main::log_line=sub {};
local *main::reset_meter_session_success=sub {};
local *main::autocal_low_light_mode_for_step=sub {'off'};
local *main::autocal_requested_sample_count=sub {1};
my $step={name=>'5%',ire=>5,signal_r_pct=>5,signal_g_pct=>5,signal_b_pct=>5};
my $zero={Y=>0,luminance=>0,x=>0.333333,y=>0.333333,null_read=>1,null_read_retries=>2};
my $good={X=>1,Y=>1.88,Z=>2,luminance=>1.88,x=>0.3127,y=>0.329};
for my $signal (qw(sdr hdr10 dv)) {
 my $calls=0;my $state={};
 local *main::read_step_once=sub {$calls++;return ({%$zero},undef)};
 my ($reading,$error)=main::read_step({signal_mode=>$signal},$step,$state);
 ok(!defined($reading),"$signal does not feed exhausted invalid samples to the solver");
 like($error,qr/No usable meter measurement for 5% after 4 sample attempts.*signal range/,"$signal failure names the patch, budget and checks");
 is($calls,4,"$signal does not fall through to extra read/solver iterations");
 is($state->{measurement_retry}{limit},4,'retry budget remains inspectable');
}
{
 my $calls=0;my @messages;my $state={};
 local *main::write_state=sub {push @messages,$_[0]{message}};
 local *main::read_step_once=sub {$calls++;return ($calls==1?{%$zero}:{%$good},undef)};
 my ($reading,$error)=main::read_step({signal_mode=>'dv'},$step,$state);
 is($error,undef,'transient invalid reading can recover');
 is($reading->{Y},1.88,'valid samples keep the normal median result');
 is($calls,3,'only needed valid samples are collected');
 ok(!exists $state->{measurement_retry},'successful reading clears retry notice');
 ok(grep(/Retrying invalid measurement.*2\/4/,@messages),'retry remains visible during physical read');
}
{
 my $calls=0;my $state={};
 local *main::read_step_once=sub {$calls++;return ($calls==1?{%$good}:{%$zero},undef)};
 my ($reading,$error)=main::read_step({signal_mode=>'dv'},$step,$state);
 is($reading->{Y},1.88,'one valid sample retains existing fallback behavior');
 ok(!exists $state->{measurement_retry},'partial valid set does not leave a stale retry badge');
}
for my $config ({disable_low_shadow_median=>1},{low_light=>{mode=>'aaa'}}) {
 local *main::autocal_requested_sample_count=sub {$config->{disable_low_shadow_median}?1:3};
 local *main::read_step_once=sub {return ({%$zero},undef)};
 my ($reading,$error)=main::read_step($config,$step,{});
 ok(!defined($reading),'disabled median / application averaging cannot accept an unusable zero');
 like($error,qr/unusable reading for 5%/,'direct failure is actionable');
 my $black={name=>'0%',ire=>0,signal_r_pct=>0,signal_g_pct=>0,signal_b_pct=>0};
 ($reading,$error)=main::read_step($config,$black,{});
 is($error,undef,'true OLED black remains valid');
 is($reading->{Y},0,'true black is not replaced');
}
{
 local *main::read_step_once=sub {return ({%$good,Y=>0.002,luminance=>0.002},undef)};
 my ($reading,$error)=main::read_step({signal_mode=>'dv'},$step,{});
 is($error,undef,'valid sub-floor shadow measurements remain usable by the existing probe-up algorithm');
 is($reading->{Y},0.002,'small but valid luminance is not confused with an unusable null read');
}
{
 local *main::read_step_once=sub {return (undef,'Pattern rejected')};
 my ($reading,$error)=main::read_step({},$step,{});
 like($error,qr/after 1 sample attempts.*Pattern rejected/,'early terminal failure reports actual attempts and preserves its cause');
}
{
 local *main::read_step_once=sub {return (undef,'cancelled')};
 my ($reading,$error)=main::read_step({},$step,{});
 is($error,'cancelled','stop still exits immediately through existing cancellation handling');
}
done_testing();
