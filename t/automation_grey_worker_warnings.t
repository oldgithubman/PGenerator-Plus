#!/usr/bin/perl
# A greyscale run that carried a near-black patch forward never measured it, so
# that patch's outcome is unknown. The worker reports this as an automation
# processing warning. Before this, the greyscale stage dropped worker warnings
# (only the 3D stage lifted them), so the item finished "complete" and looked
# exactly like a fully converged calibration in the run view and History.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
{ local @ARGV=('grey-warnings-test','test-token'); do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }

# Drive the real stage with its I/O stubbed: the worker "completes" and hands
# back the summary the runner would have polled.
sub run_stage {
 my ($summary,$item)=@_;
 $item||={};
 local *main::_set_dv_map=sub { 1 };
 local *main::_grey_payload=sub { {} };
 local *main::_start_worker=sub { {status=>'started'} };
 local *main::_wait_worker=sub { $summary };
 local *main::_copy_worker_files=sub { 1 };
 local *main::_clear_active_worker=sub { 1 };
 local *main::_log=sub {};
 my $result=main::_calibration_greyscale_stage(0,$item);
 return ($result,$item);
}

my $note='Greyscale: 1 near-black patch not measured (sdr26_2.3%): left uncorrected, outcome unknown';
{
 my ($result,$item)=run_stage({status=>'complete',final_1d_lut_upload_verified=>1,automation_processing_warnings=>[$note]});
 ok(ref($result) eq 'HASH','the stage still succeeds: a carried-forward patch is not a failure');
 is_deeply($item->{warnings},[$note],'the worker warning is lifted onto the item, so it finishes complete-with-warnings');
}
{
 my ($result,$item)=run_stage({status=>'complete',final_1d_lut_upload_verified=>1,automation_processing_warnings=>[$note]},{warnings=>[$note]});
 is_deeply($item->{warnings},[$note],'a warning already on the item (a resumed stage) is not duplicated');
}
{
 my ($result,$item)=run_stage({status=>'complete',final_1d_lut_upload_verified=>1});
 ok(!$item->{warnings} || !@{$item->{warnings}},'a clean greyscale run adds no warning');
}
{
 # The lift sits after the completion check: a failed worker is a failure,
 # reported through LAST_ERROR, not a success with a warning attached.
 my ($result,$item)=run_stage({status=>'error',message=>'boom',automation_processing_warnings=>[$note]});
 ok(!$result,'a failed greyscale worker still fails the stage');
 ok(!$item->{warnings} || !@{$item->{warnings}},'and its warnings are not attached to a failed stage');
}

done_testing();
