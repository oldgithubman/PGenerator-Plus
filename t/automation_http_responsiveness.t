use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw(time sleep);
use POSIX ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
local $ENV{MALLOC_ARENA_MAX}=1;
PGAutomation::ensure_store();
# Only the equipment-read boundary is faked. The accept loop, request queues,
# parser, startup progress writes, execution locks and failed-start handler
# below are production code. Never launch workers or contact a real device.
local *main::log=sub {};
local *main::webui_automation_readiness_data=sub {
 return {status=>'error',ready=>0,error_code=>'fixture-readiness-failed',
  message=>'Fixture TV cannot verify this request',items=>[],checks=>[{ok=>0,level=>'error',name=>'fixture-readiness',message=>'Equipment not ready'}]};
};
local *main::webui_automation_launch_runner=sub {die 'Failed readiness must not launch a calibration'};
my $listener=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>128,ReuseAddr=>1,Proto=>'tcp')
 or plan skip_all=>"Loopback listener unavailable: $!";
my $port=$listener->sockport();
my $child=fork();die $! unless defined $child;
if(!$child) {
 open STDERR,'>',PGAutomation::base_dir().'/http-test.log';
 main::webui_http($listener);
 POSIX::_exit(0);
}
close $listener;
END { if($child){kill 'TERM',$child;waitpid($child,0);} }
sub request {
 my ($method,$path,$body)=@_;$body='' unless defined $body;
 my $socket=IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$port,Proto=>'tcp',Timeout=>1) or return '';
 $socket->autoflush(1);
 print $socket "$method $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: ".length($body)."\r\n\r\n$body";
 my $select=IO::Select->new($socket);my $until=time()+3;my $raw='';
 while(time()<$until) {
  next unless $select->can_read(0.05);
  my $n=sysread($socket,my $part,65536);last unless $n;$raw.=$part;
 }
 close $socket;return $raw;
}
my $ready='';my $deadline=time()+8;
while(time()<$deadline){$ready=request('GET','/api/ping');last if $ready=~/"ok":1/;sleep .05;}
like($ready,qr/"ok":1/,'real threaded HTTP listener becomes ready');
my @idle=map {IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$port,Proto=>'tcp',Timeout=>1)} 1..20;
my $started=time();
for my $round (1..5) {
 my $reply=request('POST','/api/automation/runs/start','{"items":[{"signal_format":"hdr10","picture_mode":"hdrFilmMaker"}]}');
 like($reply,qr/fixture-readiness-failed/,"failed start $round returns a bounded explicit readiness error");
 like(request('GET','/api/ping'),qr/"ok":1/,"ping remains responsive after failed start $round with silent browser connections");
}
cmp_ok(time()-$started,'<',15,'repeated failed starts cannot pin the accept loop');
ok(!-e PGAutomation::base_dir().'/execution.json','failed readiness never claims device ownership');
close $_ for grep {defined} @idle;
kill 'TERM',$child;waitpid($child,0);$child=0;
done_testing();
