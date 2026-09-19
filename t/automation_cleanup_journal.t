use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";

# A fresh runner namespace resets its process-local one-shot cleanup latch.
# TV and meter calls are simulated; run/control/ownership files are real.
for my $fault (qw(none result-write crash initial-write)) {
    subtest "cleanup journal: $fault" => sub {
        local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
        PGAutomation::ensure_store();
        my $id='journal-'.$fault;
        my $token='journal-token';
        my $path=PGAutomation::run_dir($id).'/run.json';
        my $execution=PGAutomation::base_dir().'/execution.json';
        PGAutomation::write_json_atomic($path,{
            id=>$id,token=>$token,status=>'running',runner_pid=>0,items=>[],
            # Previous success must not mask an incomplete new cleanup attempt.
            stop_cleanup=>{verified=>JSON::PP::true,completed_at=>1,message=>'Old successful cleanup'},
        });
        PGAutomation::write_json_atomic($execution,{
            owner=>'automation',run_id=>$id,token=>$token,status=>'running',pid=>0,
        });
        {
            local @ARGV=($id,$token);
            # Reload only this test's runner to reset lexical state. Suppress
            # the expected redefinition notices, not other compiler warnings.
            local $SIG{__WARN__}=sub {
                warn $_[0] unless $_[0]=~/^Subroutine \w+ redefined at \Q$Bin\/..\/usr\/bin\/pgen_automation_runner.pl\E line /;
            };
            do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;
        }
        my $real_update=\&main::_update_run;
        my ($writes,$device_calls)=(0,0);
        local *main::_log=sub {};
        local *main::webui_automation_reconnect_for_resume=sub {
            return {status=>'error',error_code=>'unsafe-resume',message=>'Cleanup guard was bypassed'};
        };
        local *main::_worker_process_alive=sub {0};
        local *main::_ensure_lg_connection=sub {1};
        local *main::_update_run=sub {
            $writes++;
            my $preview=PGAutomation::read_json_file($path);
            my $was_verified=$preview->{stop_cleanup}{verified};
            $_[0]->($preview);
            return undef if ($fault eq 'initial-write' && $writes==1)
                || ($fault eq 'result-write' && !$was_verified && $preview->{stop_cleanup}{verified});
            return $real_update->(@_);
        };
        local *main::_api=sub {
            my ($method,$route)=@_;
            if (++$device_calls==1) {
                my $saved=PGAutomation::read_json_file($path);
                ok(main::webui_automation_cleanup_required($saved),
                    'unconfirmed cleanup is durable before the first device operation');
                ok(!$saved->{stop_cleanup}{verified},'old success is replaced by pending verification');
                die "Injected crash during cleanup\n" if $fault eq 'crash';
            }
            return {status=>'ok',connected=>JSON::PP::true,disconnected=>JSON::PP::false,
                calibration_mode=>JSON::PP::false};
        };
        my $ok=eval {main::_stop_active();1};
        my $error=$@;
        if ($fault eq 'none') {
            ok($ok,'normal cleanup completes') or diag $error;
            ok(PGAutomation::read_json_file($path)->{stop_cleanup}{verified},'fresh success is durable');
            ok(main::_finish('stopped'),'only verified cleanup finishes');
            ok(!-f $execution,'verified completion releases ownership');
        } elsif ($fault eq 'initial-write') {
            ok(!$ok,'cleanup refuses to proceed without a durable pending record');
            like($error,qr/persist.*cleanup/i,'journal failure is actionable');
            is($device_calls,0,'no device work begins when the journal cannot be saved');
            ok(-f $execution,'ownership is not released on initial storage failure');
        } else {
            ok(!$ok,"$fault is propagated instead of silently completed");
            like($error,$fault eq 'crash'?qr/Injected crash/:qr/persist.*cleanup/i,'original failure is retained');
            ok(main::webui_automation_cleanup_required(PGAutomation::read_json_file($path)),
                'interrupted verification retains a recoverable cleanup obligation');
            # Reproduce the process-recovery path, not only in-memory completion.
            main::webui_automation_recover_run($id,'runner-died','Injected interruption');
            main::webui_automation_reconcile_execution();
            is(PGAutomation::read_json_file($execution)->{status},'interrupted',
                'process recovery retains exclusive ownership');
            my $resume=PGAutomation::decode_json(main::webui_automation_control($id,'resume'));
            is($resume->{error_code},'cleanup-required','Resume cannot bypass unfinished cleanup');
            ok(!main::_finish('stopped'),'a later finish cannot reuse old verification');
            ok(-f $execution,'failed or lost verification cannot release ownership');
        }
        done_testing();
    };
}
done_testing();
