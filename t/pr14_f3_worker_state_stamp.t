# Agent BC: each calibration worker's REAL write_state must carry the attempt
# id from its config (guards F3-q/r/s mutations, which the suite does not).
# Ported from the PR 14 independent verification (docs/pr14-test evidence,
# agent BC) so the suite guards what the mutation run found unguarded (P22).
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
my $WT="$Bin/..";
my $dir=tempdir(CLEANUP=>1);
my $id='run-7-20260917-010203-abcdef';
my $perl=$^X;
sub run_perl {my ($code)=@_;my $f="$dir/p$$".int(rand(1e9)).".pl";open my $h,'>',$f or die;print {$h} $code;close $h;my $out=`"$perl" "$f" 2>&1`;return ($?>>8,$out);}
for my $w (['grey','meter_lg_autocal.pl','$main::LG_AUTOCAL_CONFIG={automation_worker_id=>"'.$id.'"};main::write_state({status=>"running",message=>"x"});'],
           ['3d','meter_lg_3d_autocal.pl','$main::LG_3D_REQUEST_CONTEXT={automation_worker_id=>"'.$id.'"};main::write_state({status=>"running",message=>"x"});']) {
  my $state="$dir/$w->[0].json";
  my ($rc,$out)=run_perl(qq{\@ARGV=("$dir/none-config.json","$state","$dir/stop");
    local \$SIG{__WARN__}=sub{};
    do "$WT/usr/bin/$w->[1]"; die \$@ if \$@;
    $w->[2]
    print "OK\\n";});
  like($out,qr/OK/,"$w->[0]: worker loaded and wrote state") or diag $out;
  my $s=eval {open my $f,'<',$state or die;JSON::PP::decode_json(do{local $/;<$f>})}||{};
  is($s->{automation_worker_id},$id,"$w->[0]: real write_state stamps automation_worker_id");
  is($s->{worker_pid}>1?1:0,1,"$w->[0]: worker_pid stamped");
}
# DV profile worker has no caller() guard: extract its real write_state sub.
{
  open my $f,'<',"$WT/usr/bin/meter_lg_dv_profile.pl" or die;my $src=do{local $/;<$f>};close $f;
  my ($sub)=$src=~/^(sub write_state \{.*?^\})/ms or die 'write_state not found';
  my $state="$dir/dv.json";
  my ($rc,$out)=run_perl(qq{use lib "$WT/usr/share/PGenerator"; use PGAutomation (); use PGCalibrationLog (); use JSON::PP ();
    our \$config={automation_worker_id=>"$id",full_autocal_run_id=>"fa-9"}; our \$state_file="$state"; our \$json=JSON::PP->new;
    $sub
    write_state(status=>"running",message=>"x",steps=>[]) or die "write failed";print "OK\\n";});
  like($out,qr/OK/,'dv: extracted write_state ran') or diag $out;
  my $s=eval {open my $g,'<',$state or die;JSON::PP::decode_json(do{local $/;<$g>})}||{};
  is($s->{automation_worker_id},$id,'dv: real write_state stamps automation_worker_id');
  is($s->{full_autocal_run_id},'fa-9','dv: full_autocal_run_id retained');
}
done_testing();
