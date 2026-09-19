use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use PGCalibrationLog ();
use PGAutomation ();

my $base={run=>'run-test',job=>2,stage=>'greyscale-done',worker=>'attempt-1'};
{
 local $PGCalibrationLog::CONTEXT={%$base,token=>'never-copy',path=>'/etc/passwd'};
 my $round=PGCalibrationLog::from_header(PGCalibrationLog::header_value());
 is_deeply($round,$base,'header carries only correlation, never credentials or paths');
 is_deeply(PGCalibrationLog::from_header('a'x2049),{},'oversized header ignored');
 is_deeply(PGCalibrationLog::context({run=>'../escape',job=>-1}),{},'unsafe run and job rejected');
 my $child=PGCalibrationLog::child_context({%$base,op=>'parent'});
 is($child->{parent},'parent','nested operations name their parent');
 isnt($child->{op},'parent','nested operation has its own identity');
 like(PGCalibrationLog::timestamp(0),qr/^1970-01-01T00:00:00\.000Z$/,'UTC includes date and subsecond precision');
}

# Instrumentation preserves results and exceptions, and idle polls stay quiet.
my @events;
{
 local $PGCalibrationLog::SINK=sub {push @events,$_[0];1};
 my $response={status=>'ok',value=>17};
 my $seen;
 my $returned=PGCalibrationLog::api_call('Worker',$base,'POST','/api/lg/1d-dpg/upload',{},60,sub {
  $seen=PGCalibrationLog::from_header(PGCalibrationLog::header_value());
  return $response;
 });
 is($returned,$response,'API response reference is unchanged');
 is_deeply([map {$_->{event}} @events],[qw(request-start request-end)],'one request pair, not payload dumps');
 is($events[0]{op},$seen->{op},'wire header names the logged operation');
 is($events[1]{op},$events[0]{op},'begin and end correlate');
 ok($events[1]{elapsed_ms}>=0,'duration is explicit milliseconds');
 is_deeply($PGCalibrationLog::CONTEXT,{},'scope does not leak to another request');
 @events=();
 PGCalibrationLog::api_call('Worker',$base,'GET','/api/meter/read/result',undef,10,sub {{status=>'running'}});
 is(scalar(@events),0,'unchanged successful polls add no diagnostic noise');
 PGCalibrationLog::api_call('Worker',$base,'GET','/api/meter/read/result',undef,10,sub {{status=>'error',message=>'USB lost'}});
 is(scalar(@events),1,'failed polls retain evidence');
 is($events[0]{message},'USB lost','failure reason retained');
 @events=();
 my $clock=100;
 local *PGCalibrationLog::monotonic=sub {my $t=$clock;$clock+=6;return $t};
 PGCalibrationLog::api_call('Worker',$base,'GET','/api/lg/status',undef,10,sub {{status=>'ok'}});
 is($events[0]{elapsed_ms},6000,'slow successful polls are visible');
 @events=();
 eval {PGCalibrationLog::api_call('Worker',$base,'POST','/api/lg/3d-lut/upload',{},30,sub {die "cancelled\n"})};
 is($@,"cancelled\n",'exception is rethrown unchanged');
 is($events[-1]{delivery_state},'outcome-unknown','failed transport never claims a mutation was rejected');
 for my $cancelled ({status=>'error',message=>'cancelled'},
                    {status=>'error',error_code=>'stopped',message=>'Automation stopped'},
                    {status=>'cancelled'}) {
  PGCalibrationLog::api_call('Worker',$base,'POST','/api/lg/3d-lut/upload',{},30,sub {$cancelled});
  is($events[-1]{delivery_state},'outcome-unknown','cancelled write may already have reached the TV');
 }
 PGCalibrationLog::api_call('Worker',$base,'POST','/write',{},30,
  sub {{status=>'error',message=>'cancelled',delivery_state=>'not-sent'}});
 is($events[-1]{delivery_state},'not-sent','explicit known delivery outcome takes precedence');
 @events=();
 my @reading=PGCalibrationLog::measurement('Worker',$base,{name=>'5%',ire=>5},3,sub {
  return ({Y=>0.015,request_id=>'read-1',timing_ms=>{settle_ms=>1800}},undef);
 });
 is($reading[0]{Y},0.015,'measurement wrapper preserves list return');
 is($events[-1]{request_id},'read-1','meter ID bridges worker and meter evidence');
 is($events[-1]{timing_ms}{settle_ms},1800,'phase timings reach the job diagnostic trail');
 is($events[-1]{patch},'5%','measurement identifies patch');
 is($events[-1]{attempt},3,'measurement identifies attempt');
}

{
 local $PGCalibrationLog::SINK=sub {die "disk failed\n"};
 local $PGCalibrationLog::WARN_SINK=sub {die "warning sink failed\n"};
 my $response={status=>'ok'};
 is(PGCalibrationLog::api_call('Worker',$base,'POST','/write',{},10,sub {$response}),$response,
    'diagnostic failure cannot replace a successful API result');
 eval {PGCalibrationLog::api_call('Worker',$base,'POST','/write',{},10,sub {die "original failure\n"})};
 is($@,"original failure\n",'diagnostic failure cannot replace the original exception');
}

my $dir=tempdir(CLEANUP=>1);
local $ENV{PGEN_AUTOMATION_DIR}=$dir;
make_path("$dir/runs/run-test/items/1");
my $file="$dir/runs/run-test/items/1/diagnostics.ndjson";
sub records {
 open my $fh,'<',$file or return [];
 return [map {JSON::PP::decode_json($_)} <$fh>];
}
ok(PGCalibrationLog::event('TV','write',{settings=>{contrast=>85,client_key=>'secret'},payload=>[(1)x3072]},$base),'job trace written directly to its archive');
my $record=records()->[0];
is($record->{settings}{client_key},'[redacted]','nested credentials redacted');
is($record->{payload}{count},3072,'large LUT described by count');
is(scalar @{$record->{payload}{sample}},6,'large LUT sample bounded');
is($record->{settings}{contrast},85,'useful values preserved');
is((stat($file))[2]&0777,0600,'diagnostic artifact is private on disk');
ok(!PGCalibrationLog::event('TV','write',{}, {run=>'missing',job=>1}),'logging cannot create an arbitrary run');
make_path("$dir/elsewhere");
symlink("$dir/elsewhere","$dir/runs/linked");
ok(!PGCalibrationLog::event('TV','write',{}, {run=>'linked'}),'symlinked run rejected');
{
 local $PGCalibrationLog::MAX_BYTES=(-s $file)+10;
 ok(PGCalibrationLog::event('TV','end',{message=>'x'x80},$base),'retention exhaustion is non-fatal');
 is(records()->[-1]{event},'retention-limit','retention loss is explicit');
 my $size=-s $file;
 PGCalibrationLog::event('TV','end',{},$base) for 1..3;
 is(-s $file,$size,'retention notice is emitted only once');
}
done_testing();
