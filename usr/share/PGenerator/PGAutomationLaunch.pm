package PGAutomationLaunch;

use strict;
use warnings;
use Time::HiRes ();
use PGAutomation ();

# Internal configuration, never taken from an HTTP request. Tests use a real
# subprocess with an isolated store, not a mocked successful shell return.
our $RUNNER_PATH = '/usr/bin/pgen_automation_runner.pl';
our $PERL_PATH = '/usr/bin/perl';
our $START_TIMEOUT = 10;
# Once a worker has flagged itself ready inside the start window, the
# launcher may already be inside _accept_ready rewriting run.json, which on
# the appliance takes several seconds per megabyte of manifest. The worker
# keeps waiting for that decision (accepted or cancelled) for this long past
# the attempt deadline; a launcher that never decides still fails closed.
our $ACCEPT_GRACE = 120;

sub _quote {
    my ($value) = @_;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

sub _file { return PGAutomation::run_dir($_[0]) . '/launch.json'; }
sub _clock { return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); }

sub _owns {
    my ($value, $run_id, $token) = @_;
    return ref($value) eq 'HASH' && ($value->{run_id} || $value->{id} || '') eq $run_id
        && ($value->{token} || '') eq $token;
}

# The production command line contains only non-secret identifiers. This
# small private journal is read before the potentially large run manifest.
sub read_launch_token {
    my ($run_id, $attempt) = @_;
    return '' if !PGAutomation::safe_component($run_id) || !PGAutomation::safe_component($attempt);
    my $file=_file($run_id);
    my @st=lstat($file);
    return '' if !@st || !-f _ || -l _ || ($st[2] & 0077) || $st[7]>8192;
    my $read=PGAutomation::read_state($file);
    return '' if $read->{state} ne 'ok';
    my $launch=$read->{value};
    return '' if ($launch->{run_id}||'') ne $run_id || ($launch->{attempt}||'') ne $attempt;
    my $token=$launch->{token}||'';
    return $token =~ /\A[A-Za-z0-9_.:-]{8,200}\z/ ? $token : '';
}

sub _live_attempt_pid {
    my ($pid, $run_id, $token, $attempt) = @_;
    return 0 if !defined($pid) || $pid !~ /^\d+$/ || $pid <= 1;
    my $raw = PGAutomation::read_raw("/proc/$pid/cmdline");
    return 0 if !defined($raw);
    my @args = split(/\0/, $raw);
    for (my $i = 0; $i + 3 < @args; $i++) {
        return 1 if $args[$i] eq $RUNNER_PATH && $args[$i+1] eq $run_id
            && $args[$i+2] eq '--launch' && $args[$i+3] eq $attempt;
    }
    return 0;
}

sub _spawn_runner {
    my ($run_id, $token, $attempt, $log) = @_;
    my $command = 'setsid ' . join(' ', map { _quote($_) }
        ($PERL_PATH, $RUNNER_PATH, $run_id, '--launch', $attempt))
        . ' </dev/null >>' . _quote($log) . ' 2>&1 & printf "%s\\n" "$!"';
    # Reap only the short-lived shell. Its detached child must acknowledge the
    # unique attempt below; neither this PID nor exit 0 means it is ready.
    return 0 if !open(my $pipe, '-|', '/bin/sh', '-c', $command);
    my $pid = <$pipe> // '';
    my $ok = close($pipe);
    $pid =~ s/\s+\z//;
    return $ok && $pid =~ /^\d+$/ && $pid > 1 ? 0+$pid : 0;
}

sub _accept_ready {
    my ($run_id, $token, $attempt) = @_;
    my $dir = PGAutomation::run_dir($run_id);
    my ($ok, $accepted) = PGAutomation::with_lock(_file($run_id), sub {
        my ($launch) = @_;
        return undef if ref($launch) ne 'HASH' || ($launch->{attempt} || '') ne $attempt
            || ($launch->{state} || '') ne 'ready' || Time::HiRes::time() >= $launch->{expires_at}
            || !_live_attempt_pid($launch->{pid}, $run_id, $token, $attempt);
        my $pid = $launch->{pid};
        my $execution_file = PGAutomation::base_dir() . '/execution.json';
        die "Automation ownership changed during startup\n"
            if !_owns(PGAutomation::read_json_file($execution_file), $run_id, $token);
        my $control = PGAutomation::read_json_file("$dir/control.json") || {};
        my $status = ($control->{request} || '') eq 'stop' ? 'stopping' : 'running';
        my $now = Time::HiRes::time();
        my ($saved) = PGAutomation::with_lock("$dir/run.json", sub {
            my ($run) = @_;
            die "Run changed during startup\n" if !_owns($run, $run_id, $token)
                || ($run->{status} || '') !~ /^(?:starting|running|stopping)$/;
            $run->{status} = $status;
            $run->{runner_pid} = $pid;
            $run->{launch_attempt} = $attempt;
            $run->{started_at} ||= $now;
            $run->{heartbeat} = $now;
            return $run;
        });
        die "Unable to persist runner startup\n" if !$saved;
        ($saved) = PGAutomation::with_lock($execution_file, sub {
            my ($execution) = @_;
            die "Automation ownership changed during startup\n" if !_owns($execution, $run_id, $token);
            return {%$execution, pid=>$pid, status=>$status, launch_attempt=>$attempt, updated_at=>$now};
        });
        die "Unable to persist runner ownership\n" if !$saved;
        die "Unable to persist runner PID\n"
            if !PGAutomation::write_atomic("$dir/runner.pid", "$pid\n", 0664);
        # This is the commit point. The child is forbidden from talking to any
        # device until it sees this exact accepted attempt, after all required
        # startup writes have succeeded.
        return {%$launch, state=>'accepted', accepted_at=>$now};
    });
    return $ok && ref($accepted) eq 'HASH' && $accepted->{state} eq 'accepted' ? 1 : 0;
}

