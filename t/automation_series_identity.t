use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
my $id='series-handoff';
{local @ARGV=($id,'test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
PGAutomation::ensure_store();
my $run_path=PGAutomation::run_dir($id).'/run.json';
PGAutomation::write_json_atomic($run_path,{id=>$id,token=>'test-token',status=>'running',items=>[{},{}]});
PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/control.json',{request=>'none'});
local *main::_log=sub {};
local *main::_sleep_controlled=sub {1};
my ($job,$status,$foreign,$lost_reply)=(0,{},0,0);
my (@requests,@identities);
local *main::_active_item_number=sub {$job};
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 return {status=>'ok',disconnected=>0} if $path eq '/api/lg/status';
 if ($method eq 'POST') {
  push @requests,[$path,PGAutomation::clone($payload)];
  push @identities,PGAutomation::worker_id($payload);
  # Use the same state seeding function as the daemon's real series route.
  $status=PGAutomation::decode_json(PGAutomation::seed_worker_state_json(
   PGAutomation::encode_json({status=>'complete',type=>$payload->{type}||'greyscale',points=>$payload->{points}||21,
    steps=>[{name=>'white'}],readings=>[{Y=>100}],white_reading=>{Y=>100}}),PGAutomation::encode_json($payload)));
  return {status=>'error',_transport_error=>1,message=>'Lost launch reply'} if $lost_reply;
  return {status=>'started'};
 }
 return {%$status,automation_worker_id=>'foreign-attempt'} if $foreign;
 return $status;
};
my $item={signal_format=>'sdr',picture_mode=>'filmMaker',
 pre_series=>[qw(greyscale-21 colors-30 saturations-24)],post_series=>[qw(greyscale-21 colors-30 saturations-24)]};
is(main::_start_worker('/api/meter/lg-autocal/start','/grey/status',{})->{status},'started','AutoCal establishes an earlier attempt');
ok(main::_run_series(0,$item,'post'),'all three post-reading series succeed after AutoCal') or diag $main::LAST_ERROR;
$job=1;
ok(main::_run_series(1,$item,'pre'),'next job pre-readings do not inherit the previous worker identity') or diag $main::LAST_ERROR;
is(scalar(@identities),7,'every AutoCal or series start is observed');
my %ids; $ids{$_}++ for @identities;
is(scalar(keys %ids),7,'every measurement sweep gets a unique attempt');
ok(!exists($ids{''}),'series starts never lack an identity');
for my $phase ([0,'post'],[1,'pre']) {
 for my $key (@{$item->{post_series}}) {
  my $snapshot=PGAutomation::read_json_file(PGAutomation::item_dir($id,$phase->[0])."/$phase->[1]/$key.json");
  is($snapshot->{status},'complete',"$phase->[1] $key retains measurements");
  like($snapshot->{automation_worker_id}||'',qr/^series-handoff-$phase->[0]-/,"$phase->[1] $key keeps attempt provenance");
 }
}
# A missing launch reply may adopt only this attempt's terminal result, without
# starting an already completed sweep again. Do not fix hand-offs by disabling fencing.
@requests=();$lost_reply=1;
ok(main::_run_series(1,{%$item,post_series=>['greyscale-21']},'post'),'lost series acknowledgement reconciles the matching completed attempt');
is(scalar @requests,1,'completed series is not launched twice');
$lost_reply=0;$foreign=1;
my $file=PGAutomation::item_dir($id,1).'/post/greyscale-21.json';
my $before=PGAutomation::read_raw($file);
ok(!main::_run_series(1,{%$item,post_series=>['greyscale-21']},'post'),'foreign result is still rejected');
is($main::LAST_ERROR_CODE,'worker-identity-mismatch','the exact ownership failure remains actionable');
is(PGAutomation::read_raw($file),$before,'foreign result cannot overwrite previously saved measurements');
done_testing();
