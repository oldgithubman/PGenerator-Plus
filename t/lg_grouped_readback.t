#!/usr/bin/perl
# Picture-settings readbacks read every requested key in one grouped call
# and fall back to single-key reads only for keys the grouped reply omitted
# or when the grouped call fails. Reading contract-flagged keys one at a
# time up front cost a TV round trip per key (26-60 s per readback on the
# G3, 18 Sep 2026).
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

my $helper="$Bin/../usr/sbin/pgenerator-lg";
my $loaded=do $helper;
ok(defined($loaded),'LG helper loads') or BAIL_OUT($@);

my $store=tempdir(CLEANUP=>1);
local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$store;

my $g3=main::lg_generation_info(
 { modelName=>'OLED55G36LA' },
 { model_name=>'HE_DTV_W23O_AFABATAA', product_name=>'webOSTV 23', software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff' },
 { deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'grouped-g3' },
);
my $resolved=PGLGCapabilities::resolve_lg_capabilities($g3);
my @wire_keys=sort map { $_->{wire_key}||() } values %{$resolved->{data}{settings}{controls}||{}};
my $matrix=main::lg_setting_contracts($g3,keys=>\@wire_keys,signal_mode=>'hdr10',picture_mode=>'hdrCinema',tv_input=>'hdmi1',category=>'picture');
my @individual=sort grep { $_ ne 'pictureMode' && (($matrix->{contracts}{$_}{read}{access}||'') eq 'individual') } keys %{$matrix->{contracts}};
ok(scalar(@individual) >= 2,'the G3 contract flags keys for individual reads') or BAIL_OUT('no individually flagged keys to test');
my @keys=('brightness',@individual[0,1]);

local *main::lg_authenticated_session=sub {{
 status=>'ok',session=>{},client_key=>'test-key',
 system_info=>{modelName=>'OLED55G36LA'},
 software_info=>{model_name=>'HE_DTV_W23O_AFABATAA',product_name=>'webOSTV 23',software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff'},
 hello_info=>{deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'grouped-g3'},
}};
local *main::websocket_close=sub {};
# Keep test traffic out of the appliance's live TV diagnostic log, and let
# the tests assert which diagnostic events a readback records.
my @diag;
local *main::diag_log_append=sub { push(@diag,{label=>$_[0],data=>$_[1]}); };
# A confirmed context (active input and picture mode agree with the request)
# is what lets a read observation count for the next readback's contracts.
local *main::lg_current_input_info=sub {{current_input=>'hdmi1',current_input_checked=>1}};
local *main::lg_current_picture_mode=sub {'hdrCinema'};

my @requests;
my $reply_all=sub {
 my ($session,$label,$path,$payload)=@_;
 push(@requests,{label=>$label,path=>$path,payload=>$payload});
 return {type=>'response',payload=>{settings=>{map { $_=>"value-$_" } @{$payload->{keys}||[]}}}}
  if($path eq 'settings/getSystemSettings');
 return {type=>'response',payload=>{}};
};

{
 @requests=(); @diag=();
 local *main::lg_request=$reply_all;
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','grouped read succeeds');
 ok(!grep({ $_->{label} =~ /^picture_get:grouped-/ } @diag),'a fully grouped readback records no fallback event');
 my @grouped=grep { $_->{label} eq 'get_picture_settings' } @requests;
 is(scalar(@grouped),1,'exactly one grouped picture read');
 my %asked=map { $_=>1 } @{$grouped[0]{payload}{keys}||[]};
 ok($asked{$_},"$_ is asked for in the grouped call") for @keys;
 my @singles=grep { $_->{label} =~ /^get_picture_setting_/ } @requests;
 is(scalar(@singles),0,'no single-key reads when the grouped reply carries every key') or diag(join(',',map { $_->{label} } @singles));
 is($read->{picture_settings}{$_},"value-$_","$_ value comes from the grouped reply") for @keys;
}

{
 @requests=(); @diag=();
 my $omitted=$individual[0];
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  if($label eq 'get_picture_settings') {
   return {type=>'response',payload=>{settings=>{map { $_=>"value-$_" } grep { $_ ne $omitted } @{$payload->{keys}||[]}}}};
  }
  return {type=>'response',payload=>{settings=>{map { $_=>"single-$_" } @{$payload->{keys}||[]}}}}
   if($path eq 'settings/getSystemSettings');
  return {type=>'response',payload=>{}};
 };
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','read with one omitted key succeeds');
 my @singles=grep { $_->{label} =~ /^get_picture_setting_/ } @requests;
 is_deeply([map { $_->{label} } @singles],["get_picture_setting_$omitted"],'only the omitted key is read on its own');
 is($read->{picture_settings}{$omitted},"single-$omitted",'the omitted key takes the single-read value');
 is($read->{picture_settings}{brightness},'value-brightness','keys the grouped reply carried are not re-read');
 my ($event)=grep { $_->{label} eq 'picture_get:grouped-fallback' } @diag;
 ok($event,'an omission records the fallback event') or diag(join(',',map { $_->{label} } @diag));
 is($event->{data}{single_reads},1,'with the single-read count');
 is_deeply($event->{data}{omitted},[$omitted],'and the omitted key');
 is($event->{data}{grouped},scalar(@keys),'and the size of the grouped call');
}

{
 @requests=();
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  return {type=>'error',error=>'grouped read refused'} if($label eq 'get_picture_settings');
  return {type=>'response',payload=>{settings=>{map { $_=>"single-$_" } @{$payload->{keys}||[]}}}}
   if($path eq 'settings/getSystemSettings');
  return {type=>'response',payload=>{}};
 };
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','a refused grouped read still completes through single reads');
 my @singles=sort map { $_->{label} } grep { $_->{label} =~ /^get_picture_setting_/ } @requests;
 is_deeply(\@singles,[sort map { "get_picture_setting_$_" } @keys],'every key is read on its own after a refused grouped call');
 is($read->{picture_settings}{$_},"single-$_","$_ value comes from its single read") for @keys;
}