sub _cancel {
    my ($run_id, $token, $attempt, $spawn_pid) = @_;
    my ($ok, $launch) = PGAutomation::with_lock(_file($run_id), sub {
        my ($current) = @_;
        return undef if ref($current) ne 'HASH' || ($current->{attempt} || '') ne $attempt;
        return undef if ($current->{state} || '') eq 'accepted';
        return {%$current, state=>'cancelled', cancelled_at=>Time::HiRes::time()};
    });
    # An accepted attempt cannot be revoked as a failed launch. Ordinary Stop
    # owns cancellation after acceptance. Missing/unwritable cancellation state
    # still fails closed in the worker because the attempt deadline expires.
    my $current = PGAutomation::read_json_file(_file($run_id));
    return 1 if ref($current) eq 'HASH' && ($current->{attempt} || '') eq $attempt
        && ($current->{state} || '') eq 'accepted';
    my %pids = map { defined($_) ? ($_=>1) : () } ($spawn_pid, ref($launch) eq 'HASH' ? $launch->{pid} : undef);
    for my $pid (keys %pids) {
        next if !_live_attempt_pid($pid, $run_id, $token, $attempt);
        kill('TERM', $pid);
        my $until = _clock() + 0.3;
        Time::HiRes::sleep(0.02) while _clock() < $until && _live_attempt_pid($pid, $run_id, $token, $attempt);
        kill('KILL', $pid) if _live_attempt_pid($pid, $run_id, $token, $attempt);
    }
    return 0;
}

sub launch_runner {
    my ($run_id, $token) = @_;
    return 0 if !PGAutomation::safe_component($run_id) || !defined($token) || ref($token)
        || $token !~ /^[A-Za-z0-9_.:-]{8,200}$/;
    my $dir = PGAutomation::run_dir($run_id);
    my $run = PGAutomation::read_json_file("$dir/run.json");
    my $execution = PGAutomation::read_json_file(PGAutomation::base_dir() . '/execution.json');
    return 0 if !_owns($run, $run_id, $token) || !_owns($execution, $run_id, $token);
    return 0 if PGAutomation::pid_is_live($run->{runner_pid}, 'pgen_automation_runner.pl')
        || PGAutomation::pid_is_live($execution->{pid}, 'pgen_automation_runner.pl');
    my $attempt = PGAutomation::new_id();
    my $deadline = _clock() + $START_TIMEOUT;
    my ($saved) = PGAutomation::with_lock(_file($run_id), sub {
        return {run_id=>$run_id, token=>$token, attempt=>$attempt, state=>'pending',
            created_at=>Time::HiRes::time(), expires_at=>Time::HiRes::time()+$START_TIMEOUT};
    });
    return 0 if !$saved;
    if (-e "$dir/runner.pid" && !unlink("$dir/runner.pid")) {
        return _cancel($run_id, $token, $attempt, 0);
    }
    my $pid = _spawn_runner($run_id, $token, $attempt, "$dir/runner.log");
    return _cancel($run_id, $token, $attempt, 0) if !$pid;
    while (_clock() < $deadline) {
        return 1 if _accept_ready($run_id, $token, $attempt);
        my $launch = PGAutomation::read_json_file(_file($run_id));
        last if ref($launch) ne 'HASH' || ($launch->{attempt} || '') ne $attempt
            || ($launch->{state} || '') =~ /^(?:cancelled|failed)$/;
        Time::HiRes::sleep(0.02);
    }
    return _cancel($run_id, $token, $attempt, $pid);
}

sub worker_handshake {
    my ($run_id, $token, $attempt) = @_;
    return 0 if !PGAutomation::safe_component($attempt);
    my ($ok, $ready) = PGAutomation::with_lock(_file($run_id), sub {
        my ($launch) = @_;
        return undef if ref($launch) ne 'HASH' || ($launch->{attempt} || '') ne $attempt
            || ($launch->{state} || '') ne 'pending' || Time::HiRes::time() >= $launch->{expires_at};
        return undef if !_owns(PGAutomation::read_json_file(PGAutomation::base_dir().'/execution.json'), $run_id, $token);
        return {%$launch, state=>'ready', pid=>$$};
    });
    return 0 if !$ok || ref($ready) ne 'HASH';
    my $deadline = _clock() + ($ready->{expires_at} - Time::HiRes::time()) + $ACCEPT_GRACE;
    while (1) {
        my $launch = PGAutomation::read_json_file(_file($run_id));
        return 0 if ref($launch) ne 'HASH' || ($launch->{attempt} || '') ne $attempt
            || ($launch->{pid} || 0) != $$ || ($launch->{state} || '') =~ /^(?:failed|cancelled)$/;
        if (($launch->{state} || '') eq 'accepted') {
            my $run = PGAutomation::read_json_file(PGAutomation::run_dir($run_id).'/run.json');
            my $execution = PGAutomation::read_json_file(PGAutomation::base_dir().'/execution.json');
            return _owns($run,$run_id,$token) && _owns($execution,$run_id,$token)
                && ($run->{launch_attempt}||'') eq $attempt && ($execution->{launch_attempt}||'') eq $attempt
                && ($execution->{pid}||0) == $$ && ($run->{runner_pid}||0) == $$ ? 1 : 0;
        }
        return 0 if _clock() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
}

1;
