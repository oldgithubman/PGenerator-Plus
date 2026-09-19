use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Test::More;
my $rc=do "$Bin/../usr/sbin/pgenerator-lg";
ok(defined $rc,'LG helper loads') or BAIL_OUT($@);

is(lg_panel_protection_generation_support({platform_model=>'W23O',platform_year=>2023}),1,'reviewed 2023 platform resolves the panel-protection operation');
is(lg_panel_protection_generation_support({platform_model=>'W20O',platform_year=>2020}),1,'2020 platforms are inside the reviewed range');
is(lg_panel_protection_generation_support({platform_model=>'W26G',platform_year=>2026}),1,'2026 platforms are inside the reviewed range');
is(lg_panel_protection_generation_support({series=>'C1',platform_year=>2021}),-1,'a retail name without its internal platform is not enough to send anything');
is(lg_panel_protection_generation_support({}),-1,'an unknown TV never inherits the operation');

{
 no warnings 'redefine';
 my (@luna,$closed);
 local *main::lg_authenticated_session=sub {{status=>'ok',session=>{},client_key=>'key'}};
 local *main::websocket_close=sub {$closed++};
 local *main::diag_log_append=sub {};
 local *main::lg_luna_request=sub {my ($session,$id,$uri,$params,$timeout)=@_;push @luna,[$uri,$params->{enable}?1:0];return {type=>'response',payload=>{returnValue=>JSON::PP::true()}}};

 local *main::lg_generation_info=sub {{platform_year=>2023,platform_model=>'HE_DTV_W23O_AFABATAA',series=>'G3'}};
 my $off=main::lg_panel_protection_workflow('192.0.2.10','key',3,0);
 is($off->{status},'ok','G3 disable request is dispatched');
 is_deeply([sort map {$_->[0]} @luna],['com.webos.service.oledepl/setGlobalStressReduction','com.webos.service.oledepl/setTemporalPeakControl'],'both panel-protection controls are addressed');
 ok(!grep({$_->[1]} @luna),'disable sends enable:false to each control');
 is($off->{verification_state},'acknowledged_unverified','no readback exists, so the result is never verified');
 ok(!$off->{acknowledged}&&!$off->{readback_available},'bridge dispatch is not reported as an acknowledgement');
 ok($off->{controls}{tpc}{dispatched}&&$off->{controls}{gsr}{dispatched},'per-control dispatch is recorded');
 is($closed,1,'session is closed after the request');

 @luna=();
 my $on=main::lg_panel_protection_workflow('192.0.2.10','key',3,1);
 is($on->{status},'ok','re-enable request is dispatched');
 is(scalar(grep {$_->[1]} @luna),2,'re-enable sends enable:true to both controls');

 @luna=();
 local *main::lg_generation_info=sub {{platform_year=>2019,platform_model=>'HE_DTV_W19O_AFABATAA',series=>'C9'}};
 my $old=main::lg_panel_protection_workflow('192.0.2.10','key',3,0);
 is($old->{status},'error','unreviewed platform is refused');
 is($old->{error_code},'panel-protection-unsupported','refusal names the missing review');
 is(scalar(@luna),0,'nothing is sent to an unreviewed platform');

 @luna=();
 local *main::lg_generation_info=sub {{platform_year=>2023,platform_model=>'HE_DTV_W23O_AFABATAA',series=>'G3'}};
 local *main::lg_luna_request=sub {my ($session,$id,$uri)=@_;push @luna,$uri;return $uri=~/Global/ ? {type=>'error',error=>'404 no such service or method'} : {type=>'response',payload=>{}}};
 my $partial=main::lg_panel_protection_workflow('192.0.2.10','key',3,0);
 is($partial->{status},'error','a rejected control fails the request');
 is($partial->{error_code},'panel-protection-rejected','rejection is distinct from lack of review');
 is_deeply($partial->{failed_controls},['gsr'],'the rejected control is named');
 ok($partial->{controls}{tpc}{dispatched}&&!$partial->{controls}{gsr}{dispatched},'per-control outcome survives a partial failure');
 is(scalar(@luna),2,'the other control is still attempted');
}
done_testing();