# pictureMode joins the grouped call like any other key and its grouped
# value is returned.
{
 @requests=();
 local *main::lg_request=$reply_all;
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,['brightness','pictureMode'],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','a read including pictureMode succeeds');
 my @grouped=grep { $_->{label} eq 'get_picture_settings' } @requests;
 is(scalar(@grouped),1,'one grouped call');
 ok(grep({ $_ eq 'pictureMode' } @{$grouped[0]{payload}{keys}||[]}),'pictureMode is asked for in the grouped call');
 ok(!grep({ $_->{label} eq 'get_picture_setting_pictureMode' } @requests),'and not read on its own');
 is($read->{picture_settings}{pictureMode},'value-pictureMode','its value comes from the grouped reply');
}

# A grouped call refused for a key it names is retried once without it. This
# block reads with an unconfirmed context and its own key, so it records no
# observation the exclusion block below could depend on.
{
 @requests=(); @diag=();
 my $refused=$individual[0];
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  if($path eq 'settings/getSystemSettings' && grep { $_ eq $refused } @{$payload->{keys}||[]}) {
   return {type=>'error',error=>"doesn't support the key: $refused"};
  }
  return {type=>'response',payload=>{settings=>{map { $_=>"value-$_" } @{$payload->{keys}||[]}}}}
   if($path eq 'settings/getSystemSettings');
  return {type=>'response',payload=>{}};
 };
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','a refusal naming one key still completes');
 is_deeply([map { $_->{label} } grep { $_->{label} =~ /^get_picture_settings/ } @requests],['get_picture_settings','get_picture_settings_retry'],'the group is retried once');
 my ($retry)=grep { $_->{label} eq 'get_picture_settings_retry' } @requests;
 ok(!grep({ $_ eq $refused } @{$retry->{payload}{keys}||[]}),'the retry leaves out the refused key');
 is_deeply([map { $_->{label} } grep { $_->{label} =~ /^get_picture_setting_/ } @requests],["get_picture_setting_$refused"],'only the refused key is read on its own');
 is($read->{picture_settings}{brightness},'value-brightness','the other keys come from the retried group');
 ok(exists($read->{unsupported_picture_keys}{$refused}) || exists($read->{picture_capabilities}{unsupported}{$refused}),'the refused key is reported unsupported');
 my ($refused_event)=grep { $_->{label} eq 'picture_get:grouped-refused' } @diag;
 is_deeply($refused_event->{data}{refused},[$refused],'the refusal event names the key');
 my ($fallback)=grep { $_->{label} eq 'picture_get:grouped-fallback' } @diag;
 is($fallback->{data}{single_reads},1,'and the fallback event counts one single read');
 is($fallback->{data}{grouped},scalar(@keys),'for the group as first requested');
}

# The retry also covers the other refusal wordings the helper recognises.
{
 @requests=();
 my $refused=$individual[0];
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  if($path eq 'settings/getSystemSettings' && grep { $_ eq $refused } @{$payload->{keys}||[]}) {
   return {type=>'error',error=>"No matched extended item: $refused"};
  }
  return {type=>'response',payload=>{settings=>{map { $_=>"value-$_" } @{$payload->{keys}||[]}}}}
   if($path eq 'settings/getSystemSettings');
  return {type=>'response',payload=>{}};
 };
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','a "no matched" refusal naming one key still completes');
 ok(grep({ $_->{label} eq 'get_picture_settings_retry' } @requests),'and the group is retried without it');
 is_deeply([map { $_->{label} } grep { $_->{label} =~ /^get_picture_setting_/ } @requests],["get_picture_setting_$refused"],'only the named key is read on its own');
}

# A key observed unsupported (in a confirmed context) stays out of the next
# grouped call, so one unsupported key cannot put every readback back on
# single reads.
{
 @requests=();
 my $refused=$individual[1];
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  if($path eq 'settings/getSystemSettings' && grep { $_ eq $refused } @{$payload->{keys}||[]}) {
   return {type=>'error',error=>"doesn't support the key"};
  }
  return {type=>'response',payload=>{settings=>{map { $_=>"value-$_" } @{$payload->{keys}||[]}}}}
   if($path eq 'settings/getSystemSettings');
  return {type=>'response',payload=>{}};
 };
 my $first=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',1,'picture');
 is($first->{status},'ok','an unnamed refusal falls back to single reads and completes');
 my @grouped=grep { $_->{label} eq 'get_picture_settings' } @requests;
 ok(grep({ $_ eq $refused } @{$grouped[0]{payload}{keys}||[]}),'the first grouped call still asked for the key');
 @requests=();
 my $second=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',1,'picture');
 is($second->{status},'ok','the next read succeeds');
 @grouped=grep { $_->{label} eq 'get_picture_settings' } @requests;
 is(scalar(@grouped),1,'one grouped call');
 ok(!grep({ $_ eq $refused } @{$grouped[0]{payload}{keys}||[]}),'the key observed unsupported is left out of the group');
 is_deeply([map { $_->{label} } grep { $_->{label} =~ /^get_picture_setting_/ } @requests],["get_picture_setting_$refused"],'and is the only single read');
 is($second->{picture_settings}{brightness},'value-brightness','the grouped keys are read together');
}

done_testing();
