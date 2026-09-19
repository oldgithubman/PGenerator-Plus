use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
{local @ARGV=('eta-worker-test','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
# Every tick must reach the manifest here; in production only one a minute
# does (the rest go to the live status), which is what this test measures.
$main::WORKER_MANIFEST_INTERVAL=0;
my ($now,@statuses,@clocks);
local *main::time=sub {$now};
local *main::_refresh_control=sub {};
local *main::_sleep_controlled=sub {1};
local *main::_log=sub {};
local *main::_log_worker_events=sub {};
local *main::_worker_progress=sub {''};
local *main::_active_item_number=sub {0};
local *main::_update_run=sub {my $r={};$_[0]->($r);push @clocks,PGAutomation::clone($r->{worker_timing});return $r};
local *main::_api=sub {
 return {status=>'ok'} if $_[1] eq '/api/lg/status';
 die 'unexpected API call' unless $_[1] eq '/test/status' && @statuses;
 my $s=shift @statuses;$now=$s->{at};return $s;
};
$now=1000;
@statuses=(map {{status=>'running',current_step=>$_,total_steps=>8,at=>1000+($_-1)*60}} 1..7);
push @statuses,{status=>'running',current_step=>2,total_steps=>8,at=>1500},
 {status=>'running',current_step=>3,total_steps=>8,at=>1680},
 {status=>'complete',current_step=>8,total_steps=>8,at=>1800};
is(main::_wait_worker('/test/status','greyscale AutoCal',{})->{status},'complete','worker loop completes without device I/O');
is_deeply($clocks[0]{recent_point_seconds},[],'first point does not invent a duration');
is_deeply($clocks[6]{recent_point_seconds},[(60)x5],'only the latest five completed point timings retained');
is_deeply($clocks[7]{recent_point_seconds},[],'counter reset clears old-pass timings');
is($clocks[7]{start_step},1,'reset starts a new measured pass');
is_deeply($clocks[8]{recent_point_seconds},[180],'new pass uses its own observed pace');
done_testing();
