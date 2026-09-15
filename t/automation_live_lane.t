use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use POSIX ();
require "$Bin/../usr/share/PGenerator/webui.pm";
for my $path ('/api/automation/runs/current','/api/automation/runs/run-1/jobs/0') {
 ok(main::webui_route_is_concurrent_safe('GET',$path),"$path bypasses bulk history");
 ok(!main::webui_route_is_concurrent_safe('POST',$path),"POST $path never bypasses control serialization");
}
for my $path ('/api/automation/runs','/api/automation/runs/run-1','/api/automation/runs/run-1/artifact/runner.log','/api/automation/start','/api/automation/readiness','/api/automation/runs/run-1/control/stop','/api/automation/runs/../jobs/0/extra') {
 ok(!main::webui_route_is_concurrent_safe('GET',$path),"$path stays off the fast lane");
}
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
my $run_path=PGAutomation::run_dir('concurrent-reap').'/run.json';
my $execution_path=PGAutomation::base_dir().'/execution.json';
PGAutomation::write_json_atomic($run_path,{id=>'concurrent-reap',status=>'running',runner_pid=>2147483647,active_item=>0,active_stage=>'greyscale-done',items=>[{status=>'running',checkpoints=>[]}]});
PGAutomation::write_json_atomic($execution_path,{owner=>'automation',run_id=>'concurrent-reap',status=>'running',pid=>2147483647});
pipe(my $ready,my $go) or die $!;
my @children;
for(1..2){
 my $pid=fork();die $! if !defined $pid;
 if(!$pid){
  close $go;my $byte;sysread($ready,$byte,1);
  my $ok=eval{main::webui_automation_reap_dead_runner();1};
  POSIX::_exit($ok?0:1);
 }
 push @children,$pid;
}
close $ready;syswrite($go,'xx');close $go;
for my $pid (@children){waitpid($pid,0);is($?,0,'concurrent status recovery completed');}
my $run=PGAutomation::read_json_file($run_path);
is($run->{status},'interrupted','dead runner recovered');
is(scalar @{$run->{items}[0]{checkpoints}},1,'concurrent polls do not duplicate interruption checkpoints');
is(PGAutomation::read_json_file($execution_path)->{status},'interrupted','execution ownership remains recoverable');
done_testing();
