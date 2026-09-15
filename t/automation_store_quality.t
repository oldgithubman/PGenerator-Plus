use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use File::Temp qw(tempdir);
use Test::More;
use PGAutomation ();

local $ENV{PGEN_AUTOMATION_DIR} = tempdir(CLEANUP => 1);
ok(PGAutomation::ensure_store(), 'isolated store created');
my $id = PGAutomation::new_id();
my $path = PGAutomation::run_dir($id) . '/run.json';
ok(PGAutomation::write_json_atomic($path, {name => 'Écran – 夜', items => []}), 'Unicode manifest written');
is(PGAutomation::read_json_file($path)->{name}, 'Écran – 夜', 'Unicode survives a disk round trip');
is(PGAutomation::clone({name => 'Écran – 夜'})->{name}, 'Écran – 夜', 'Unicode survives snapshots');
ok(PGAutomation::remove_run($id), 'named run can be deleted without File::Path exception');
ok(!-d PGAutomation::run_dir($id), 'named run removed');
is(PGAutomation::safe_component('../other'), '', 'parent traversal refused');

my $x = .3127; my $y = .329;
my $reading = {X => 100*$x/$y, Y => 100, Z => 100*(1-$x-$y)/$y,
    target_x => $x, target_y => $y, target_Yn => 1, series_target_white_y => 100};
foreach my $formula (qw(deitp de2000)) {
    my ($avg,$max,$count,$missing) = PGAutomation::quality_summary({readings=>[$reading]},$formula);
    cmp_ok(abs($avg), '<', 1e-8, "$formula gives zero for matching measured XYZ and target");
    is($count, 1, "$formula scores physical XYZ without a precomputed dE field");
    is($missing, 0, "$formula has complete evidence");
    my %black = (%$reading, X=>0, Y=>0, Z=>0);
    ($avg,$max,$count,$missing) = PGAutomation::quality_summary({readings=>[\%black]},$formula);
    cmp_ok($avg, '>', 20, "$formula does not silently discard a black reading for a white target");
    ($avg,$max,$count,$missing) = PGAutomation::quality_summary({readings=>[{deltaE=>0}]},$formula);
    ok(!defined($avg) && !$count && $missing==1, "$formula cannot pass missing measurement evidence");
}
my ($avg,$max,$count,$missing) = PGAutomation::quality_summary({readings=>[$reading]},'unknown');
ok(!defined($avg) && !$count && $missing==1, 'unknown formula remains unverified');
done_testing();
