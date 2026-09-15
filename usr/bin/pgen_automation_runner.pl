#!/usr/bin/perl

use strict;
use warnings;

BEGIN {
    my $dir = __FILE__;
    $dir =~ s{/[^/]+$}{};
    $dir =~ s{/bin$}{/share/PGenerator};
    $dir = '/usr/share/PGenerator' if $dir eq '';
    unshift @INC, $dir;
}

use Fcntl qw(:flock);
use Encode qw(encode);
use File::Path qw(make_path);
use HTTP::Tiny;
use IO::Select;
use JSON::PP ();
use POSIX qw(strftime);
use Time::HiRes qw(time);
use PGAutomation ();
use PGAutomationETA ();
use PGMath ();
use PGSignalCode ();
use PGLGCapabilities qw(lg_setting_values_agree lg_scoped_request_payload lg_setting_write_accepted lg_readback_unavailable_reason);

my ($RUN_ID, $TOKEN) = @ARGV;
die "usage: pgen_automation_runner.pl RUN_ID TOKEN\n"
    if !defined($RUN_ID) || !defined($TOKEN)
    || !PGAutomation::safe_component($RUN_ID)
    || $TOKEN !~ /^[A-Za-z0-9_.:-]{8,200}$/;

my $RUN_DIR = PGAutomation::run_dir($RUN_ID);
my $RUN_FILE = $RUN_DIR . '/run.json';
my $CONTROL_FILE = $RUN_DIR . '/control.json';
my $EXECUTION_FILE = PGAutomation::base_dir() . '/execution.json';
my $RUNNER_LOCK_FILE = PGAutomation::base_dir() . '/runner.lock';
my $HTTP = HTTP::Tiny->new(
    agent   => 'PGenerator-automation/1',
    timeout => 45,
);
my $API_RETRY_INTERVAL = 5;
my $API_RETRY_WINDOW = 300;

my $STOP_REQUESTED = 0;
my $PAUSE_REQUESTED = 0;
my $STOP_HANDLED = 0;
my $STOPPING = 0;
my $ACTIVE_ITEM;
my $ACTIVE_STAGE = '';
my $ACTIVE_WORKER = '';
my ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE);
my $ETA_HISTORY=[];
my $LAST_CONTROL_POLL = 0;
my $LAST_HEARTBEAT = 0;
my $RUNNER_LOCK;
my $SETUP_WHITE_SEQUENCE = 0;

$SIG{TERM} = sub { $STOP_REQUESTED = 1; };
$SIG{INT}  = sub { $STOP_REQUESTED = 1; };

sub _log {
    my ($message, $event_time) = @_;
    $message = '' if !defined($message);
    my $stamp = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(defined($event_time) ? $event_time : time()));
    # JSON status text is decoded characters. Raw STDERR otherwise emits
    # Latin-1-range characters (e.g. the cube's superscript 3) as invalid UTF-8.
    print STDERR encode('UTF-8', "[$stamp] $message\n");
}

sub _log_action {
    my ($message) = @_;
    my $number = _active_item_number();
    $message =~ s/[\r\n]+/ /g;
    _log((defined($number) ? 'Job '.($number+1).' | ' : '').$message);
}

# Deliberately sparse: one notice after 20 seconds, then at most every 30.
# No payload values, pairing keys or worker debug dumps in routine output.
sub _log_wait {
    my ($label, $started, $last, $now) = @_;
    $now = time() if !defined($now);
    return if $now-$started<20 || (defined($$last) && $now-$$last<30);
    _log_action('Waiting for '.$label.' ('.int($now-$started).' s elapsed)');
    $$last=$now;
}

sub _api_wait_label {
    my ($path, $payload) = @_;
    if ($path eq '/api/lg/picture-settings/set') {
        my $settings=ref($payload) eq 'HASH' && ref($payload->{settings}) eq 'HASH' ? $payload->{settings} : {};
        return 'TV to accept picture mode '.$settings->{pictureMode} if defined($settings->{pictureMode}) && !ref($settings->{pictureMode});
        return 'TV to apply picture settings';
    }
    return {
        '/api/automation/readiness'=>'TV and meter readiness checks',
        '/api/lg/connect'=>'the saved TV connection',
        '/api/lg/picture-settings'=>'TV settings readback',
        '/api/lg/picture-settings/reset'=>'picture-mode reset',
        '/api/lg/sdr-calman-reset'=>'SDR calibration reset',
        '/api/lg/hdr-calman-reset'=>'HDR10 calibration reset',
        '/api/lg/dv-calman-reset'=>'Dolby Vision calibration reset',
        '/api/lg/3d-lut/reset'=>'3D LUT reset',
        '/api/lg/calibration-mode'=>'TV calibration-mode change',
        '/api/meter/read'=>'meter preparation and measurement',
        '/api/config'=>'generator output change',
        '/api/pattern'=>'the requested test pattern',
    }->{$path} || 'the generator response';
}

sub _run {
    return PGAutomation::read_json_file($RUN_FILE) || {};
}

sub _active_item_number {
    return undef if ref($ACTIVE_ITEM) ne 'HASH';
    return undef if !defined($ACTIVE_ITEM->{item_number}) || $ACTIVE_ITEM->{item_number} !~ /^\d+$/;
    return int($ACTIVE_ITEM->{item_number});
}

sub _worker_summary {
    my ($status) = @_;
    return {} if ref($status) ne 'HASH';
    my %summary;
    foreach my $key (qw(status current_name current_step total_steps current_delta_e message error_code debug)) {
        $summary{$key} = $status->{$key} if exists($status->{$key});
    }
    return \%summary;
}

sub _write_run {
    my ($run) = @_;
    return PGAutomation::write_json_atomic($RUN_FILE, $run, 0664);
}

sub _write_artifact {
    my ($path, $value) = @_;
    return 0 if !defined($path) || !defined($value);
    if (!PGAutomation::write_json_atomic($path, $value, 0664)) {
        $::LAST_ERROR = "Unable to write automation artifact $path";
        _log($::LAST_ERROR);
        return 0;
    }
    return 1;
}

sub _update_run {
    my ($callback) = @_;
    my ($ok, $value, $error) = PGAutomation::with_lock($RUN_FILE, sub {
        my ($run) = @_;
        # Never replace an unreadable manifest with a skeleton: that would
        # silently drop the items, token and checkpoints.
        die "run manifest unreadable\n" if ref($run) ne 'HASH';
        $callback->($run);
        # Advisory only: ETA failure must never stop or change calibration.
        eval { PGAutomationETA::update($run,time(),$ETA_HISTORY); 1 } or delete $run->{time_estimate};
        return $run;
    });
    _log("run state update failed: $error") if !$ok && $error;
    return $ok ? $value : undef;
}

sub _control {
    my $control = PGAutomation::read_json_file($CONTROL_FILE);
    return ref($control) eq 'HASH' ? $control : { request => 'none' };
}

sub _refresh_control {
    my $now = time();
    return if $now - $LAST_CONTROL_POLL < 0.5 && !$STOP_REQUESTED;
    $LAST_CONTROL_POLL = $now;
    my $request = _control()->{request} || 'none';
    $STOP_REQUESTED = 1 if $request eq 'stop';
    $PAUSE_REQUESTED = 1 if $request eq 'pause';
}

sub _write_execution {
    my $run = _run();
    my $value = {
        owner     => 'automation',
        run_id    => $RUN_ID,
        token     => $TOKEN,
        pid       => $$,
        updated_at => time(),
        status    => $run->{status} || 'running',
    };
    my ($ok) = PGAutomation::with_lock($EXECUTION_FILE, sub { return $value; });
    return $ok;
}

sub _release_execution {
    my ($ok) = PGAutomation::with_lock($EXECUTION_FILE, sub {
        my ($current) = @_;
        return undef if ref($current) ne 'HASH'
            || ($current->{run_id} || '') ne $RUN_ID
            || ($current->{token} || '') ne $TOKEN;
        return { __pg_automation_delete => 1 };
    });
    _log('execution lock release failed') if !$ok;
}

sub _heartbeat {
    my ($force) = @_;
    my $now = time();
    return if !$force && $now - $LAST_HEARTBEAT < 2;
    $LAST_HEARTBEAT = $now;
    my $saved = _update_run(sub {
        my ($run) = @_;
        $run->{heartbeat} = $now;
        $run->{heartbeat_at} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($now));
        $run->{runner_pid} = $$;
        my $active_item = _active_item_number();
        $run->{active_item} = $active_item if defined($active_item);
        delete($run->{active_grey_state});
        $run->{active_stage} = $ACTIVE_STAGE if $ACTIVE_STAGE ne '';
    });
    die 'Unable to persist automation heartbeat' if !ref($saved);
    die 'Unable to write automation execution heartbeat' if !_write_execution();
}

sub _sleep_controlled {
    my ($seconds) = @_;
    $seconds = 0 if !defined($seconds) || $seconds < 0;
    my $deadline = time() + $seconds;
    while (time() < $deadline) {
        _refresh_control();
        return 0 if $STOP_REQUESTED;
        _heartbeat(0);
        select(undef, undef, undef, 0.5);
    }
    return 1;
}

sub _api_once {
    my ($method, $path, $payload, $allow_stop) = @_;
    $payload=lg_scoped_request_payload($path,$payload,$ACTIVE_ITEM);
    my $url = 'http://127.0.0.1' . $path;
    my %options = (
        headers => {
            Accept => 'application/json',
        },
    );
    if ($method eq 'POST') {
        my $body = ref($payload) eq 'HASH' ? PGAutomation::clone($payload) : {};
        $body->{automation_token} = $TOKEN;
        $body->{automation_cleanup} = JSON::PP::true if $STOPPING || $allow_stop;
        $options{headers}{'Content-Type'} = 'application/json';
        $options{content} = PGAutomation::encode_json($body);
    }
    # Poll controls and maintain the heartbeat even while a reset or readiness
    # request holds the TV lane for several minutes.
    pipe(my $reader, my $writer) or die "Unable to create HTTP response pipe: $!";
    my $child = fork();
    die "Unable to launch HTTP request: $!" if !defined($child);
    if (!$child) {
        close($reader);
        # The child inherits the runner.lock descriptor; flock is only released
        # when every copy is closed, so a child stuck to its timeout would keep
        # a relaunched runner out. Drop it before the request.
        close($RUNNER_LOCK) if $RUNNER_LOCK;
        $SIG{TERM} = 'DEFAULT'; $SIG{INT} = 'DEFAULT';
        my $timeout = ref($payload) eq 'HASH' && $payload->{helper_timeout}
            ? $payload->{helper_timeout} + 20 : 60;
        $timeout = 300 if $path eq '/api/automation/readiness';
        my $client = HTTP::Tiny->new(agent => 'PGenerator-automation/1', timeout => $timeout);
        my $response = eval { $client->request($method, $url, \%options) };
        print {$writer} PGAutomation::encode_json($response || {});
        close($writer);
        POSIX::_exit(0);
    }
    close($writer);
    my $select = IO::Select->new($reader);
    my $raw = '';
    my $wait_started=time();
    my $last_wait_log;
    while (1) {
        _refresh_control();
        _heartbeat(0);
        if ($STOP_REQUESTED && !$STOPPING && !$allow_stop) {
            kill('TERM', $child); close($reader); waitpid($child, 0);
            return {status => 'error', error_code => 'stopped', message => 'Automation stop requested'};
        }
        if (!$select->can_read(0.5)) {
            _log_wait(_api_wait_label($path,$payload),$wait_started,\$last_wait_log);
            next;
        }
        my $read = sysread($reader, my $chunk, 65536);
        last if !defined($read) || !$read;
        $raw .= $chunk;
    }
    close($reader); waitpid($child, 0);
    my $response = PGAutomation::decode_json($raw);
    if (!$response || !$response->{success}) {
        my $status = $response ? ($response->{status} || 0) : 0;
        my $reason = $response ? ($response->{reason} || 'HTTP request failed') : ($@ || 'HTTP request failed');
        return {
            status => 'error',
            error_code => 'daemon-unreachable',
            http_status => $status,
            message => $reason,
            _transport_error => 1,
        };
    }
    my $decoded = PGAutomation::decode_json($response->{content} || '');
    return $decoded if ref($decoded) eq 'HASH';
    return {
        status => 'error',
        error_code => 'invalid-daemon-response',
        message => 'The daemon returned invalid JSON',
        raw_response => substr($response->{content} || '', 0, 500),
    };
}

sub _ensure_lg_connection {
    my ($force) = @_;
    my $status = _api_once('GET', '/api/lg/status', undef);
    return 1 if !$force && ref($status) eq 'HASH'
        && $status->{connected}
        && !$status->{disconnected};
    my $ip = ref($status) eq 'HASH'
        ? ($status->{stored_ip} || $status->{manual_ip} || $status->{ip} || '') : '';
    if ($ip !~ /^[A-Za-z0-9_.:-]{1,120}$/) {
        $::LAST_ERROR = 'The paired LG TV has no reconnectable address';
        return 0;
    }
    for my $attempt (1..3) {
        my $connect = _api_once('POST', '/api/lg/connect', { ip => $ip });
        if (ref($connect) eq 'HASH' && $connect->{connected} && !$connect->{disconnected}) {
            _log($force ? 'refreshed the paired LG TV connection for automation'
                : 'reconnected the paired LG TV for automation');
            return 1;
        }
        my $check = _api_once('GET', '/api/lg/status', undef);
        if (ref($check) eq 'HASH' && $check->{connected} && !$check->{disconnected}) {
            _log($force ? 'refreshed the paired LG TV connection for automation'
                : 'reconnected the paired LG TV for automation');
            return 1;
        }
        _sleep_controlled(1) or return 0;
    }
    $::LAST_ERROR = 'The paired LG TV could not be reconnected';
    return 0;
}

sub _lg_action_path {
    my ($path) = @_;
    return 0 if !defined($path) || $path !~ m{\A/api/lg/};
    return 0 if $path =~ m{\A/api/lg/(?:status|connect|disconnect)\z};
    return 1;
}

sub _lg_connection_failure {
    my ($response) = @_;
    return 0 if ref($response) ne 'HASH' || ($response->{status} || '') ne 'error';
    my $code = lc($response->{error_code} || '');
    return 1 if $code =~ /(?:lg|tv)[_-](?:unreachable|disconnected|connection)/;
    my $message = lc(join(' ', map { defined($_) ? "$_" : '' }
        @{$response}{qw(message error raw_error)}));
    return 1 if $message =~ /unable to connect to lg webos tv/;
    return 1 if $message =~ /connect the lg tv before/;
    return 1 if $message =~ /lg tv did not (?:answer|finish)/;
    return 1 if $message =~ /lg webos tv.*(?:websocket|connection)/;
    return 0;
}

sub _api {
    my ($method, $path, $payload, $allow_stop, $retry_window) = @_;
    $allow_stop = 0 if !defined($allow_stop);
    $retry_window = $API_RETRY_WINDOW if !defined($retry_window);
    $retry_window = 0 if $retry_window < 0;
    my $last;
    my $started = time();
    my $attempt = 0;
    my $lg_action = _lg_action_path($path) && !$allow_stop;
    my $lg_preflighted = 0;
    my $lg_reconnects = 0;
    while (1) {
        $attempt++;
        _refresh_control() unless $allow_stop;
        if ($STOP_REQUESTED && !$allow_stop) {
            return { status => 'error', error_code => 'stopped', message => 'Automation stop requested' };
        }
        _heartbeat(0);
        if ($lg_action && !$lg_preflighted) {
            $lg_preflighted = 1;
            _ensure_lg_connection();
        }
        $last = _api_once($method, $path, $payload, $allow_stop);
        if (!$last->{_transport_error}) {
            if ($lg_action && _lg_connection_failure($last) && $lg_reconnects < 3) {
                $lg_reconnects++;
                _log("LG request $method $path reported a connection failure; refreshing the pairing (attempt $lg_reconnects)");
                if (_ensure_lg_connection(1)) {
                    next;
                }
            }
            $::LAST_ERROR_CODE = (($last->{status} || '') eq 'error' && $last->{error_code})
                ? $last->{error_code} : '';
            return $last;
        }
        my $remaining = $retry_window - (time() - $started);
        last if $remaining <= 0;
        my $delay = $remaining < $API_RETRY_INTERVAL ? $remaining : $API_RETRY_INTERVAL;
        _log("daemon request $method $path failed; retrying in ${API_RETRY_INTERVAL} seconds (attempt $attempt, ${retry_window}s window)");
        last if !_sleep_controlled($delay);
    }
    $::LAST_ERROR_CODE = 'daemon-unreachable';
    return $last || { status => 'error', error_code => 'daemon-unreachable' };
}

sub _ping_ok {
    my ($ping) = @_;
    return 0 if ref($ping) ne 'HASH' || $ping->{_transport_error} || ($ping->{status} || '') eq 'error';
    return ($ping->{ok} || ($ping->{status} || '') ne '') ? 1 : 0;
}

sub _response_ok {
    my ($response) = @_;
    return ref($response) eq 'HASH' && (($response->{status} || '') eq 'ok'
        || ($response->{status} || '') eq 'started'
        || ($response->{status} || '') eq 'measuring'
        || ($response->{status} || '') eq 'running');
}

sub _item_snapshot {
    my ($item) = @_;
    return $item if ref($item) eq 'HASH';
    return {};
}

sub _signal {
    my ($item) = @_;
    my $signal = lc($item->{signal_format} || $item->{signal_mode} || $item->{format} || 'sdr');
    $signal = 'hdr10' if $signal eq 'hdr';
    return $signal =~ /^(?:sdr|hdr10|hlg|dv)$/ ? $signal : 'sdr';
}

sub _picture_mode {
    my ($item) = @_;
    return $item->{picture_mode} || $item->{pictureMode} || '';
}

sub _stages {
    my ($item) = @_;
    my $stages = ref($item->{stages}) eq 'HASH' ? $item->{stages} : {};
    my $pre = exists($stages->{pre_readings}) ? $stages->{pre_readings}
        : exists($item->{pre_readings}) ? $item->{pre_readings} : 0;
    my $cal = exists($stages->{calibration}) ? $stages->{calibration}
        : exists($item->{calibration}) ? $item->{calibration} : 1;
    my $post = exists($stages->{post_readings}) ? $stages->{post_readings}
        : exists($item->{post_readings}) ? $item->{post_readings} : 0;
    return {
        pre => $pre ? 1 : 0,
        calibration => $cal ? 1 : 0,
        post => $post ? 1 : 0,
        apply_all => exists($stages->{apply_all}) ? ($stages->{apply_all} ? 1 : 0)
            : exists($item->{apply_all}) ? ($item->{apply_all} ? 1 : 0) : 1,
    };
}

sub _series_selection {
    my ($item, $which) = @_;
    my $field = $which eq 'post' ? 'post_series' : 'pre_series';
    my $selection = $item->{$field};
    $selection = $item->{series} if ref($selection) ne 'ARRAY';
    $selection = ['greyscale-21', 'colors-30', 'saturations-24']
        if ref($selection) ne 'ARRAY' || !@$selection;
    my %valid = map { $_ => 1 } qw(greyscale-21 colors-30 saturations-24);
    my @keys;
    foreach my $key (@$selection) {
        next if !defined($key) || !$valid{$key};
        push @keys, $key if !grep { $_ eq $key } @keys;
    }
    return @keys;
}

sub _series_info {
    my ($key) = @_;
    return ('greyscale', 21) if $key eq 'greyscale-21';
    return ('colors', 30) if $key eq 'colors-30';
    return ('saturations', 24) if $key eq 'saturations-24';
    return ('greyscale', 21);
}

sub _default_range {
    my ($item) = @_;
    return "$item->{signal_range}" if defined($item->{signal_range}) && $item->{signal_range} =~ /^[12]$/;
    return "$item->{pattern_signal_range}" if defined($item->{pattern_signal_range}) && $item->{pattern_signal_range} =~ /^[12]$/;
    return '2';
}

sub _measurement_options {
    my ($item) = @_;
    return map { $_ => $item->{$_} } grep {
        /^patch_insert/ || /^(?:measurement_meter_port|measurement_meter_usb_id|observer|low_light)$/
    } keys %$item;
}

# The step builder and every worker must see the same transport. In particular,
# omitting color_format makes the SDR DPG worker default to RGB even when its
# supplied steps describe the YCbCr 99/105/109 ladder.
sub _transport_options {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    return (
        color_format => $item->{color_format} // '0',
        max_bpc => $item->{max_bpc} || $cal->{max_bpc} || (_signal($item) eq 'dv' ? 8 : 10),
    );
}

sub _series_payload {
    my ($item, $key, $run_id) = @_;
    my ($type, $points) = _series_info($key);
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $target_gamma = $item->{target_gamma} || $cal->{target_gamma}
        || ($signal eq 'sdr' ? 'bt1886' : $signal eq 'hlg' ? 'hlg' : 'st2084');
    $target_gamma = 'st2084' if $signal eq 'dv';
    my $payload = {
        _transport_options($item),
        type => $type,
        points => $points,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        max_luma => 0 + ($item->{max_luma} || 1000),
        target_gamma => $target_gamma,
        target_gamut => $signal eq 'dv' ? 'p3d65' : ($item->{target_gamut} || 'auto'),
        dv_map_mode => $signal eq 'dv' ? '1' : '',
        requested_signal_mode => $signal,
        refresh_rate => $item->{refresh_rate} || '',
        measurement_meter_port => $item->{measurement_meter_port} || '',
        measurement_meter_usb_id => $item->{measurement_meter_usb_id} || '',
        observer => '1931_2',
        pattern_provider => $item->{pattern_provider} || 'local',
        target_white_use_measured => JSON::PP::true,
        custom_d65_enabled => JSON::PP::true,
        target_white_x => ($item->{target_white} || $cal->{target_white} || {})->{x} // 0.3127,
        target_white_y => ($item->{target_white} || $cal->{target_white} || {})->{y} // 0.3290,
        series_report_key => $key,
        full_autocal_run_id => $run_id,
        require_device_ready => JSON::PP::false,
    };
    foreach my $key (keys %$item) {
        $payload->{$key} = $item->{$key} if $key =~ /^patch_insert/ || $key eq 'low_light';
    }
    return $payload;
}

sub _grey_code {
    my ($signal, $ire, $range, $max_bpc) = @_;
    $max_bpc = 10 if !defined($max_bpc) || $max_bpc !~ /^(?:8|10|12)$/;
    my $max = $max_bpc == 12 ? 4095 : $max_bpc == 10 ? 1023 : 255;
    if ($signal eq 'dv') {
        return int(256 + ($ire / 100.0) * 3504 + 0.5);
    }
    if ($range eq '1') {
        my $min = $max_bpc == 10 ? 64 : $max_bpc == 12 ? 256 : 16;
        my $span = $max_bpc == 10 ? 876 : $max_bpc == 12 ? 3504 : 219;
        return int($min + ($ire / 100.0) * $span + 0.5);
    }
    return int(($ire / 100.0) * $max + 0.5);
}

sub _grey_steps {
    my ($item) = @_;
    my $signal = _signal($item);
    my $range = _default_range($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my %transport = _transport_options($item);
    my $max_bpc = $transport{max_bpc};
    my @ires;
    if ($signal eq 'hdr10' || $signal eq 'dv') {
        @ires = (100, 0, 90, 80, 70, 60, 50, 45, 40, 35, 30, 25, 20, 15, 10, 7, 5, 4, 2.7, 2, 1.4);
    } elsif ($range eq '1' && ($item->{color_format} || '0') =~ /^(?:1|2)$/) {
        @ires = (100, 0, 2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99, 105, 109);
    } else {
        @ires = (100, 0, 2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95);
    }
    if ($cal->{dark_detail}) {
        my @fillers = ($signal eq 'hdr10' || $signal eq 'dv')
            ? (1,2.3,3,3.7,6,8,55,65,75,85,95) : (2,2.7,3.7,6,8,9);
        my %seen = map { $_ => 1 } @ires;
        push @ires, grep { !$seen{$_}++ } @fillers;
    }
    # Use the same signal-code policy as the guided series path. In particular,
    # HDR20 has a slot table. Standard DV authors 12-bit Limited components
    # inside an 8-bit Full HDMI tunnel, just like the manual wizard. The link's
    # range/bit depth must not become the source-code range/bit depth.
    my $code_policy = PGSignalCode::signal_code_policy({
        signal_mode=>$signal, pattern_range=>$range, max_bpc=>$max_bpc,
        color_format=>$item->{color_format} || '0',
        ($signal eq 'sdr' ? (autocal_26_codes=>1)
         : $signal eq 'hdr10' ? (hdr20_codes=>1,hdr20_use_limited=>1,hdr20_full=>($range ne '1' ? 1 : 0))
         : (dv_series=>1,dv_series_code_bits=>12,dv_series_full_range=>0)),
    });
    die "Unable to build greyscale signal-code policy\n" if !defined($code_policy);
    my @steps;
    foreach my $ire (@ires) {
        my $encoded = PGSignalCode::signal_percent_to_code($code_policy,$ire);
        die "Unable to encode greyscale step $ire\n" if ref($encoded) ne 'HASH';
        my $code = $encoded->{code};
        my $step = {
            name => sprintf('%.4g%%', $ire),
            ire => 0 + $ire,
            stimulus => 0 + $ire,
            nominal_ire => 0 + $ire,
            r => $code,
            g => $code,
            b => $code,
            r_code => $code,
            g_code => $code,
            b_code => $code,
            input_max => $encoded->{input_max},
            signal_r_pct => 0 + $ire,
            signal_g_pct => 0 + $ire,
            signal_b_pct => 0 + $ire,
            target_ire => 0 + $ire,
            autocal_white_reference => abs($ire - 100) < 0.001 ? JSON::PP::true : undef,
            ddc_layout => $signal eq 'sdr' ? 'sdr26' : 'hdr20',
        };
        if (abs($ire) < 0.001) {
            $step->{autocal_reference_only} = JSON::PP::true;
            $step->{autocal_read_only} = JSON::PP::true;
        }
        if (abs($ire - 100) < 0.001) {
            $step->{read_delay_ms} = 3000;
            if ($signal eq 'sdr' && $range eq '1'
                && ($item->{color_format} || '0') =~ /^(?:1|2)$/) {
                $step->{autocal_reference_only} = JSON::PP::true;
                $step->{autocal_read_only} = JSON::PP::true;
                $step->{autocal_legal_white_anchor} = JSON::PP::true;
                $step->{ddc_target_ire} = 99;
                $step->{autocal_order_ire} = 98.95;
            }
        } elsif ($signal eq 'sdr' && $ire > 0 && $ire <= 25) {
            $step->{read_delay_ms} = $ire <= 10 ? 6000 : 3200;
        }
        push @steps, $step;
    }
    return \@steps;
}

sub _grey_payload {
    my ($item) = @_;
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $steps = _grey_steps($item);
    my $target_gamma = $cal->{target_gamma} || $item->{target_gamma} || 'bt1886';
    $target_gamma = '2.2' if $signal eq 'hdr10' || $signal eq 'dv';
    my $body = {
        _measurement_options($item),
        _transport_options($item),
        type => 'greyscale',
        points => 26,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        ($signal eq 'dv' ? (dv_map_mode => '2') : ()),
        target_delta_e => 0 + ($cal->{target_delta_e} || $item->{target_delta_e} || 0.5),
        delta_e_formula => $cal->{delta_e_formula} || $item->{delta_e_formula} || 'deitp',
        target_gamma => $target_gamma,
        target_white => $cal->{target_white} || $item->{target_white} || { x => 0.3127, y => 0.3290 },
        target_luminance => ($signal eq 'sdr' ? 0 + ($item->{target_luminance} || $cal->{target_luminance} || 100) : undef),
        setup_luminance_reference => ($signal eq 'sdr' ? 0 + ($cal->{setup_luminance_reference} || $item->{target_luminance} || 100) : undef),
        headroom_target_luminance => ($signal eq 'sdr' ? 0 + ($cal->{headroom_target_luminance} || 0) : undef),
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        force_ddc_white_balance => JSON::PP::true,
        preflight_generation_profile => $item->{generation_profile},
        lg_autocal_sdr_1d_dpg_upload_enabled => JSON::PP::true,
        lg_autocal_26 => JSON::PP::true,
        lg_greyscale_21 => JSON::PP::false,
        lg_autocal_26_full_ddc_spine => JSON::PP::true,
        lg_extended_sdr_16_255 => $signal eq 'sdr' ? JSON::PP::true : JSON::PP::false,
        dark_detail => $cal->{dark_detail} ? 1 : 0,
        restore_factory_levels => JSON::PP::false,
        reset_ddc_baseline => JSON::PP::false,
        full_workflow => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        full_autocal_phase => 'first-greyscale',
        max_iterations => int($cal->{max_iterations} || 36),
        headroom_max_iterations => int($cal->{headroom_max_iterations} || 60),
        max_polish_iterations => int($cal->{max_polish_iterations} // 16),
        precision_polish_iterations => int($cal->{precision_polish_iterations} // 18),
        low_light => ref($item->{low_light}) eq 'HASH' ? $item->{low_light} : {},
        refresh_rate => $item->{refresh_rate} || '',
        require_device_ready => JSON::PP::false,
        steps => $steps,
    };
    delete $body->{$_} for grep { !defined($body->{$_}) } keys %$body;
    return $body;
}

sub _lattice_patches {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    if (ref($cal->{lattice_patches}) eq 'ARRAY' && @{$cal->{lattice_patches}}) {
        # Older queued snapshots used r/g/b instead of the worker's percent keys.
        return [map { ref($_) eq 'HASH' && !defined($_->{name}) && defined($_->{r})
            ? {%$_, r_pct=>$_->{r}, g_pct=>$_->{g}, b_pct=>$_->{b}} : $_ } @{$cal->{lattice_patches}}];
    }
    my $method = $cal->{method} || 'hybrid';
    my $size = $cal->{lattice_size} || 5;
    $size = $1 if ($cal->{profile_source} || '') =~ /^hybrid([359])$/;
    $size = 5 if $size !~ /^(?:3|5|9)$/;
    my @levels = map { 100 * $_ / ($size - 1) } 0..($size - 1);
    my @patches;
    my %seen;
    my $add = sub {
        my $name = join('/',map { sprintf('%.6g',$_) } @_);
        push @patches,{name=>$name} if !$seen{$name}++;
    };
    if ($method eq 'skeleton' || $method eq 'hybrid') {
        $add->(0,0,0);
        for my $level (5,10,20,30,40,50,60,70,80,90,100) {
            $add->($level,$level,$level);$add->($level,0,0);$add->(0,$level,0);$add->(0,0,$level);
        }
    }
    return \@patches if $method eq 'skeleton';
    foreach my $r (@levels) {
        foreach my $g (@levels) {
            foreach my $b (@levels) {
                $add->($r,$g,$b);
            }
        }
    }
    return \@patches;
}

sub _three_d_payload {
    my ($item, $run, $item_number) = @_;
    my $automatic_settings=_item_settings($item);
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $method = lc($cal->{method} || $item->{method} || ($signal eq 'hdr10' ? 'matrix' : 'hybrid'));
    $method = 'matrix' if $signal eq 'hdr10' && $method ne 'imported';
    $method = 'hybrid' if $method !~ /^(?:matrix|ramp|lattice|skeleton|hybrid|imported)$/;
    my $grey = {};
    if (defined($item_number)) {
        my $saved = PGAutomation::read_json_file(
            PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/grey-state.json'
        );
        $grey = $saved if ref($saved) eq 'HASH';
    }
    $grey = {} if ref($grey) ne 'HASH';
    my $body = {
        _measurement_options($item),
        _transport_options($item),
        method => $method,
        type => 'lg-3d-lut',
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        requested_signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        target_gamma => $signal eq 'hdr10' ? 'st2084' : ($cal->{target_gamma} || $item->{target_gamma} || 'bt1886'),
        target_gamut => $signal eq 'hdr10' ? ($item->{target_gamut} || 'p3d65') : ($cal->{target_gamut} || $item->{target_gamut} || 'bt709'),
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        upload => JSON::PP::true,
        full_workflow => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        full_autocal_phase => '3d-lut',
        automation_processing_settings => {map {$_=>$automatic_settings->{$_}} grep {_processing_setting($_)} keys %$automatic_settings},
        lattice_patches => ($method =~ /^(?:lattice|skeleton|hybrid)$/ ? _lattice_patches($item) : undef),
        solve_matrix_only => $cal->{lattice_residuals} ? JSON::PP::false : JSON::PP::true,
        solve_cube_size => int($cal->{solve_cube_size} || 17),
        refresh_rate => $item->{refresh_rate} || '',
        require_device_ready => JSON::PP::false,
        post_check => JSON::PP::false,
        preflight_lg_generation => $item->{lg_generation},
        preflight_generation_profile => $item->{generation_profile},
        lg_autocal_hdr20_postcal_shadow_enable => $cal->{shadow_fix} ? 1 : 0,
        low_light => ref($item->{low_light}) eq 'HASH' ? $item->{low_light} : {},
    };
    if ($signal eq 'hdr10') {
        $body->{upload_command} = 'BT2020_3D_LUT_DATA';
        $body->{get_command} = 'GET_3D_LUT_DATA';
        $body->{full_workflow_peak_luminance} = $grey->{hdr20_1d_tonemap_peak_luminance}
            || $grey->{hdr_tone_map_peak_luminance} || $grey->{hdr20_1d_dpg_white_ref}
            || $grey->{calibrated_white_luminance} if ref($grey) eq 'HASH';
        $body->{full_workflow_dpg_data} = $grey->{hdr20_1d_dpg_data}
            if ref($grey->{hdr20_1d_dpg_data}) eq 'ARRAY' && @{$grey->{hdr20_1d_dpg_data}} == 3072;
    }
    $body->{full_workflow_dpg_data} = $grey->{sdr_1d_dpg_data}
        if $signal eq 'sdr' && ref($grey->{sdr_1d_dpg_data}) eq 'ARRAY' && @{$grey->{sdr_1d_dpg_data}} == 3072;
    delete $body->{$_} for grep { !defined($body->{$_}) } keys %$body;
    return $body;
}

sub _dv_payload {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $range = _default_range($item);
    return {
        _measurement_options($item),
        _transport_options($item),
        signal_mode => 'dv',
        dv_map_mode => '2',
        input_max => 4095,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        pattern_signal_range => $range,
        signal_range => $range,
        transport_signal_range => $range,
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        patch_size => int($item->{patch_size} || 10),
        refresh_rate => $item->{refresh_rate} || '',
        upload => JSON::PP::false,
        keep_calibration_mode => JSON::PP::true,
        calibration_mode_active => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        require_device_ready => JSON::PP::false,
        max_luma => 1000,
        preflight_generation_profile => $item->{generation_profile},
    };
}

sub _status_terminal {
    my ($status) = @_;
    return defined($status) && $status =~ /^(?:complete|error|failed|cancelled|stopped|idle)$/;
}

sub _start_worker {
    my ($path, $status_path, $payload) = @_;
    my $result;
    for my $attempt (1..6) {
        $result = _api('POST', $path, $payload, 0, 0);
        return $result if ($result->{status} || '') eq 'started';
        return $result if $STOP_REQUESTED;
        my $probe = _api('GET', $status_path, undef, 0, 0);
        if (($probe->{status} || '') eq 'running' && $payload->{full_autocal_run_id}
            && ($probe->{full_autocal_run_id} || '') eq $payload->{full_autocal_run_id}) {
            return {status => 'started', adopted => JSON::PP::true};
        }
        last if !$result->{retryable} && !$result->{_transport_error}
            && ($result->{error_code} || '') !~ /finishing/;
        my $delay = ($result->{retry_after_ms} || 1000) / 1000;
        $delay = 3 if $delay > 3; $delay = 0.25 if $delay < 0.25;
        _sleep_controlled($delay) or last;
    }
    return $result;
}

sub _worker_progress {
    my ($status) = @_;
    my $message=$status->{message} || '';
    # Sample counters belong in live status. Save point transitions once,
    # plus actual measurements/events and exceptional state changes.
    $message='' if $message =~ /^Reading\b/i;
    $message='' if $status->{activity_sequence} && $message =~ / uploaded \(max dE=/;
    $message='' if $message eq ($status->{current_name}||'');
    return join(' | ', grep { defined($_) && !ref($_) && $_ ne '' }
        $status->{status}, $status->{current_name}, $message,
        defined($status->{current_step}) && ($status->{status}||'') ne 'complete'
            ? 'Patch '.$status->{current_step}.' / '.($status->{total_steps}||'?') : undef);
}

sub _log_worker_events {
    my ($status,$last) = @_;
    return if ref($status->{activity_events}) ne 'ARRAY';
    my @events=sort {$a->{seq}<=>$b->{seq}} grep {
        ref($_) eq 'HASH' && defined($_->{seq}) && $_->{seq}=~/^\d+$/ && $_->{seq}>$$last
        && defined($_->{message}) && !ref($_->{message})
    } @{$status->{activity_events}};
    _log_action('Worker activity gap: earlier detail events expired before collection; see saved worker log')
        if @events && $events[0]{seq}>$$last+1;
    for my $event (@events) {
        next if $event->{seq}<=$$last;
        my $message=substr($event->{message},0,1500);$message=~s/[\r\n]+/ /g;
        my $number=_active_item_number();
        my $timestamp=defined($event->{time}) && !ref($event->{time}) && $event->{time}=~/^\d+(?:\.\d+)?$/ ? $event->{time} : undef;
        _log((defined($number)?'Job '.($number+1).' | ':'').'1D LUT | '.$message,$timestamp);
        $$last=$event->{seq};
    }
}

sub _wait_worker {
    my ($status_path, $kind, $item) = @_;
    my $started = time();
    my $last_keepalive = 0;
    my $last_log_progress = '';
    my $last_activity_sequence = 0;
    my ($timing_started,$timing_base,$timing_last)=($started,0,0);
    my $point_started=$started;
    my @point_seconds;
    while (time() - $started < 21600) {
        _refresh_control();
        if ($STOP_REQUESTED) {
            _log("$kind interrupted by stop request before worker status became terminal");
            return undef;
        }
        my $status = _api('GET', $status_path, undef);
        return $status if $status->{error_code} && $status->{error_code} eq 'daemon-unreachable';
        my $now = time();
        if ($now - $last_keepalive >= 60) {
            $last_keepalive = $now;
            my $tv = _api('GET', '/api/lg/status', undef);
            if (ref($tv) eq 'HASH' && $tv->{disconnected}) {
                _ensure_lg_connection();
                $tv = _api('GET', '/api/lg/status', undef, 0, 0);
            }
            if (ref($tv) ne 'HASH' || ($tv->{status} || '') eq 'error' || $tv->{disconnected}
                || lc($tv->{tv_power} || $tv->{power} || '') =~ /^(?:off|standby|powering-off)$/) {
                $status = {
                    status => 'error',
                    error_code => 'tv-unreachable',
                    message => 'The LG TV stopped answering or entered standby',
                };
                return $status;
            }
        }
        my $state = $status->{status} || '';
        my $step=0+($status->{current_step}||0);
        if ($state eq 'running' && $step<$timing_last) {
            ($timing_started,$timing_base)=($now,$step>0?$step-1:0);
            @point_seconds=();$point_started=$now;
        } elsif ($state eq 'running' && $step>$timing_last) {
            if ($timing_last>0 && $now>$point_started) {
                push @point_seconds,($now-$point_started)/($step-$timing_last);
                shift @point_seconds while @point_seconds>5;
            }
            $point_started=$now;
        }
        $timing_last=$step;
        _log_worker_events($status,\$last_activity_sequence);
        my $progress = _worker_progress($status);
        if ($progress ne $last_log_progress) {
            $last_log_progress = $progress;
            my $number = _active_item_number();
            _log((defined($number) ? 'Job '.($number+1).' | ' : '')."$kind | $progress");
        }
        _update_run(sub {
            my ($run) = @_;
            $run->{worker_status} = _worker_summary($status);
            $run->{worker_timing}={started_at=>$timing_started,start_step=>$timing_base,kind=>$ACTIVE_WORKER,stage=>$ACTIVE_STAGE,series_key=>$ACTIVE_SERIES_KEY||'',recent_point_seconds=>[@point_seconds]};
            $run->{active_stage} = $ACTIVE_STAGE;
            my $active_item = _active_item_number();
            $run->{active_item} = $active_item if defined($active_item);
        });
        if ($state eq 'idle' && _worker_process_alive($ACTIVE_WORKER)) {
            _sleep_controlled(2) or return undef;
            next;
        }
        return $status if _status_terminal($state);
        return { status => 'error', error_code => 'worker-timeout', message => "$kind exceeded six hours" }
            if time() - $started >= 21600;
        _sleep_controlled(2) or return undef;
    }
    return { status => 'error', error_code => 'worker-timeout', message => "$kind exceeded six hours" };
}

sub _worker_process_alive {
    my ($kind) = @_;
    my %pattern = (
        series => '[m]eter_series\\.sh',
        grey   => '[m]eter_lg_autocal\\.pl',
        '3d'   => '[m]eter_lg_3d_autocal\\.pl',
        dv     => '[m]eter_lg_dv_profile\\.pl',
    );
    my $needle = $pattern{$kind} || '';
    return 0 if $needle eq '';
    my $alive = `pgrep -f '$needle' 2>/dev/null`;
    return $alive =~ /\d/ ? 1 : 0;
}

sub _copy_worker_files {
    my ($item_number, $kind, $state) = @_;
    my $dir = PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration';
    return 0 if $dir eq '';
    if (!-d $dir && !eval { make_path($dir, { mode => 0775 }); 1 }) {
        _log("unable to create calibration artifact directory $dir");
        return 0;
    }
    # The daemon deliberately leaves user files alone, so a previous guided
    # run may still have state in /tmp. Capture only a worker state supplied by
    # the current wait, or a partial state while that worker is still active;
    # later checkpoints preserve the copy already made for this item.
    my $capture_current = ref($state) eq 'HASH' || $ACTIVE_WORKER eq $kind;
    return 1 if !$capture_current;
    my $copy_if_present = sub {
        my ($source, $destination) = @_;
        return 1 if !-f $source;
        if (!PGAutomation::copy_artifact($source, $destination)) {
            _log("unable to copy automation artifact $source to $destination");
            return 0;
        }
        return 1;
    };
    my $ok = 1;
    if ($kind eq 'grey') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_autocal.json', "$dir/grey-state.json");
        $ok &&= $copy_if_present->('/tmp/meter_lg_autocal.log', "$dir/grey-log.txt");
        $ok &&= _write_artifact("$dir/grey-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/grey-state.json";
    } elsif ($kind eq '3d') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_3d_autocal.json', "$dir/3d-state.json");
        $ok &&= $copy_if_present->('/tmp/meter_lg_3d_autocal.log', "$dir/3d-log.txt");
        $ok &&= _write_artifact("$dir/3d-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/3d-state.json";
        if (ref($state) eq 'HASH' && ref($state->{export}) eq 'HASH') {
            foreach my $key (qw(cube_path payload_path)) {
                my $source = $state->{export}{$key} || '';
                next if $source eq '' || $source !~ m{/var/lib/PGenerator/lg/luts/[A-Za-z0-9_.-]+$};
                my ($name) = $source =~ m{/([^/]+)$};
                $ok &&= $copy_if_present->($source, "$dir/$name") if $name;
            }
        }
    } elsif ($kind eq 'dv') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_dv_profile.json', "$dir/dv-profile-state.json");
        $ok &&= $copy_if_present->('/tmp/meter_lg_dv_profile.log', "$dir/dv-profile-log.txt");
        $ok &&= _write_artifact("$dir/dv-profile-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/dv-profile-state.json";
        my $measurements = ref($state) eq 'HASH'
            ? ($state->{measurements} || $state->{dv_profile_measurements}) : undef;
        $ok &&= _write_artifact("$dir/dv-profile-measurements.json", $measurements)
            if ref($measurements) eq 'HASH';
    }
    return $ok;
}

sub _snapshot_series {
    my ($item_number, $which, $key, $status) = @_;
    my $directory = PGAutomation::item_dir($RUN_ID, $item_number) . '/' . $which;
    if (!-d $directory && !eval { make_path($directory, { mode => 0775 }); 1 }) {
        $::LAST_ERROR = "Unable to create series artifact directory $directory";
        return undef;
    }
    my %snapshot;
    foreach my $field (qw(type points steps readings white_reading black_reading signal_mode target_gamma target_gamut calibration_target_context max_luma dv_map_mode color_format max_bpc signal_range pattern_signal_range transport_signal_range status report_key)) {
        $snapshot{$field} = $status->{$field} if exists($status->{$field});
    }
    $snapshot{type} = (_series_info($key))[0] if !exists($snapshot{type});
    $snapshot{points} = (_series_info($key))[1] if !exists($snapshot{points});
    $snapshot{steps} = [] if ref($snapshot{steps}) ne 'ARRAY';
    $snapshot{readings} = [] if ref($snapshot{readings}) ne 'ARRAY';
    my $context = _series_payload(_item_snapshot($ACTIVE_ITEM), $key, $RUN_ID);
    foreach my $field (qw(signal_mode target_gamma target_gamut max_luma dv_map_mode color_format max_bpc signal_range pattern_signal_range transport_signal_range)) {
        $snapshot{$field} = $context->{$field} if !defined($snapshot{$field});
    }
    $snapshot{status} = $status->{status} || 'error' if !defined($snapshot{status});
    $snapshot{report_key} = $key;
    return undef if !_write_artifact("$directory/$key.json", \%snapshot);
    return \%snapshot;
}

sub _run_series {
    my ($item_number, $item, $which) = @_;
    my @keys = _series_selection($item, $which);
    my $item_dir = PGAutomation::item_dir($RUN_ID, $item_number);
    make_path("$item_dir/$which", { mode => 0775 }) if !-d "$item_dir/$which";
    foreach my $key (@keys) {
        _refresh_control();
        return 0 if $STOP_REQUESTED;
        _log("launching meter worker series $key for $which readings");
        $ACTIVE_WORKER = 'series';
        ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE) = ($key, $which);
        _update_run(sub { $_[0]{active_series} = {key=>$key, phase=>$which}; });
        my $started = _api('POST', '/api/meter/series', _series_payload($item, $key, $RUN_ID));
        if (!$started || ($started->{status} || '') ne 'started') {
            $ACTIVE_WORKER = '';
            $::LAST_ERROR = $started->{message} || 'Unable to start meter series';
            return 0;
        }
        my $status = _wait_worker('/api/meter/series/status', "series $key", $item);
        if ($STOP_REQUESTED) {
            _log("meter worker series $key retained for stop cleanup");
            return 0;
        }
        return 0 if !ref($status);
        my $snapshot = _snapshot_series($item_number, $which, $key, $status);
        if (!ref($snapshot)) {
            $ACTIVE_WORKER = '';
            return 0;
        }
        if (($status->{status} || '') ne 'complete') {
            $::LAST_ERROR = _series_failure_message($key, $status);
            $::LAST_ERROR_CODE = $status->{error_code} || $status->{error} || 'meter-series-failed';
            return 0;
        }
        $ACTIVE_WORKER = '';
        _update_run(sub {
            my ($run) = @_;
            $run->{last_series} = { item => $item_number, phase => $which, key => $key };
        });
    }
    undef $ACTIVE_SERIES_KEY; undef $ACTIVE_SERIES_PHASE;
    return 1;
}

sub _series_failure_message {
    my ($key, $status) = @_;
    my $message = $status->{message} || $status->{current_name} || 'Worker returned ' . ($status->{status} || 'no status');
    my $step = defined($status->{current_step}) ? ' at patch ' . $status->{current_step}
        . ($status->{total_steps} ? '/' . $status->{total_steps} : '') : '';
    return "Series $key failed$step: $message"
        . ($status->{debug} ? ' Driver: ' . $status->{debug} : '');
}

sub _observed_settings {
    my ($response) = @_;
    return {} if ref($response) ne 'HASH';
    foreach my $key (qw(picture_settings settings)) {
        return $response->{$key} if ref($response->{$key}) eq 'HASH';
    }
    return {};
}

sub _mode_agrees {
    my ($expected, $observed) = @_;
    return 0 if !defined($expected) || $expected eq '' || !defined($observed) || $observed eq '';
    my $e = lc("$expected");
    my $o = lc("$observed");
    $e =~ s/[\s_-]+//g;
    $o =~ s/[\s_-]+//g;
    # Match the helper's TV wire aliases in both directions. Keep the Dolby
    # prefix so an SDR Filmmaker token can never verify a Dolby Vision mode.
    foreach my $mode ($e, $o) {
        $mode =~ s/^dolbyvision/dolbyhdr/;
        $mode = 'dolbyhdrcinema' if $mode =~ /^dolbyhdr(?:filmmaker(?:mode)?|cinemadark)$/;
        $mode = 'dolbyhdrcinemabright' if $mode eq 'dolbyhdrcinemahome';
        $mode = 'normal' if $mode eq 'standard';
    }
    return $e eq $o ? 1 : 0;
}

sub _signal_mode_compatible {
    my ($signal, $observed) = @_;
    return 0 if !defined($observed) || $observed eq '';
    my $mode = lc("$observed");
    $mode =~ s/[\s_-]+//g;
    return $mode !~ /^(?:hdr|dolby)/ if ($signal || '') eq 'sdr';
    return $mode =~ /^hdr/ if ($signal || '') eq 'hdr10' || ($signal || '') eq 'hlg';
    return $mode =~ /^dolby(?:vision|hdr)/ if ($signal || '') eq 'dv';
    return 0;
}

sub _tv_gamma_value {
    my ($value) = @_;
    return $value if !defined($value) || ref($value);
    my %aliases = ('1.9'=>'low', '2.2'=>'medium', '2.4'=>'high1', bt1886=>'high2', 'bt.1886'=>'high2');
    return $aliases{lc($value)} || $value;
}

sub _value_agrees {
    my ($expected, $observed, $key) = @_;
    return _mode_agrees($expected, $observed) if ($key || '') eq 'pictureMode';
    return 0 if !defined($observed);
    ($expected, $observed) = map { _tv_gamma_value($_) } ($expected, $observed) if ($key || '') eq 'gamma';
    if (!ref($expected) && !ref($observed) && "$expected" =~ /^-?\d+(?:\.\d+)?$/
        && "$observed" =~ /^-?\d+(?:\.\d+)?$/) {
        return abs(($expected + 0) - ($observed + 0)) <= 0.1;
    }
    return lc("$expected") eq lc("$observed") if !ref($expected) && !ref($observed);
    return PGAutomation::encode_json($expected) eq PGAutomation::encode_json($observed);
}

sub _append_setting_check {
    my ($item_number, $point, $record) = @_;
    my $path = PGAutomation::item_dir($RUN_ID, $item_number) . '/settings-checks.ndjson';
    $record->{checkpoint} = $point;
    $record->{timestamp} = time();
    return PGAutomation::append_line_locked($path, PGAutomation::encode_json($record) . "\n");
}

sub _best_available_manual {
    my ($item)=@_;
    my $plan=$item->{best_available_settings}||{};
    my $context=$plan->{context}||{};
    return {} if !$plan->{active} || !($plan->{capability_profile_hash}||'')
        || ($plan->{capability_profile_hash}||'') ne ($item->{capability_profile}{hash}||'')
        || ($context->{tv_input}||'') ne ($item->{tv_input}||'')
        || ($context->{picture_mode}||'') ne lc(_picture_mode($item))
        || ($context->{signal_mode}||'') ne _signal($item);
    return {} if ref($plan->{manual}) ne 'HASH';
    return {map {$_=>$plan->{manual}{$_}} grep {
        exists($item->{settings}{$_}) && _value_agrees($item->{settings}{$_},$plan->{manual}{$_}{value},$_)
    } keys %{$plan->{manual}}};
}

sub _item_settings {
    my ($item) = @_;
    my $settings = ref($item->{settings}) eq 'HASH' ? PGAutomation::clone($item->{settings}) : {};
    my $hazards = ref($item->{hazards}) eq 'ARRAY' ? $item->{hazards} : [];
    my $capabilities = ref($item->{hazard_capabilities}) eq 'HASH' ? $item->{hazard_capabilities} : {};
    foreach my $default_key (qw(energySaving aiPicture)) {
        my $capability = ref($capabilities->{$default_key}) eq 'HASH' ? $capabilities->{$default_key} : {};
        $settings->{$default_key} = 'off'
            if !exists($settings->{$default_key}) && $capability->{controllable} && $capability->{supported};
    }
    foreach my $hazard (@$hazards) {
        next if ref($hazard) ne 'HASH' || !$hazard->{controllable};
        next if !defined($hazard->{key}) || $hazard->{key} eq '';
        my $category = $hazard->{category} || 'picture';
        $item->{hazard_restore}{$hazard->{key}} = {
            value => $hazard->{value},
            category => $category,
        } if exists($hazard->{value}) && !exists($item->{hazard_restore}{$hazard->{key}});
        next if ($hazard->{key} eq 'energySaving' || $hazard->{key} eq 'aiPicture')
            && exists($settings->{$hazard->{key}});
        $settings->{$hazard->{key}} = $hazard->{disabled_value}
            if exists($hazard->{disabled_value});
    }
    delete @$settings{keys %{_best_available_manual($item)}};
    return $settings;
}

sub _setting_category {
    my ($item, $key) = @_;
    return 'picture' if !defined($key) || $key eq 'pictureMode';
    my $capabilities = ref($item->{hazard_capabilities}) eq 'HASH' ? $item->{hazard_capabilities} : {};
    return $capabilities->{$key}{category}
        if ref($capabilities->{$key}) eq 'HASH' && $capabilities->{$key}{category};
    foreach my $hazard (@{$item->{hazards} || []}) {
        next if ref($hazard) ne 'HASH' || ($hazard->{key} || '') ne $key;
        return $hazard->{category} || 'picture';
    }
    return 'picture';
}

sub _apply_one_setting {
    my ($item, $key, $value, $category, $calibration_active) = @_;
    $value = _tv_gamma_value($value) if $key eq 'gamma';
    $category = 'picture' if !defined($category) || $category eq '';
    my $result = _api('POST', '/api/lg/picture-settings/set', {
        settings => { $key => $value },
        readback_keys => [$key, 'pictureMode'],
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        signal_mode => _signal($item),
        category => $category,
        keep_calibration_mode => $calibration_active ? JSON::PP::true : JSON::PP::false,
        calibration_mode_active => $calibration_active ? JSON::PP::true : JSON::PP::false,
    });
    return $result;
}

sub _calibration_manages_setting {
    my ($item, $key, $point) = @_;
    if ($key eq 'gamma') {
        return 0 if _signal($item) ne 'sdr' || !_stages($item)->{calibration}
            || ($point || '') !~ /^(?:resume-)?c(?:6|7|8|9|10)(?:-(?:confirm|repair|stable|recovery))?$/;
        return 0 if (_tv_gamma_value($item->{settings}{$key}) || '') !~ /^(?:low|medium|high1|high2)$/;
        # Uploaded 1D LUT data bypasses LG's menu gamma. Only this job's
        # completed, verified upload owns it; a later reset invalidates that.
        # https://github.com/chros73/bscpylgtv (LUT uploads and greyed-out controls)
        my $grey;
        for my $record (@{$item->{checkpoints} || []}) {
            next if ref($record) ne 'HASH';
            $grey = undef if ($record->{name} || '') eq 'reset-and-reapply-verified';
            $grey = $record if ($record->{name} || '') eq 'greyscale-done';
        }
        return $grey && ($grey->{status} || '') eq 'done' && ($grey->{verified} // '') eq '1' ? 1 : 0;
    }
    return 0 if $key ne 'colorGamut' || ($point || '') !~ /^(?:resume-)?c(?:7|8|9|10)(?:-(?:confirm|repair|stable|recovery))?$/;
    return 0 if _signal($item) !~ /^(?:sdr|hdr10)$/ || !_stages($item)->{calibration};
    return 0 if ($item->{settings}{$key} || '') !~ /^(?:auto|native|wide|extended)$/i;
    # Only a committed 3D LUT owns the post-calibration gamut control. Never
    # waive baseline checks, failed uploads, or a later invalidated checkpoint.
    # LG LUT integration: https://lightillusion.com/lg_manual.html (LUT Upload).
    my ($commit) = reverse grep { ref($_) eq 'HASH' && ($_->{name} || '') eq 'volume-done' } @{$item->{checkpoints} || []};
    return $commit && ($commit->{status} || '') eq 'done' && ($commit->{verified} // '') eq '1' ? 1 : 0;
}

sub _read_and_verify_settings {
    my ($item_number, $item, $point) = @_;
    my $settings = _item_settings($item);
    my %expected = %$settings;
    $expected{pictureMode} = _picture_mode($item) if _picture_mode($item) ne '';
    my @keys = sort keys %expected;
    _log_action('Reading back picture mode and TV settings ('.$point.')');
    my %by_category;
    foreach my $key (@keys) {
        push @{$by_category{_setting_category($item, $key)}}, $key;
    }
    my %observed;
    my %meta;
    my @responses;
    foreach my $category (sort keys %by_category) {
        my $response = _api('POST', '/api/lg/picture-settings', {
            keys => $by_category{$category},
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => _signal($item),
            include_current_input => JSON::PP::true,
            category => $category,
        });
        if(($item->{tv_input}||'') ne '' && (ref($response) ne 'HASH' || ($response->{current_input}||'') ne $item->{tv_input})) {
            $response={status=>'error',error_code=>'lg-input-context-changed',message=>'The active LG input changed or could not be confirmed against job readiness.'};
        }
        push @responses, { category => $category, response => $response };
        my $category_observed = _observed_settings($response);
        foreach my $key (keys %$category_observed) {
            $observed{$key} = $category_observed->{$key};
        }
        my $unverifiable = ref($response) eq 'HASH' && ($response->{virtual_picture_settings}
            || $response->{manual_confirmation_required}
            || $response->{picture_mode_read_forbidden});
        my $unsupported = ref($response) eq 'HASH' && ref($response->{unsupported_picture_keys}) eq 'HASH'
            ? $response->{unsupported_picture_keys} : {};
        my %native=map {$_=>1} @{$response->{supported_picture_keys}||[]};
        foreach my $key (@{$by_category{$category}}) {
            $meta{$key} = {
                unverifiable => $unverifiable && !$native{$key} ? 1 : 0,
                unsupported => exists($unsupported->{$key}) ? 1 : 0,
                unavailable_reason => exists($unsupported->{$key}) ? $unsupported->{$key} : 'No value returned by TV',
                error => (ref($response) ne 'HASH' || ($response->{status} || '') eq 'error') ? 1 : 0,
                reason => ref($response) eq 'HASH' ? ($response->{message} || $response->{error} || '') : 'TV returned no settings response',
                error_code => ref($response) eq 'HASH' ? ($response->{error_code} || '') : '',
                contract => ref($response->{setting_contracts}) eq 'HASH' ? $response->{setting_contracts}{$key} : undef,
                mode_readback_unavailable => $key eq 'pictureMode' && $unverifiable
                    && $response->{generation_profile}{capability_library_valid}
                    && $response->{generation_profile}{capability_platform_profile_applied}
                    && exists($response->{generation_profile}{picturemode_readable})
                    && !$response->{generation_profile}{picturemode_readable},
            };
        }
    }
    my $response = @responses == 1 ? $responses[0]{response} : {
        status => (grep { ref($_->{response}) ne 'HASH' || ($_->{response}{status} || '') eq 'error' } @responses) ? 'error' : 'ok',
        responses => \@responses,
    };
    my $all = 1;
    my $any_unverifiable = 0;
    my @readback_warnings;
    my $hard_failure = 0;
    my $storage_failure = 0;
    my %values;
    my $mode_verified = _mode_agrees(_picture_mode($item), $observed{pictureMode})
        && !$meta{pictureMode}{error} && !$meta{pictureMode}{unverifiable} && !$meta{pictureMode}{unsupported};
    foreach my $key (@keys) {
        my $has = exists($observed{$key});
        my $ok = $has ? _value_agrees($expected{$key}, $observed{$key}, $key) : 0;
        my $meta = $meta{$key} || {};
        $ok = lg_setting_values_agree($meta->{contract}, $expected{$key}, $observed{$key})
            if $has && $key ne 'pictureMode' && ref($meta->{contract}) eq 'HASH';
        my $ack=$item->{best_available_write_ack}{$key};
        my $ack_missing=!$has && $meta->{contract}{allow_unverified_readback} && ref($ack) eq 'HASH'
            && lg_readback_unavailable_reason($meta->{unavailable_reason})
            && ($ack->{profile_hash}||'') eq ($item->{capability_profile}{hash}||'')
            && _value_agrees($expected{$key},$ack->{expected},$key);
        my $can_be_unverifiable = !$meta->{error} && ($meta->{unsupported} || $meta->{unverifiable} || $ack_missing);
        my $unverifiable_permitted=$meta->{mode_readback_unavailable} || $ack_missing;
        my $expected_transition = $mode_verified && $has && !$meta->{error} && !$can_be_unverifiable
            && _expected_calibration_gamut_state($item, $key, $point)
            && _lg_gamut_readback_warning($key, $expected{$key}, $observed{$key});
        my $managed = $expected_transition || ($mode_verified && $has && !$meta->{error} && !$can_be_unverifiable
            && _calibration_manages_setting($item, $key, $point)
            && defined($observed{$key}) && ($key eq 'gamma'
                ? _tv_gamma_value($observed{$key}) =~ /^(?:low|medium|high1|high2)$/
                : $observed{$key} =~ /^(?:auto|native|wide|extended)$/i));
        my $warning = !$managed && $mode_verified && !$meta->{error} && !$can_be_unverifiable
            && _lg_gamut_readback_warning($key, $expected{$key}, $observed{$key});
        my $warning_reason = 'Requested Auto; LG reported Wide. LG LUT/reset transitions can change or bypass the gamut menu. This is a warning, not a verified match or proof that Auto and Wide are equivalent; check the TV menu if needed.';
        $ok = 0 if $can_be_unverifiable || $meta->{error} || $managed;
        $values{$key} = {
            expected => $expected{$key},
            observed => $has ? $observed{$key} : undef,
            matched => $ok ? JSON::PP::true : JSON::PP::false,
            unverifiable => $can_be_unverifiable ? JSON::PP::true : JSON::PP::false,
            calibration_managed => $managed ? JSON::PP::true : JSON::PP::false,
            expected_calibration_state => $expected_transition ? JSON::PP::true : JSON::PP::false,
            readback_warning => $warning ? JSON::PP::true : JSON::PP::false,
            read_failed => $meta->{error} || !$has ? JSON::PP::true : JSON::PP::false,
            reason => $meta->{reason} || (!$has ? 'TV response omitted this setting' : ''),
        };
        $all = 0 if !$ok && !$managed;
        $any_unverifiable = 1 if $can_be_unverifiable || $warning;
        $hard_failure = 1 if !$ok && !$can_be_unverifiable && !$managed && !$warning;
        $hard_failure = 1 if $can_be_unverifiable && !$unverifiable_permitted;
        push @readback_warnings, $warning_reason if $warning;
        my $check_saved = _append_setting_check($item_number, $point, {
            key => $key,
            expected => $expected{$key},
            observed => $has ? $observed{$key} : undef,
            verified => $ok ? JSON::PP::true : JSON::PP::false,
            result => $expected_transition ? 'expected-calibration-state' : $managed ? 'lut-managed' : $warning ? 'readback-warning' : $ok ? 'verified' : ($can_be_unverifiable ? 'unverifiable' : 'mismatch'),
            category => _setting_category($item, $key),
            reason => $expected_transition ? 'Expected LG calibration state: Auto was requested for setup; the TV reports Wide after the completed 1D calibration and combined LUT baseline reset. This is retained as diagnostic evidence, not a settings warning or a claim that Auto and Wide are interchangeable. No gamut rewrite is required.'
                : $managed ? ($key eq 'gamma'
                    ? 'The verified 1D LUT controls gamma after calibration; the TV Gamma menu is bypassed. The requested menu value applies to setup, not the uploaded LUT curve.'
                    : 'The verified 3D LUT controls gamut after calibration; the TV gamut menu is bypassed. The requested value applies to the pre-calibration setup, not the uploaded LUT.')
                : $warning ? $warning_reason
                : $ok ? 'TV readback matches the requested value'
                : $meta->{error} ? ($meta->{reason} || 'TV settings read failed; no driver reason was returned')
                : $meta->{unsupported} ? 'This TV API does not support reading this setting; verify it in the TV menu'
                : $meta->{unverifiable} ? 'Readback is unavailable in this signal/picture mode; verify it in the TV menu'
                : !$has ? 'TV response omitted this setting; its value could not be verified'
                : 'TV-reported value differs from the requested value',
            error_code => $meta->{error_code},
            operation => 'readback',
            capability_profile_id => ref($meta->{contract}) eq 'HASH' ? $meta->{contract}{capability_profile_id} : undef,
            capability_profile_hash => ref($meta->{contract}) eq 'HASH' ? $meta->{contract}{capability_profile_hash} : undef,
        });
        $storage_failure = 1 if !$check_saved;
    }
    my $manual=_best_available_manual($item);
    for my $key (sort keys %$manual) {
        my $entry=$manual->{$key};
        $values{$key}={expected=>$entry->{value},observed=>undef,matched=>JSON::PP::false,
            unverifiable=>JSON::PP::true,manual_required=>JSON::PP::true,reason=>$entry->{message}};
        $storage_failure=1 if !_append_setting_check($item_number,$point,{
            key=>$key,expected=>$entry->{value},result=>'manual-required',verified=>JSON::PP::false,
            operation=>'manual',category=>'picture',reason=>$entry->{message},
        });
        $all=0;$any_unverifiable=1;
    }
    if ($storage_failure) {
        $::LAST_ERROR = 'Unable to persist LG settings verification evidence';
        $hard_failure = 1;
    }
    my $matched=grep { $values{$_}{matched} } @keys;
    my $managed=grep { $values{$_}{calibration_managed} } @keys;
    my $gamma_managed=$values{gamma} && $values{gamma}{calibration_managed} ? 1 : 0;
    my $expected_transitions=grep { $values{$_}{expected_calibration_state} } @keys;
    foreach my $warning (@readback_warnings) {
        _log_action('Warning: colorGamut: '.$warning.' ('.$point.')');
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, $warning if !grep { $_ eq $warning } @{$item->{warnings}};
    }
    _log_action('TV settings readback: '.$matched.'/'.scalar(@keys).' matched'
        .($gamma_managed ? '; TV Gamma controlled by the verified 1D LUT' : '')
        .($managed > $expected_transitions+$gamma_managed ? '; '.($managed-$expected_transitions-$gamma_managed).' controlled by the verified 3D LUT' : '')
        .($expected_transitions ? '; expected LG calibration state: Auto requested, Wide reported (no gamut rewrite needed)' : '')
        .($hard_failure ? '; mismatch or failed read - see setting checks' : $any_unverifiable ? '; warning: some controls cannot be verified - see setting checks' : '')
        .' ('.$point.')');
    return {
        verified => $storage_failure ? 0 : ($all ? 1 : ($any_unverifiable && !$hard_failure ? 'unverifiable' : 0)),
        values => \%values,
        response => $response,
        storage_failure => $storage_failure,
    };
}

sub _expected_calibration_gamut_state {
    my ($item, $key, $point) = @_;
    return 0 if $key ne 'colorGamut' || ($point || '') !~ /^(?:resume-)?c6(?:-(?:confirm|repair|stable|recovery))?$/;
    return 0 if _signal($item) !~ /^(?:sdr|hdr10)$/ || !_stages($item)->{calibration};
    return 0 if lc($item->{settings}{$key} || '') ne 'auto';
    # Our SDR/HDR reset stage includes BOTH the 1D and 3D baseline reset.
    # A completed, verified 1D stage after that reset can leave Auto reported
    # as Wide. This is a phase-specific state, not a global Auto/Wide alias.
    # In particular, isolated 1D workflows can retain normal gamut management:
    # https://lightillusion.com/lg_manual.html (LUT Upload).
    # Use the latest records so failed/superseded stages cannot grant a waiver.
    my ($reset, $grey);
    for my $record (@{$item->{checkpoints} || []}) {
        next if ref($record) ne 'HASH';
        if (($record->{name} || '') eq 'reset-and-reapply-verified') {
            $reset = $record;
            $grey = undef;
        } elsif (($record->{name} || '') eq 'greyscale-done') {
            $grey = $record;
        }
    }
    return 0 if !$reset || !$grey;
    return !grep { ($_->{status} || '') ne 'done' || ($_->{verified} // '') ne '1' } ($reset, $grey);
}

sub _lg_gamut_readback_warning {
    my ($key, $expected, $observed) = @_;
    # Deliberately not an alias in _value_agrees: these are distinct settings.
    # Only this known LG readback direction is non-blocking; missing values,
    # failed writes/reads and other gamut values retain their normal errors.
    return $key eq 'colorGamut' && defined($expected) && !ref($expected)
        && defined($observed) && !ref($observed)
        && lc($expected) eq 'auto' && lc($observed) eq 'wide';
}

sub _boundary_evidence {
    my ($item, $name) = @_;
    my ($record) = reverse grep { ($_->{name} || '') eq $name } @{$item->{checkpoints} || []};
    return {} if !$record || ($record->{status} || '') ne 'done';
    return $record->{evidence} || {};
}

sub _processing_setting {
    # Do not generalise this to luminance, gamma, gamut, white balance, input
    # or picture mode. Their effects cannot be bounded by a menu read alone.
    return ($_[0] || '') =~ /^(?:smoothGradation|noiseReduction|mpegNoiseReduction|superResolution|sharpness|realCinema)$/;
}

sub _settings_evidence_only_gamut_warning {
    my ($evidence) = @_;
    return 0 if ref($evidence) ne 'HASH' || ($evidence->{verified} || '') ne 'unverifiable';
    my $values = $evidence->{values};
    return 0 if ref($values) ne 'HASH' || ref($values->{pictureMode}) ne 'HASH' || !$values->{pictureMode}{matched};
    my $warning = 0;
    for my $key (keys %$values) {
        my $v = $values->{$key};
        return 0 if ref($v) ne 'HASH' || $v->{read_failed} || $v->{unverifiable};
        next if $v->{matched};
        return 0 if !$v->{readback_warning}
            || !_lg_gamut_readback_warning($key, $v->{expected}, $v->{observed});
        $warning = 1;
    }
    return $warning;
}

sub _settings_boundary_pause {
    my ($item, $point, $resume_from, $detail, $read_failure) = @_;
    my %next = (
        'greyscale-done' => 'repeat 1D calibration and the dependent profile/LUT stages',
        'volume-done' => 'repeat only the profile/LUT stage, retaining the verified 1D result',
        'greyscale-settings-verified' => 'retry the settings check after 1D calibration',
        'volume-settings-verified' => 'retry the settings check after profile/LUT upload',
        'session-closed' => 'retry calibration exit and its settings check',
    );
    my $message = "Settings review required at $point: $detail. Saved results are retained; no automatic recalibration. Resume will $next{$resume_from}.";
    $item->{settings_recovery} = {point=>$point, resume_from=>$resume_from, message=>$message, at=>time()};
    $::LAST_ERROR = $message;
    $::LAST_ERROR_CODE = $read_failure ? 'settings-readback-unavailable' : 'settings-review-required';
    _log_action($message);
    return 0;
}

sub _calibration_settings_boundary {
    my ($number, $item, $point, $before_exit) = @_;
    my %gates = (c6=>'greyscale-settings-verified', c7=>'volume-settings-verified', c8=>'session-closed');
    my $check = _read_and_verify_settings($number, $item, $point);
    my $summary = sub {
        my ($result, $mode) = @_;
        return _settings_boundary_pause($item, $point, $gates{$point},
            'Calibration mode could not be verified; no controls were rewritten', 1) if !defined($mode);
        return {verified=>$result->{verified}, values=>$result->{values}, point=>$point,
            checked_at=>time(), calibration_mode=>$mode};
    };
    my $mode_state = sub {
        my $s = _api('GET', '/api/lg/status', undef);
        return undef if ref($s) ne 'HASH' || ($s->{status} || '') ne 'ok' || $s->{disconnected}
            || !exists($s->{calibration_mode});
        return $s->{calibration_mode} ? 1 : 0;
    };
    return $summary->($check, $mode_state->()) if $check->{verified};
    _log_action("Settings differ at $point; confirming with a fresh read before changing anything");
    return 0 if !_sleep_controlled(1);
    my $confirmed = _read_and_verify_settings($number, $item, "$point-confirm");
    if ($confirmed->{verified}) {
        _log_action("Settings matched on confirmation at $point; no settings rewritten or calibration repeated");
        return $summary->($confirmed, $mode_state->());
    }
    my @keys = sort grep {
        my $v = $confirmed->{values}{$_};
        !$v->{matched} && !$v->{unverifiable} && !$v->{calibration_managed} && !$v->{readback_warning}
    } keys %{$confirmed->{values} || {}};
    my $reason = _settings_failure_message($point, $confirmed, 1);
    my $unreadable = $confirmed->{storage_failure} || !@keys
        || grep { $confirmed->{values}{$_}{read_failed} } @keys;
    if ($unreadable) {
        my @details = grep { $_ } map { $confirmed->{values}{$_}{reason} } @keys;
        return _settings_boundary_pause($item, $point, $gates{$point},
            $reason.(@details ? '; '.join('; ', @details) : '; settings evidence could not be verified'), 1);
    }
    my $processing_only = !grep { !_processing_setting($_) } @keys;
    my $grey = _boundary_evidence($item, 'greyscale-settings-verified');
    my $grey_clean = (($grey->{verified} || '') eq '1' || _settings_evidence_only_gamut_warning($grey))
        && !grep { !$grey->{values}{$_}{matched} } @keys;
    my $resume_from = $point ne 'c6' && $processing_only && $grey_clean ? 'volume-done' : 'greyscale-done';
    my $mode = $mode_state->();
    my $stable_mismatch = !grep {
        my $v = $check->{values}{$_} || {};
        $v->{read_failed} || $v->{unverifiable} || !defined($v->{observed})
            || !_value_agrees($v->{observed}, $confirmed->{values}{$_}{observed}, $_)
    } @keys;
    if (!$stable_mismatch || !defined($mode) || !$confirmed->{values}{pictureMode}{matched}) {
        return _settings_boundary_pause($item, $point, $resume_from,
            "$reason; settings or calibration/picture mode are unstable or unconfirmed, so no controls were rewritten", 0);
    }
    # Only a fresh, successful check immediately before CAL_END can establish
    # an exit-only processing change. Historical checkpoints cannot authorise
    # retaining measurements after a restart. Other changes require review.
    my $exit_only = $point eq 'c8' && $processing_only && $mode == 0
        && (_boundary_evidence($item, 'volume-done')->{verified} || '') eq '1'
        && ref($before_exit) eq 'HASH' && ($before_exit->{verified} || '') eq '1'
        && defined($before_exit->{calibration_mode}) && $before_exit->{calibration_mode} == 1
        && !grep { !$before_exit->{values}{$_}{matched}
            || !_value_agrees($before_exit->{values}{$_}{expected}, $confirmed->{values}{$_}{expected}, $_) } @keys;
    # DV's upload helper always sends CAL_END itself. A fresh check made after
    # profiling and immediately before that upload isolates this transition:
    # processing changes happened AFTER the measured profile, not during it.
    # This proof is passed from the just-executed stage, never loaded on Resume.
    my $upload_only = $point eq 'c7' && _signal($item) eq 'dv' && $processing_only && $mode == 0
        && (_boundary_evidence($item, 'volume-done')->{verified} || '') eq '1'
        && ref($before_exit) eq 'HASH' && ($before_exit->{transition} || '') eq 'dv-profile-upload'
        && ($before_exit->{verified} || '') eq '1'
        && defined($before_exit->{calibration_mode})
        && !grep { !$before_exit->{values}{$_}{matched}
            || !_value_agrees($before_exit->{values}{$_}{expected}, $confirmed->{values}{$_}{expected}, $_) } @keys;
    _log_action("Confirmed settings change at $point: $reason; restoring only ".join(', ', @keys));
    foreach my $key (@keys) {
        my $value = $confirmed->{values}{$key}{expected};
        my $result = _apply_one_setting($item, $key, $value, _setting_category($item, $key), $mode);
        my $accepted = ref($result) eq 'HASH' && ($result->{status} || '') =~ /^(?:ok|started)$/;
        return _settings_boundary_pause($item, $point, $resume_from, 'Unable to save setting-repair evidence', 1)
            if !_append_setting_check($number, "$point-repair", {key=>$key, expected=>$value,
                operation=>'write', result=>$accepted ? 'applied' : 'apply-failed', verified=>JSON::PP::false,
                reason=>$accepted ? 'Targeted restoration; awaiting fresh readback' : ($result->{message} || 'TV rejected setting repair')});
        return _settings_boundary_pause($item, $point, $resume_from,
            "Could not restore $key: ".($result->{message} || 'TV rejected setting repair'), 0) if !$accepted;
    }
    my $restored = _read_and_verify_settings($number, $item, "$point-repair");
    return 0 if !_sleep_controlled(1);
    my $stable = _read_and_verify_settings($number, $item, "$point-stable");
    if (!$restored->{verified} || !$stable->{verified}) {
        return _settings_boundary_pause($item, $point, $resume_from,
            _settings_failure_message("$point-stable", $stable->{verified} ? $restored : $stable, 1).'; repaired settings did not remain verified', 0);
    }
    my $after_mode = $mode_state->();
    return _settings_boundary_pause($item, $point, $resume_from,
        'Calibration mode changed or became unverified during setting repair', 0)
        if !defined($after_mode) || $after_mode != $mode;
    if (($exit_only || $upload_only) && ($restored->{verified} || '') eq '1' && ($stable->{verified} || '') eq '1') {
        my $message = $upload_only
            ? 'Restored after Dolby Vision profile upload: '.join(', ', @keys).'; settings matched after measurement and immediately before upload, calibration results retained'
            : 'Restored after calibration exit: '.join(', ', @keys).'; pre-exit settings verified, calibration results retained';
        _log_action($message);
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, $message if !grep { $_ eq $message } @{$item->{warnings}};
        return {%{$summary->($stable, 0)}, recovery=>$upload_only ? 'upload-only-restored' : 'exit-only-restored', repaired_keys=>\@keys};
    }
    return _settings_boundary_pause($item, $point, $resume_from,
        "$reason; requested settings restored, but their effect on measurements is not established", 0);
}

sub _select_item_picture_mode {
    my ($item_number,$item,$point)=@_;
    return 1 if _picture_mode($item) eq '';
    _log_action('Selecting '.uc(_signal($item)).' picture mode '._picture_mode($item));
    my $result=_apply_one_setting($item,'pictureMode',_picture_mode($item),'picture');
    if (!$result || (($result->{status}||'') ne 'ok' && ($result->{status}||'') ne 'started')) {
        $::LAST_ERROR=$result->{message}||'Unable to select LG picture mode';
        _append_setting_check($item_number,$point,{key=>'pictureMode',expected=>_picture_mode($item),result=>'apply-failed',operation=>'write',reason=>$::LAST_ERROR,error_code=>$result->{error_code}});
        return 0;
    }
    my $settle=0+($item->{settle_seconds}//8);
    _log_action('Picture-mode write accepted; allowing '.$settle.' s to settle before settings') if $settle>0;
    return 0 if !_sleep_controlled($settle);
    # Confirm the mode BEFORE any of this job's control writes. A successful
    # mode write alone does not establish which picture mode is now active.
    my $check_item = {%$item, settings=>{}, hazards=>[], hazard_capabilities=>{}};
    my $check = _read_and_verify_settings($item_number, $check_item, $point.'-mode');
    if (!$check->{verified}) {
        $::LAST_ERROR = _settings_failure_message($point.'-mode', $check, 1);
        return 0;
    }
    _log_action($check->{verified} eq 'unverifiable'
        ? 'Warning: picture-mode readback unavailable; proceeding with accepted mode write, not a verified mode'
        : 'Picture mode confirmed: '._picture_mode($item).'; queued settings can now be applied');
    return 1;
}

sub _apply_and_verify {
    my ($item_number, $item, $point, $mode_selected, $calibration_active) = @_;
    return 0 if !_verify_live_capability_profile($item);
    my $settings = _item_settings($item);
    my @keys = sort grep { !_calibration_manages_setting($item, $_, $point)
        && !_expected_calibration_gamut_state($item, $_, $point) } keys %$settings;
    _log_action('Leaving LUT-managed picture controls unchanged during settings recovery') if @keys < keys %$settings;
    my $last;
    for my $cycle (1..3) {
        _log_action('Retrying TV settings after readback mismatch (attempt '.$cycle.'/3)') if $cycle>1;
        return 0 if (!$mode_selected || $cycle>1) && !_select_item_picture_mode($item_number,$item,$point);
        _log_action('Applying '.scalar(@keys).' queued TV settings to '._picture_mode($item)) if @keys;
        my $applied=0;
        my $next_setting_log=time()+15;
        foreach my $key (@keys) {
            delete $item->{best_available_write_ack}{$key};
            my $category = _setting_category($item, $key);
            my $result = _apply_one_setting($item, $key, $settings->{$key}, $category, $calibration_active);
            if (!$result || (($result->{status} || '') ne 'ok' && ($result->{status} || '') ne 'started')) {
                _append_setting_check($item_number, $point, {key=>$key, category=>$category, expected=>$settings->{$key}, result=>'apply-failed', operation=>'write', reason=>$result->{message} || 'TV did not accept the setting write', error_code=>$result->{error_code}});
                $::LAST_ERROR = $result->{message} || "Unable to set LG picture key $key";
                return 0;
            }
            if (exists($result->{verification_state}) && ($result->{verification_state} || '') ne 'verified') {
                my $reason = $result->{message} || "LG accepted $key but did not return a verified readback";
                my $saved=_append_setting_check($item_number, $point, {
                    key=>$key, category=>$category, expected=>$settings->{$key}, result=>'unverified',
                    operation=>'write', reason=>$reason, verification_state=>$result->{verification_state}||'unknown',
                    setting_verification=>$result->{setting_verification},
                });
                if(!$saved) {
                    $::LAST_ERROR='Unable to persist LG write acknowledgement evidence';
                    return 0;
                }
                if(lg_setting_write_accepted($result,$key,$settings->{$key})) {
                    $item->{best_available_write_ack}{$key}={expected=>$settings->{$key},profile_hash=>$item->{capability_profile}{hash}||''};
                    _log_action("Warning: $key write accepted without readback under the TV matrix; not verified");
                    push @{$item->{warnings}},"$key write accepted without readback; verify in the TV menu"
                        if !grep {$_ eq "$key write accepted without readback; verify in the TV menu"} @{$item->{warnings}||[]};
                } else {
                    $::LAST_ERROR = $reason;
                    return 0;
                }
            }
            $applied++;
            if (time()>=$next_setting_log && $applied<@keys) {
                _log_action('Applied '.$applied.'/'.scalar(@keys).' TV settings; last control: '.$key);
                $next_setting_log=time()+15;
            }
        }
        $last = _read_and_verify_settings($item_number, $item, $point);
        if ($last->{verified}) {
            return $last->{verified};
        }
    }
    $::LAST_ERROR = _settings_failure_message($point, $last);
    return 0;
}

sub _settings_failure_message {
    my ($point, $last, $single_read) = @_;
    my @mismatches;
    foreach my $key (sort keys %{$last->{values} || {}}) {
        my $value = $last->{values}{$key};
        next if $value->{matched} || $value->{unverifiable} || $value->{calibration_managed} || $value->{readback_warning};
        my @text = map { !defined($_) ? '(not returned)' : ref($_) ? PGAutomation::encode_json($_) : "$_" }
            @{$value}{qw(expected observed)};
        push @mismatches, "$key: requested $text[0], TV reported $text[1]";
    }
    return "LG settings did not verify at $point" . ($single_read ? '' : ' after three cycles')
        . (@mismatches ? ': ' . join('; ', @mismatches) : ' (TV readback unavailable)');
}

sub _apply_signal {
    my ($item) = @_;
    my $signal = _signal($item);
    _log_action('Switching generator output to '.uc($signal));
    my $config = {
        signal_mode => $signal,
        requested_signal_mode => $signal,
        eotf => $signal eq 'sdr' ? '0' : $signal eq 'hlg' ? '3' : '2',
        primaries => $signal eq 'sdr' ? '0' : $signal eq 'dv' ? '1' : '2',
        colorimetry => $signal eq 'sdr' ? '2' : '9',
    };
    $config->{dv_map_mode} = $item->{dv_map_mode} || '1' if $signal eq 'dv';
    foreach my $key (qw(color_format rgb_quant_range max_bpc eotf primaries colorimetry)) {
        $config->{$key} = $item->{$key} if exists($item->{$key}) && defined($item->{$key});
    }
    my $result = _api('POST', '/api/config', $config);
    if (!$result || ($result->{status} || '') ne 'ok') {
        $::LAST_ERROR = $result->{message} || 'Unable to apply signal format';
        return 0;
    }
    my $deadline = time() + 35;
    my $pattern_sent = 0;
    my $pattern_announced = 0;
    _log_action('Output change accepted; waiting for renderer and TV signal detection (up to 35 s)');
    while (time() < $deadline) {
        my $ping = _api('GET', '/api/ping', undef);
        my $config = _api('GET', '/api/config', undef);
        my $reported = lc($config->{signal_mode} || '');
        if (_ping_ok($ping) && ($reported eq $signal || $signal eq 'hdr10' && $reported eq 'hdr')) {
            if (!$pattern_sent) {
                _log_action('Displaying a neutral grey pattern for TV signal detection') if !$pattern_announced++;
                my $pattern = _api('POST', '/api/pattern', {
                    name => 'gray50',
                    signal_mode => $signal,
                    max_luma => $item->{max_luma} || 1000,
                });
                $pattern_sent = 1 if ($pattern->{status} || '') eq 'ok';
            }
            if ($pattern_sent && _picture_mode($item) ne '') {
                my $tv = _api('POST', '/api/lg/picture-settings', {
                    keys => ['pictureMode'],
                    picture_mode => _picture_mode($item),
                    tv_input => $item->{tv_input}||'',
                    signal_mode => $signal,
                    include_current_input => JSON::PP::true,
                    category => 'picture',
                }, 0, 0);
                my $observed = _observed_settings($tv);
                if (ref($observed) eq 'HASH' && _signal_mode_compatible($signal, $observed->{pictureMode})) {
                    _log_action('TV signal path ready; reported picture mode '.$observed->{pictureMode});
                    return 1;
                }
            } elsif ($pattern_sent) {
                _log_action('Generator signal ready');
                return 1;
            }
        }
        _sleep_controlled(2) or return 0;
    }
    $::LAST_ERROR = 'Renderer did not settle on the queued signal format';
    return 0;
}

sub _set_dv_map {
    my ($item, $mode) = @_;
    return 1 if _signal($item) ne 'dv';
    my $current = _api('GET', '/api/config', undef);
    return 1 if "$current->{dv_map_mode}" eq "$mode";
    _log_action('Switching Dolby Vision map to '.($mode eq '1'?'Absolute':'Relative'));
    my $result = _api('POST', '/api/config', { dv_map_mode => "$mode", signal_mode => 'dv' });
    return 0 if !$result || ($result->{status} || '') ne 'ok';
    my $deadline = time() + 30;
    while (time() < $deadline) {
        my $ping = _api('GET', '/api/ping', undef);
        my $config = _api('GET', '/api/config', undef);
        if (_ping_ok($ping) && "$config->{dv_map_mode}" eq "$mode") {
            my $pattern = _api('POST', '/api/pattern', {
                name => 'gray50',
                signal_mode => 'dv',
                max_luma => $item->{max_luma} || 1000,
            });
            if (($pattern->{status} || '') eq 'ok') {
                # A renderer ping proves the Pi is ready, not that the TV has
                # reacquired Dolby Vision after the HDMI restart. Keep this
                # short transition wait cancellable; it is not panel warm-up.
                _log_action('Dolby Vision output restored; allowing 8 s for TV signal acquisition');
                return 0 if !_sleep_controlled(8);
                _log_action('Dolby Vision map ready');
                return 1;
            }
        }
        _sleep_controlled(1) or return 0;
    }
    return 0;
}

sub _begin_run {
    my ($item) = @_;
    my $result = _api('POST', '/api/lg/autocal/run/begin', {
        workflow => 'automation',
        controller_id => 'automation-runner',
        client_run_token => $TOKEN,
        config => {
            signal_mode => _signal($item),
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            target_gamma => $item->{target_gamma} || '',
            target_gamut => $item->{target_gamut} || '',
            luminance_target => $item->{target_luminance} || undef,
        },
    });
    return $result;
}

sub _verify_live_capability_profile {
    my ($item) = @_;
    my $expected = ref($item->{capability_profile}) eq 'HASH'
        ? ($item->{capability_profile}{hash} || '') : '';
    $expected ||= ref($item->{generation_profile}) eq 'HASH'
        ? ($item->{generation_profile}{capability_profile_hash} || '') : '';
    # Legacy manifests have no signature to compare. New readiness always
    # supplies one; an absent live signature must not waive its protection.
    if($expected eq '') {
        return 1 if !_stages($item)->{calibration};
        $::LAST_ERROR='Calibration has no frozen LG compatibility signature. Run job readiness before changing TV calibration data.';
        return 0;
    }
    if(_stages($item)->{calibration} && ($item->{tv_input}||'') !~ /^hdmi[1-4](?:_pc)?$/) {
        $::LAST_ERROR='Calibration has no confirmed HDMI input. Run job readiness before changing TV calibration data.';
        return 0;
    }
    my $live = _api('POST', '/api/lg/picture-settings', {
        keys => ['pictureMode'], picture_mode => _picture_mode($item),
        signal_mode => _signal($item), include_current_input => JSON::PP::true,
        tv_input => $item->{tv_input}||'',
    });
    my $actual = ref($live) eq 'HASH' && ref($live->{generation_profile}) eq 'HASH'
        ? ($live->{generation_profile}{capability_profile_hash} || '') : '';
    if (ref($live) ne 'HASH' || ($live->{status} || '') ne 'ok' || $actual eq '' || $actual ne $expected
        || (($item->{tv_input}||'') ne '' && ($live->{current_input}||'') ne $item->{tv_input})) {
        $::LAST_ERROR = 'The LG compatibility signature changed or could not be confirmed after readiness. Refresh readiness before changing TV settings or calibration data.';
        _log_action($::LAST_ERROR);
        return 0;
    }
    return 1;
}

sub _reset_for_calibration {
    my ($item_number, $item) = @_;
    return 0 if !_verify_live_capability_profile($item);
    my $signal = _signal($item);
    my $mode = _picture_mode($item);
    _log_action('Opening TV calibration session for '.$mode);
    my $begin = _begin_run($item);
    if (!$begin || (($begin->{status} || '') ne 'ok' && ($begin->{status} || '') ne 'started')) {
        $::LAST_ERROR = $begin->{message} || 'Unable to begin the LG automation run';
        return 0;
    }
    _update_run(sub { $_[0]{lg_run_id} = $begin->{run_id} if $begin->{run_id}; });
    my @responses;
    if ($signal eq 'sdr') {
        _log_action('Resetting SDR picture mode and white balance; existing calibration will be replaced');
        my $picture = _api('POST', '/api/lg/picture-settings/reset', {
            picture_mode => $mode,
            signal_mode => 'sdr',
            require_white_balance_reset => JSON::PP::true,
            helper_timeout => 170,
        });
        push @responses, { picture_reset => $picture };
        if (!$picture || ($picture->{status} || '') ne 'ok') {
            $::LAST_ERROR = $picture->{message} || 'Unable to reset the LG picture mode';
            return 0;
        }
        my $slots = [ (0) x 22 ];
        _log_action('Picture reset complete; resetting the SDR greyscale controls');
        my $ddc = _api('POST', '/api/lg/picture-settings/set', {
            settings => {
                whiteBalanceMethod => '22',
                whiteBalanceIre => '109',
                ddc_layout => 'sdr26',
                whiteBalanceRed => $slots,
                whiteBalanceGreen => $slots,
                whiteBalanceBlue => $slots,
                adjustingLuminance => $slots,
            },
            picture_mode => $mode,
            signal_mode => 'sdr',
            reset_ddc_baseline => JSON::PP::true,
            force_ddc_white_balance => JSON::PP::true,
            lg_autocal_sdr_1d_dpg_upload_enabled => JSON::PP::true,
            readback_keys => [qw(whiteBalanceMethod whiteBalanceIre adjustingLuminance)],
        });
        push @responses, { ddc_reset => $ddc };
        if (!$ddc || ($ddc->{status} || '') ne 'ok') {
            $::LAST_ERROR = $ddc->{message} || 'Unable to reset the SDR DDC baseline';
            return 0;
        }
        _log_action('Resetting the SDR calibration baseline');
        my $reference = _api('POST', '/api/lg/sdr-calman-reset', {
            picture_mode => $mode,
            action => 'sdr_calman_reset',
            ddc_layout => 'sdr26',
            helper_timeout => 170,
        });
        push @responses, { sdr_calman_reset => $reference };
        if (!$reference || ($reference->{status} || '') ne 'ok') {
            $::LAST_ERROR = $reference->{message} || 'Unable to complete the SDR calibration reset';
            return 0;
        }
    } else {
        _log_action('Resetting '.uc($signal).' calibration for '.$mode);
        my $endpoint = $signal eq 'dv' ? '/api/lg/dv-calman-reset' : '/api/lg/hdr-calman-reset';
        my $reset = _api('POST', $endpoint, {
            picture_mode => $mode,
            signal_mode => $signal,
            action => $signal eq 'dv' ? 'dv_calman_reset' : 'hdr_calman_reset',
            ddc_layout => 'hdr20',
            helper_timeout => 170,
        });
        push @responses, { hdr_calman_reset => $reset };
        if (!$reset || ($reset->{status} || '') ne 'ok') {
            $::LAST_ERROR = $reset->{message} || 'Unable to complete the HDR calibration reset';
            return 0;
        }
    }
    if ($signal ne 'dv') {
        _log_action('Resetting the 3D LUT baseline');
        my $lut = _api('POST', '/api/lg/3d-lut/reset', {
            picture_mode => $mode,
            signal_mode => $signal,
            upload_command => $signal eq 'hdr10' ? 'BT2020_3D_LUT_DATA' : '',
            get_command => $signal eq 'hdr10' ? 'GET_3D_LUT_DATA' : '',
            keep_calibration_mode => JSON::PP::false,
            calibration_mode_active => JSON::PP::false,
            helper_timeout => 220,
        });
        push @responses, { lut_reset => $lut };
        if (!$lut || ($lut->{status} || '') ne 'ok') {
            $::LAST_ERROR = $lut->{message} || 'Unable to reset the LG 3D LUT baseline';
            return 0;
        }
    }
    # Carry the exact TV signature selected by the reset helper into the
    # worker. The 3D worker resolves payload geometry from this data and will
    # fail closed if it is absent or unknown.
    my $preflight_profile_hash = ref($item->{capability_profile}) eq 'HASH'
        ? ($item->{capability_profile}{hash} || '') : '';
    $preflight_profile_hash ||= ref($item->{generation_profile}) eq 'HASH'
        ? ($item->{generation_profile}{capability_profile_hash} || '') : '';
    foreach my $envelope (reverse @responses) {
        next if ref($envelope) ne 'HASH';
        foreach my $response (values %$envelope) {
            next if ref($response) ne 'HASH';
            my $live_profile_hash = ref($response->{generation_profile}) eq 'HASH'
                ? ($response->{generation_profile}{capability_profile_hash} || '') : '';
            if ($preflight_profile_hash ne '' && $live_profile_hash ne ''
                && $preflight_profile_hash ne $live_profile_hash) {
                $::LAST_ERROR = 'The connected LG TV or firmware changed during calibration reset; calibration was stopped before measurement and generated LUT upload.';
                _log_action($::LAST_ERROR);
                return 0;
            }
            $item->{lg_generation} = $response->{lg_generation}
                if ref($response->{lg_generation}) eq 'HASH';
            $item->{generation_profile} = $response->{generation_profile}
                if ref($response->{generation_profile}) eq 'HASH';
        }
    }
    _log_action('Calibration resets complete; queued TV settings will be reapplied next');
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/reset.json', {
        completed_at => time(),
        responses => \@responses,
        lg_generation => $item->{lg_generation},
        generation_profile => $item->{generation_profile},
        calibration_session_unconfirmed => scalar(grep {
            my $response = $_;
            grep { ref($_) eq 'HASH' && $_->{calibration_session_unconfirmed} } values %$response
        } @responses) ? JSON::PP::true : JSON::PP::false,
    });
    return 1;
}

sub _setup_white_error {
    ($::LAST_ERROR) = @_;
    _log_action($::LAST_ERROR);
    return undef;
}

sub _read_white {
    my ($item) = @_;
    $::LAST_ERROR = '';
    my $range = _default_range($item);
    my $max_bpc = $item->{max_bpc} || 10;
    my $code = _grey_code('sdr', 100, $range, $max_bpc);
    _log_action('Displaying 100% white and preparing the meter for setup luminance');
    my $pattern = _api('POST', '/api/pattern', {
        name => 'patch',
        r => $code, g => $code, b => $code,
        input_max => $max_bpc == 12 ? 4095 : $max_bpc >= 10 ? 1023 : 255,
        size => int($item->{patch_size} || 10),
        signal_mode => 'sdr',
        signal_range => $range,
    });
    if (!$pattern || ($pattern->{status} || '') ne 'ok') {
        return _setup_white_error('Setup white pattern failed: '.($pattern->{message}||$pattern->{status}||'no response'));
    }
    my $read_started = time();
    my $request_id = sprintf('automation-white-%d-%.0f-%d', $$, int($read_started*1000), ++$SETUP_WHITE_SEQUENCE);
    my $read = _api('POST', '/api/meter/read', {
        _measurement_options($item),
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        refresh_rate => $item->{refresh_rate} || '',
        name => 'panel-light-white',
        patch_name => 'panel-light-white',
        patch_r => $code, patch_g => $code, patch_b => $code,
        ire => 100,
        request_id => $request_id,
        input_max => $max_bpc == 12 ? 4095 : $max_bpc >= 10 ? 1023 : 255,
        size => int($item->{patch_size} || 10),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => 'sdr',
        signal_range => $range,
        transport_signal_range => $range,
        delay_ms => int($item->{delay_ms} // 1000),
    });
    if (!$read || (($read->{status} || '') ne 'measuring' && ($read->{status} || '') ne 'starting' && ($read->{status} || '') ne 'ok')) {
        return _setup_white_error('Setup white measurement was not accepted: '.($read->{message}||$read->{status}||'no response'));
    }
    _log_action('Meter request accepted; waiting for the setup white reading');
    my $deadline = time() + 240;
    my $wait_started=time();
    my $last_wait_log;
    my $stale_logged = 0;
    while (time() < $deadline) {
        my $result = _api('GET', '/api/meter/read/result', undef);
        my $state = lc($result->{status} || '');
        if ($state eq 'complete' || $state eq 'ok') {
            # The meter returns an envelope containing readings, not a reading
            # itself. Match the physical request before using its luminance.
            return _setup_white_error('Setup white response has no reading (status '.$state.')')
                if ref($result->{readings}) ne 'ARRAY' || ref($result->{readings}[0]) ne 'HASH';
            my $reading = $result->{readings}[0];
            my $stamp = $reading->{timestamp};
            my $stale = ($result->{request_id} || '') ne $request_id
                || (($reading->{request_id} || '') ne '' && $reading->{request_id} ne $request_id)
                || (defined($stamp) && "$stamp" =~ /^\d+(?:\.\d+)?$/ && $stamp > 0 && $stamp+1 < $read_started);
            if (!$stale) {
                foreach my $key (qw(r_code g_code b_code)) {
                    return _setup_white_error('Setup white response reports a different patch; luminance was not used')
                        if exists($reading->{$key}) && (!defined($reading->{$key}) || "$reading->{$key}" !~ /^\d+$/ || $reading->{$key} != $code);
                }
                my $luma = _luminance($reading);
                return _setup_white_error('Setup white response has no luminance value') if !defined($luma);
                return _setup_white_error('Setup white luminance must be positive; meter reported '.$luma.' cd/m2') if $luma <= 0;
                _log_action(sprintf('Setup white reading: %.2f cd/m2', $luma));
                return $reading;
            }
            _log_action('Ignoring an older or mismatched meter result; waiting for this setup white reading') if !$stale_logged++;
        } elsif ($state eq 'error' || $state eq 'cancelled') {
            return _setup_white_error('Setup white measurement '.$state.': '.($result->{message}||$result->{error_code}||'no reason returned'))
                if !($result->{request_id} || '') || $result->{request_id} eq $request_id;
        }
        _log_wait('the setup white reading',$wait_started,\$last_wait_log);
        _sleep_controlled(1) or return undef;
    }
    return _setup_white_error('Setup white measurement timed out after 240 s without a matching reading');
}

sub _luminance {
    my ($reading) = @_;
    return undef if ref($reading) ne 'HASH';
    foreach my $key (qw(luminance Y luminance_nits Y_nits white_luminance)) {
        return 0 + $reading->{$key} if defined($reading->{$key}) && "$reading->{$key}" =~ /^-?\d+(?:\.\d+)?$/;
    }
    foreach my $key (qw(reading result data)) {
        my $nested = $reading->{$key};
        my $value = _luminance($nested);
        return $value if defined($value);
    }
    return undef;
}

sub _panel_light_key {
    my ($item) = @_;
    return $item->{panel_light_key} if $item->{panel_light_key};
    my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
    return $panel->{key} if $panel->{key};
    my $settings = ref($item->{settings}) eq 'HASH' ? $item->{settings} : {};
    foreach my $key (qw(oledPixelBrightness oledLight backlight)) {
        return $key if exists($settings->{$key});
    }
    return '';
}

sub _record_setup_luminance {
    my ($item,$luminance) = @_;
    return 0 if !defined($luminance) || $luminance <= 0;
    my $cal = $item->{calibration} ||= {};
    my $setup = $luminance < 10 ? 10 : $luminance > 10000 ? 10000 : $luminance;
    my $gamma = $cal->{target_gamma} || $item->{target_gamma} || 'bt1886';
    my $headroom = _default_range($item) eq '1' && ($item->{color_format} || '0') =~ /^(?:1|2)$/;
    my $fraction = $headroom ? (($item->{max_bpc} || 10) == 8 ? 239/219 : 959/876) : 1;
    my $ratio = $gamma eq 'srgb' ? (($fraction+0.055)/1.055)**2.4 : $fraction**($gamma eq '2.2' ? 2.2 : 2.4);
    $cal->{setup_luminance_reference} = $setup;
    $cal->{target_luminance} = $setup;
    $cal->{headroom_target_luminance} = $setup * $ratio;
    $item->{target_luminance} = $setup;
    return 1;
}

sub _panel_light_stage {
    my ($item_number, $item) = @_;
    my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
    my $policy = lc($panel->{policy} || $item->{panel_light_policy} || 'fixed');
    my $key = _panel_light_key($item);
    if ($policy ne 'target') {
        my $verified = _apply_and_verify($item_number, $item, 'c5');
        return 0 if !$verified && $verified ne 'unverifiable';
        my ($reading,$luminance);
        if (_signal($item) eq 'sdr') {
            _sleep_controlled(2) or return 0;
            $reading = _read_white($item);
            $luminance = _luminance($reading);
            if (!_record_setup_luminance($item,$luminance)) {
                $::LAST_ERROR ||= 'Fixed panel light did not produce a valid setup white measurement';
                return 0;
            }
        }
        return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json', {
            policy => 'fixed',
            key => $key,
            value => $key && ref($item->{settings}) eq 'HASH' ? $item->{settings}{$key} : undef,
            verified => $verified,
            setup_white_reading => $reading,
            setup_white_luminance => $luminance,
            completed_at => time(),
        });
        return _update_item_snapshot($item_number,$item);
    }
    if (!$key) {
        $::LAST_ERROR = 'Target panel-light policy requires a supported LG panel-light setting';
        return 0;
    }
    my $target = 0 + ($panel->{target_luminance} || $item->{target_luminance} || 100);
    $item->{settings} = {} if ref($item->{settings}) ne 'HASH';
    my $observed = _observed_settings(_api('POST', '/api/lg/picture-settings', {
        keys => [$key], picture_mode => _picture_mode($item), signal_mode => _signal($item),
    }));
    my $start = $item->{settings}{$key} // $panel->{initial_value} // $observed->{$key};
    my $start_assumed = 0;
    if (!defined($start) || $start !~ /^-?\d+(?:\.\d+)?$/) {
        # Some sets refuse to read the panel-light key while still accepting
        # writes. The loop converges from any start, so assume mid-range, but
        # record that the starting value was never read from the TV.
        _log("panel-light start value for $key could not be read; assuming 50");
        $start = 50; $start_assumed = 1;
    }
    my $current = int($start);
    $current = 0 if $current < 0; $current = 100 if $current > 100;
    my $initial = _apply_one_setting($item, $key, $current, 'picture');
    if (!_response_ok($initial)) { $::LAST_ERROR = $initial->{message} || 'Unable to set initial panel light'; return 0; }
    $item->{settings}{$key} = $current;
    _sleep_controlled(2) or return 0;
    my @iterations;
    my $converged = 0;
    my $last_read;
    my $stage_failed = 0;
    for my $iteration (1..8) {
        my $reading = _read_white($item);
        my $luma = _luminance($reading);
        my $entry = { iteration => $iteration, value => $current, reading => $reading, luminance => $luma };
        if (!defined($luma) || $luma <= 0) {
            $entry->{result} = 'measurement-failed';
            $::LAST_ERROR ||= 'Panel-light control did not receive a valid white luminance measurement';
            $stage_failed = 1;
            push @iterations, $entry;
            last;
        }
        $last_read = $luma;
        my $tolerance = $target * 0.03;
        $tolerance = 2 if $tolerance < 2;
        if (abs($luma - $target) <= $tolerance) {
            $entry->{result} = 'converged';
            $converged = 1;
            push @iterations, $entry;
            last;
        }
        if ($iteration == 8) { push @iterations, $entry; last; }
        my $next = int(($current || 1) * $target / $luma + 0.5);
        $next = 0 if $next < 0;
        $next = 100 if $next > 100;
        if ($next == $current) {
            $entry->{result} = ($current == 0 || $current == 100) ? 'clamped' : 'resolution-limit';
            push @iterations, $entry;
            last;
        }
        $entry->{next_value} = $next;
        push @iterations, $entry;
        my $result = _apply_one_setting($item, $key, $next, 'picture');
        if (!$result || ($result->{status} || '') ne 'ok') {
            $entry->{result} = 'set-failed';
            $::LAST_ERROR = $result->{message} || "Unable to adjust panel light $key";
            $stage_failed = 1;
            last;
        }
        $current = $next;
        $item->{settings}{$key} = $current;
        my $verified = _read_and_verify_settings($item_number, $item, 'c5-panel-iteration');
        if (!$verified->{verified} && $verified->{verified} ne 'unverifiable') {
            $entry->{result} = 'set-unverified';
            $::LAST_ERROR = 'Panel-light adjustment did not verify against the LG TV';
            $stage_failed = 1;
            last;
        }
        _sleep_controlled(2) or last;
    }
    my $unreachable = !$converged && ($current == 0 || $current == 100);
    if (!$converged && !$unreachable && !$stage_failed) {
        $stage_failed = 1;
        $::LAST_ERROR = 'Panel light did not reach the luminance tolerance within eight measurements';
    }
    my $warning = $converged ? undef : ($unreachable ? 'panel-light-target-unreachable' : 'panel-light-unverifiable');
    my $final_check = { verified => 'unverifiable' };
    if (!$stage_failed) {
        $final_check = _read_and_verify_settings($item_number, $item, 'c5');
        if (!$final_check->{verified} && $final_check->{verified} ne 'unverifiable') {
            $stage_failed = 1;
            $::LAST_ERROR = 'Panel-light stage settings did not verify against the LG TV';
        }
    }
    my $result = {
        policy => 'target',
        key => $key,
        target_luminance => $target,
        iterations => \@iterations,
        settled_value => $current,
        start_value_assumed => $start_assumed ? JSON::PP::true : JSON::PP::false,
        last_luminance => $last_read,
        converged => $converged ? JSON::PP::true : JSON::PP::false,
        settings_verified => $final_check->{verified},
        warning => $warning,
        completed_at => time(),
    };
    delete $result->{warning} if !defined($result->{warning});
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json', $result);
    return 0 if $stage_failed;
    return 0 if !_record_setup_luminance($item,$last_read);
    $item->{warnings} ||= [];
    push @{$item->{warnings}}, $warning if $warning;
    push @{$item->{warnings}}, 'panel-light-start-assumed'
        if $start_assumed && !grep { !ref($_) && $_ eq 'panel-light-start-assumed' } @{$item->{warnings}};
    return _update_item_snapshot($item_number, $item);
}

sub _update_item_snapshot {
    my ($item_number, $item) = @_;
    my $path = PGAutomation::item_dir($RUN_ID, $item_number) . '/item.json';
    my ($ok) = PGAutomation::with_lock($path, sub { return $item; });
    _log("item $item_number snapshot update failed") if !$ok;
    return $ok;
}

sub _calibration_greyscale_stage {
    my ($item_number, $item) = @_;
    return 0 if !_set_dv_map($item, '2');
    _log('launching LG greyscale AutoCal worker');
    $ACTIVE_WORKER = 'grey';
    my $grey_start = _start_worker('/api/meter/lg-autocal', '/api/meter/lg-autocal/status', _grey_payload($item));
    if (!$grey_start || ($grey_start->{status} || '') ne 'started') {
        $ACTIVE_WORKER = '';
        $::LAST_ERROR = $grey_start->{message} || 'Unable to start LG greyscale AutoCal';
        return 0;
    }
    my $grey = _wait_worker('/api/meter/lg-autocal/status', 'greyscale AutoCal', $item);
    my $copied = _copy_worker_files($item_number, 'grey', $grey);
    if ($STOP_REQUESTED) {
        _log('LG greyscale AutoCal worker retained for stop cleanup');
        return 0 if !$copied || $STOP_REQUESTED;
    }
    return 0 if !$copied;
    if (!ref($grey) || ($grey->{status} || '') ne 'complete') {
        $::LAST_ERROR = $grey->{message} || $grey->{error} || 'Greyscale worker did not complete';
        $::LAST_ERROR_DETAIL = $grey->{failure_detail} if ref($grey->{failure_detail}) eq 'HASH';
        return 0;
    }
    $ACTIVE_WORKER = '';
    my $verified = $grey->{ddc_upload_verified} || $grey->{final_1d_lut_upload_verified};
    return {verified => $verified ? JSON::PP::true : 'unverifiable',
        final_1d_lut_upload_verified => $grey->{final_1d_lut_upload_verified},
        ddc_upload_verified => $grey->{ddc_upload_verified}};
}

sub _calibration_volume_stage {
    my ($item_number, $item) = @_;
    my $signal = _signal($item);
    if ($signal eq 'dv') {
        return 0 if !_set_dv_map($item, '2');
        _log('launching Dolby Vision profile worker');
        $ACTIVE_WORKER = 'dv';
        my $start = _start_worker('/api/lg/dv-profile/start', '/api/lg/dv-profile/status', _dv_payload($item));
        if (!$start || ($start->{status} || '') ne 'started') {
            $ACTIVE_WORKER = '';
            $::LAST_ERROR = $start->{message} || 'Unable to start Dolby Vision profile measurement';
            return 0;
        }
        my $dv = _wait_worker('/api/lg/dv-profile/status', 'Dolby Vision profile', $item);
        my $copied = _copy_worker_files($item_number, 'dv', $dv);
        if ($STOP_REQUESTED) {
            _log('Dolby Vision profile worker retained for stop cleanup');
            return 0 if !$copied || $STOP_REQUESTED;
        }
        return 0 if !$copied;
        if (!ref($dv) || ($dv->{status} || '') ne 'complete') {
            $::LAST_ERROR = (ref($dv) && ($dv->{message} || $dv->{error})) || 'Dolby Vision profile worker did not complete';
            return 0;
        }
        $ACTIVE_WORKER = '';
        my $measurements = $dv->{measurements} || $dv->{dv_profile_measurements} || $dv->{result};
        if (ref($measurements) ne 'HASH') {
            $::LAST_ERROR = 'Dolby Vision profile did not return measurements';
            return 0;
        }
        my $before_upload = _read_and_verify_settings($item_number, $item, 'dv-profile-before-upload');
        if (!$before_upload->{verified}) {
            my $read_failed = $before_upload->{storage_failure}
                || grep { $_->{read_failed} } values %{$before_upload->{values} || {}};
            return _settings_boundary_pause($item, 'dv-profile-before-upload', 'volume-done',
                _settings_failure_message('dv-profile-before-upload', $before_upload, 1), $read_failed);
        }
        my $mode = _api('GET', '/api/lg/status', undef);
        return _settings_boundary_pause($item, 'dv-profile-before-upload', 'volume-done',
            'Calibration mode is unavailable before profile upload; no profile was uploaded', 1)
            if ref($mode) ne 'HASH' || ($mode->{status} || '') ne 'ok' || $mode->{disconnected}
                || !exists($mode->{calibration_mode});
        my $proof = {transition=>'dv-profile-upload', verified=>$before_upload->{verified},
            values=>$before_upload->{values}, calibration_mode=>$mode->{calibration_mode} ? 1 : 0, checked_at=>time()};
        _log_action('Uploading measured Dolby Vision profile; TV calibration mode currently '.($proof->{calibration_mode} ? 'on' : 'off'));
        my $upload = _api('POST', '/api/lg/dv-profile/upload', {
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => 'dv',
            measurements => $measurements,
            keep_calibration_mode => JSON::PP::false,
            calibration_mode_active => $proof->{calibration_mode} ? JSON::PP::true : JSON::PP::false,
        });
        if (!$upload || ($upload->{status} || '') ne 'ok') {
            $::LAST_ERROR = $upload->{message} || 'Dolby Vision profile upload failed';
            return 0;
        }
        return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/dv-profile-upload.json', $upload);
        # The helper reports cal_end_tolerated when the TV rejected CAL_END in a
        # known-harmless way. The profile write was accepted but CAL_END was
        # never confirmed, so the stage is recorded as unverifiable (a warning
        # on the item), not verified.
        return {verified => 'unverifiable', cal_end_tolerated => JSON::PP::true} if $upload->{cal_end_tolerated};
        return {verified => JSON::PP::true, cal_end_tolerated => JSON::PP::false, settings_before_upload=>$proof};
    }
    _log('launching LG 3D LUT AutoCal worker');
    $ACTIVE_WORKER = '3d';
    my $start = _start_worker('/api/meter/lg-3d-autocal/start', '/api/meter/lg-3d-autocal/status', _three_d_payload($item, _run(), $item_number));
    if (!$start || ($start->{status} || '') ne 'started') {
        $ACTIVE_WORKER = '';
        $::LAST_ERROR = $start->{message} || 'Unable to start LG 3D LUT AutoCal';
        return 0;
    }
    my $three_d = _wait_worker('/api/meter/lg-3d-autocal/status', '3D LUT AutoCal', $item);
    if (ref($three_d) eq 'HASH' && ($three_d->{status} || '') eq 'error' && $three_d->{upload_retry_available}) {
        my $retry = _api('POST', '/api/meter/lg-3d-autocal/retry-upload', { run_id => $RUN_ID });
        if ($retry && ($retry->{status} || '') eq 'started') {
            $three_d = _wait_worker('/api/meter/lg-3d-autocal/status', '3D LUT upload retry', $item);
        }
    }
    my $copied = _copy_worker_files($item_number, '3d', $three_d);
    if (ref($three_d) eq 'HASH') {
        for my $check (@{$three_d->{automation_processing_checks} || []}) {
            if (!PGAutomation::append_line_locked(
                PGAutomation::item_dir($RUN_ID,$item_number).'/settings-checks.ndjson',
                PGAutomation::encode_json($check)."\n")) {
                $copied = 0;
                $::LAST_ERROR = 'Unable to save 3D processing-setting verification evidence';
            }
        }
        for my $warning (@{$three_d->{automation_processing_warnings} || []}) {
            push @{$item->{warnings}}, $warning if !grep {$_ eq $warning} @{$item->{warnings}||[]};
        }
    }
    if ($STOP_REQUESTED) {
        _log('LG 3D LUT AutoCal worker retained for stop cleanup');
        return 0 if !$copied || $STOP_REQUESTED;
    }
    return 0 if !$copied;
    if (!ref($three_d) || ($three_d->{status} || '') ne 'complete') {
        $::LAST_ERROR = $three_d->{message} || '3D LUT AutoCal did not complete';
        return 0;
    }
    $ACTIVE_WORKER = '';
    return {verified => ($three_d->{terminal_commit_verified} || $three_d->{upload_verified})
        ? JSON::PP::true : 'unverifiable', terminal_commit_verified => $three_d->{terminal_commit_verified}};
}

sub _restore_profile_baseline {
    my ($number,$item)=@_;
    return 1 if _signal($item) eq 'dv';
    my $grey=PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID,$number).'/calibration/grey-state.json');
    my $dpg=ref($grey) eq 'HASH' ? $grey->{_signal($item) eq 'hdr10'?'hdr20_1d_dpg_data':'sdr_1d_dpg_data'} : undef;
    die 'Cannot restore profile baseline: verified 1D data is missing' if !_resume_calibration_artifacts_ok($number,$item,'grey')
        || ref($dpg) ne 'ARRAY' || @$dpg!=3072;
    _log_action('Restoring saved 1D curve and unity 3D baseline before repeating the profile; no 1D remeasurement');
    die 'Unable to close calibration before restoring profile baseline' if !_ensure_calibration_mode_off($item);
    my $reset=_api('POST','/api/lg/3d-lut/reset',{
        picture_mode=>_picture_mode($item),signal_mode=>_signal($item),
        upload_command=>_signal($item) eq 'hdr10'?'BT2020_3D_LUT_DATA':'BT709_3D_LUT_DATA',
        keep_calibration_mode=>JSON::PP::true,calibration_mode_active=>JSON::PP::false,
    });
    die((ref($reset) eq 'HASH' && $reset->{message})||'Unity profile baseline reset failed') if ref($reset) ne 'HASH'
        || ($reset->{status}||'') ne 'ok' || !$reset->{upload_verified};
    my $upload=_api('POST','/api/lg/1d-dpg/upload',{
        picture_mode=>_picture_mode($item),signal_mode=>_signal($item),dpg_data=>$dpg,
        ddc_layout=>_signal($item) eq 'hdr10'?'hdr20':'sdr26',
        keep_calibration_mode=>JSON::PP::true,calibration_mode_active=>JSON::PP::true,
    });
    die((ref($upload) eq 'HASH' && $upload->{message})||'Saved 1D curve restore failed') if ref($upload) ne 'HASH'
        || ($upload->{status}||'') ne 'ok' || !$upload->{dpg_uploaded};
    die($::LAST_ERROR||'Profile baseline settings did not verify')
        if !_apply_and_verify($number,$item,'resume-profile-baseline',1,1);
    my $mode=_api('GET','/api/lg/status',undef);
    die 'Profile baseline did not retain a confirmed calibration session' if ref($mode) ne 'HASH'
        || ($mode->{status}||'') ne 'ok' || $mode->{disconnected} || !$mode->{calibration_mode};
    die 'Unable to save restored profile baseline evidence' if !_write_artifact(
        PGAutomation::item_dir($RUN_ID,$number).'/calibration/profile-baseline-restore.json',
        {restored_at=>time(),picture_mode=>_picture_mode($item),verified=>JSON::PP::true,
         source=>'grey-state.json',data_count=>scalar @$dpg,unity_reset=>$reset,dpg_upload=>$upload});
    delete $item->{profile_baseline_needs_restore};
    return 1;
}

sub _close_calibration {
    my ($item) = @_;
    my ($closed, $off, $status);
    for my $attempt (1..3) {
        $off = _api('POST', '/api/lg/calibration-mode', {
            enabled => JSON::PP::false,
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => _signal($item),
        });
        $status = _api('GET', '/api/lg/status', undef);
        $closed = ref($status) eq 'HASH' && ($status->{status} || '') eq 'ok'
            && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode};
        last if $closed;
        _sleep_controlled(1) or last;
    }
    my $end = _api('POST', '/api/lg/autocal/run/end', {
        status => 'complete',
        note => 'Automation calibration stage complete',
        run_id => $RUN_ID,
        client_run_token => $TOKEN,
    });
    my $end_ok = ref($end) eq 'HASH' && ($end->{status} || '') eq 'ok';
    return ($closed && $end_ok, $off, $status, $end);
}

sub _ensure_calibration_mode_off {
    my ($item) = @_;
    _log_action('Closing TV calibration mode before measurements');
    for my $attempt (1..3) {
        my $off = _api('POST', '/api/lg/calibration-mode', {
            enabled => JSON::PP::false,
            picture_mode => _picture_mode($item),
            tv_input => $item->{tv_input}||'',
            signal_mode => _signal($item),
        });
        my $status = _api('GET', '/api/lg/status', undef);
        if (ref($status) eq 'HASH' && ($status->{status} || '') eq 'ok'
            && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode}) {
            _log_action('TV calibration mode confirmed off');
            return 1;
        }
        _sleep_controlled(1) or return 0;
    }
    $::LAST_ERROR = 'LG calibration mode could not be confirmed off';
    return 0;
}

sub _quality_stage {
    my ($item_number, $item) = @_;
    my $quality = ref($item->{quality}) eq 'HASH' ? $item->{quality} : {};
    my $result = {
        enabled => $quality->{enabled} ? JSON::PP::true : JSON::PP::false,
        formula => $quality->{dE_formula} || $item->{delta_e_formula} || 'deitp',
        series => {},
        warnings => [],
        completed_at => time(),
    };
    if ($quality->{enabled}) {
        my $limits = ref($quality->{limits}) eq 'HASH' ? $quality->{limits} : {};
        foreach my $key (_series_selection($item, 'post')) {
            my $snapshot = PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID, $item_number) . "/post/$key.json") || {};
            my ($average, $max, $count, $missing) = PGAutomation::quality_summary(
                $snapshot, $result->{formula}, $item->{target_white});
            my $limit = ref($limits->{$key}) eq 'HASH' ? $limits->{$key} : {};
            my $miss = (defined($average) && defined($limit->{avg}) && $average > $limit->{avg})
                || (defined($max) && defined($limit->{max}) && $max > $limit->{max});
            $result->{series}{$key} = {
                average => $average,
                maximum => $max,
                readings => $count,
                limits => $limit,
                missing_readings => $missing,
                passed => !$count || $missing ? undef : ($miss ? JSON::PP::false : JSON::PP::true),
            };
            push @{$result->{warnings}}, {
                code => 'quality-limit',
                series => $key,
                average => $average,
                maximum => $max,
            } if $miss;
            push @{$result->{warnings}}, {code => 'quality-unverifiable', series => $key,
                message => 'Missing measurements or target metadata; quality was not verified'}
                if !$count || $missing;
        }
    }
    return undef if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/quality.json', $result);
    return $result;
}

sub _apply_all {
    my ($item_number, $item) = @_;
    my $fault = PGAutomation::read_json_file(PGAutomation::base_dir() . '/fault.json');
    if (ref($fault) eq 'HASH' && ($fault->{stage} || '') eq 'apply-all' && ($fault->{mode} || '') eq 'error') {
        unlink(PGAutomation::base_dir() . '/fault.json');
        $item->{fault_injected} = JSON::PP::true;
        if (!_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json', {
            status => 'error',
            error_code => 'fault-injected',
            fault_injected => JSON::PP::true,
            completed_at => time(),
        })) {
            return 0;
        }
        $::LAST_ERROR = 'Test fault injected at apply-all';
        return 0;
    }
    my $check = _read_and_verify_settings($item_number, $item, 'c9')->{verified};
    return 0 if !$check && $check ne 'unverifiable';
    my $response = _api('POST', '/api/lg/picture-settings/apply-all-inputs', {
        picture_mode => _picture_mode($item),
        tv_input => $item->{tv_input}||'',
        signal_mode => _signal($item),
    });
    my $outcome = 'failed';
    my $confirmation_unavailable = ref($response) eq 'HASH' && ($response->{status} || '') eq 'ok'
        && !$response->{error_code} && !$response->{confirmed} && $response->{confirmation_unavailable}
        && ($response->{transport} || '') =~ /^(?:ssap|luna)$/;
    if (ref($response) eq 'HASH' && ($response->{status} || '') eq 'ok') {
        # Successful dispatch is not proof of a completed copy. Distinguish a
        # known unsupported confirmation read from other unconfirmed results.
        $outcome = $response->{confirmed} ? 'confirmed' : $confirmation_unavailable ? 'sent-unconfirmed' : 'unverified';
    }
    my $record = {
        %{$response || {}},
        outcome => $outcome,
        completed_at => time(),
    };
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json', $record);
    my $error_code = ref($response) eq 'HASH' ? ($response->{error_code} || '') : '';
    if ($outcome eq 'failed' || $error_code =~ /^(?:lg-calibration-session-held|apply-all-inputs-unsupported)$/) {
        $::LAST_ERROR = (ref($response) eq 'HASH' ? $response->{message} : undef) || 'LG apply-to-all-inputs failed';
        return 0;
    }
    $item->{warnings} ||= [];
    push @{$item->{warnings}}, 'apply-all-unverified' if $outcome eq 'unverified';
    _log_action('Apply to All Inputs sent - confirmation unavailable on this TV') if $confirmation_unavailable;
    return {verified => $outcome eq 'confirmed' && $check eq '1' ? JSON::PP::true : 'unverifiable', outcome => $outcome,
        confirmation_unavailable => $confirmation_unavailable ? JSON::PP::true : JSON::PP::false,
        settings_verified => $check};
}

sub _checkpoint_record {
    my ($item_number, $item, $name, $verified, $evidence, $status) = @_;
    $status = 'done' if !defined($status);
    my $record = {
        name => $name,
        status => $status,
        verified => $verified,
        evidence => $evidence || {},
        completed_at => time(),
    };
    if ($status eq 'done' && ($item->{active_stage}||'') eq $name && $item->{stage_started_at}) {
        $record->{duration_seconds}=time()-$item->{stage_started_at};
    }
    $item->{checkpoints} ||= [];
    push @{$item->{checkpoints}}, $record;
    $item->{checkpoint} = $name;
    $item->{checkpoint_status} = $status;
    $item->{active_stage} = '';
    my $item_saved = _update_item_snapshot($item_number, $item);
    my $run_saved = _update_run(sub {
        my ($run) = @_;
        $run->{active_stage} = '';
        $run->{checkpoint} = $name;
        $run->{last_checkpoint} = $record;
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
    });
    my $artifacts_saved = _copy_worker_files($item_number, 'grey', undef)
        && _copy_worker_files($item_number, '3d', undef)
        && _copy_worker_files($item_number, 'dv', undef);
    if (!$item_saved || !$run_saved || !$artifacts_saved) {
        $::LAST_ERROR = 'Unable to persist automation checkpoint evidence';
        _log($::LAST_ERROR);
        return undef;
    }
    _log('Job '.($item_number+1).' | Saved checkpoint: '.$name.' ('.$status.')');
    return $record;
}

sub _checkpoint_exists {
    my ($item, $name) = @_;
    return 0 if ref($item->{checkpoints}) ne 'ARRAY';
    foreach my $record (@{$item->{checkpoints}}) {
        return 1 if ref($record) eq 'HASH' && ($record->{name} || '') eq $name
            && ($record->{status} || '') eq 'done';
    }
    return 0;
}

sub _last_checkpoint {
    my ($item) = @_;
    return undef if ref($item->{checkpoints}) ne 'ARRAY' || !@{$item->{checkpoints}};
    my @records = grep { ($_->{status} || '') ne 'skipped' } @{$item->{checkpoints}};
    return $records[-1];
}

sub _skip_stage {
    my ($item_number, $item, $name) = @_;
    return if grep { ($_->{name} || '') eq $name && ($_->{status} || '') eq 'skipped' } @{$item->{checkpoints} || []};
    die($::LAST_ERROR || "Unable to persist skipped checkpoint $name")
        if !ref(_checkpoint_record($item_number, $item, $name, 'unverifiable', { skipped => JSON::PP::true }, 'skipped'));
}

sub _stage {
    my ($item_number, $item, $name, $callback) = @_;
    return 1 if _checkpoint_exists($item, $name);
    _refresh_control();
    return 0 if $STOP_REQUESTED;
    $::LAST_ERROR = '';
    $::LAST_ERROR_CODE = '';
    $::LAST_ERROR_DETAIL = undef;
    $ACTIVE_STAGE = $name;
    $item->{active_stage} = $name;
    $item->{stage_started_at} = time();
    my $stage_label={
        'item-started'=>'Job readiness', 'tv-setup-verified'=>'TV setup',
        'pre-readings-done'=>'Before measurements', 'reset-and-reapply-verified'=>'Calibration reset and settings reapply',
        'panel-light-settled'=>'Panel brightness setup', 'greyscale-done'=>'1D LUT calibration',
        'greyscale-settings-verified'=>'Post-1D TV settings check', 'volume-done'=>'Color calibration',
        'volume-settings-verified'=>'Post-color TV settings check', 'session-closed'=>'Calibration-mode exit',
        'apply-all-done'=>'Apply to All Inputs', 'post-readings-done'=>'After measurements',
    }->{$name} || $name;
    _log('Job '.($item_number+1).' | '.$stage_label.' started');
    _update_item_snapshot($item_number, $item);
    _update_run(sub {
        my ($run) = @_;
        $run->{active_item} = $item_number;
        $run->{active_stage} = $name;
        $run->{stage_started_at} = $item->{stage_started_at};
        $run->{worker_status} = {};
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
    });
    my $ok = eval { $callback->(); };
    $ok = 0 if !$ok || $@;
    _refresh_control();
    if ($STOP_REQUESTED) {
        _log("stage $name interrupted by stop request for item $item_number");
        return 0;
    }
    if (!$ok) {
        my $message = $::LAST_ERROR || ($@ || "Stage $name failed");
        my $resumable = 1;
        $item->{status} = $resumable ? 'interrupted' : 'failed';
        $item->{failure} = { stage => $name, message => "$message", at => time() };
        $item->{failure}{error_code} = $::LAST_ERROR_CODE if $::LAST_ERROR_CODE;
        $item->{failure}{detail} = PGAutomation::clone($::LAST_ERROR_DETAIL) if ref($::LAST_ERROR_DETAIL) eq 'HASH';
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = $resumable ? 'interrupted' : 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        _log("$name failed: $message");
        return 0;
    }
    my $verified = ref($ok) eq 'HASH' ? ($ok->{verified} // 1) : 1;
    # This action is allowed to finish without a capability the TV does not
    # expose. Keep its evidence unverified, but do not turn that expected
    # limitation into a job warning. No other stage/read failure is exempt.
    my $informational_apply = $name eq 'apply-all-done' && ref($ok) eq 'HASH'
        && ($ok->{outcome} || '') eq 'sent-unconfirmed' && $ok->{confirmation_unavailable}
        && ($ok->{settings_verified} // '') eq '1';
    if (defined($verified) && $verified eq 'unverifiable' && !$informational_apply) {
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, "$name-unverified"
            if !grep { !ref($_) && $_ eq "$name-unverified" } @{$item->{warnings}};
    }
    my $evidence = ref($ok) eq 'HASH' ? $ok : { result => $ok };
    my $checkpoint = _checkpoint_record($item_number, $item, $name, $verified, $evidence);
    if (!ref($checkpoint)) {
        my $message = $::LAST_ERROR || "Unable to persist checkpoint $name";
        $item->{status} = 'failed';
        $item->{failure} = { stage => $name, message => $message, at => time() };
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        _log("$name checkpoint failed: $message");
        return 0;
    }
    $ACTIVE_STAGE = '';
    $ACTIVE_WORKER = '';
    _refresh_control();
    return 1;
}

sub _pause_after_checkpoint {
    _refresh_control();
    return 0 if !$PAUSE_REQUESTED || $STOP_REQUESTED;
    die 'Unable to persist paused automation state' if !ref(_update_run(sub {
        my ($run) = @_;
        $run->{status} = 'paused';
        $run->{paused_at} = time();
        $run->{runner_pid} = 0;
        $run->{active_stage} = '';
    }));
    unlink($RUN_DIR . '/runner.pid');
    die 'Unable to persist paused execution state' if !_write_execution();
    _log('pause reached a checkpoint; runner exiting');
    return 1;
}

sub _park_interrupted {
    my ($stage) = @_;
    _update_run(sub {
        my ($run) = @_;
        $run->{status} = 'interrupted';
        $run->{runner_pid} = 0;
        $run->{active_stage} = $stage if defined($stage) && $stage ne '';
        $run->{updated_at} = time();
    });
    PGAutomation::with_lock($EXECUTION_FILE, sub {
        my ($current) = @_;
        return undef if ref($current) ne 'HASH'
            || ($current->{run_id} || '') ne $RUN_ID
            || ($current->{token} || '') ne $TOKEN;
        $current->{status} = 'interrupted';
        $current->{pid} = 0;
        $current->{updated_at} = time();
        return $current;
    });
    unlink($RUN_DIR . '/runner.pid');
    $ACTIVE_STAGE = '';
    $ACTIVE_WORKER = '';
    _log('runner parked an interrupted run for resume');
}

sub _stop_active {
    return if $STOP_HANDLED++;
    $STOPPING = 1;
    _update_run(sub {
        $_[0]{status}='stopping';
        $_[0]{worker_status}={message=>'Stopping all workers and closing TV calibration mode'};
    });
    _log_action('Stop requested: cancelling all measurement and calibration workers');
    my %paths = (
        series=>'/api/meter/series', grey=>'/api/meter/lg-autocal',
        '3d'=>'/api/meter/lg-3d-autocal', dv=>'/api/lg/dv-profile',
    );
    # The stage pointer can be empty/stale during startup and handoffs.
    # Signal every worker first; never rely on that pointer for safety.
    foreach my $worker (sort keys %paths) {
        _api('POST',$paths{$worker}.'/stop',{automation_graceful=>JSON::PP::true},1,0);
    }
    my $deadline=time()+5;
    while (time()<$deadline && grep { _worker_process_alive($_) } keys %paths) {
        select(undef,undef,undef,0.25);
    }
    foreach my $worker (sort keys %paths) {
        next if !_worker_process_alive($worker);
        _log_action("Force stopping $worker worker after cancellation grace period");
        _api('POST',$paths{$worker}.'/kill',{automation_force=>JSON::PP::true},1,0);
    }
    my @alive=grep { _worker_process_alive($_) } sort keys %paths;
    if ($ACTIVE_WORKER eq 'series' && $ACTIVE_ITEM && $ACTIVE_SERIES_KEY && $ACTIVE_SERIES_PHASE) {
        my $partial = PGAutomation::read_json_file('/tmp/meter_series.json');
        _snapshot_series($ACTIVE_ITEM->{item_number} || 0, $ACTIVE_SERIES_PHASE, $ACTIVE_SERIES_KEY, $partial)
            if ref($partial) eq 'HASH';
    }
    my $meter_session=_api('POST','/api/meter/session/stop',{},1,0);
    my $item=ref($ACTIVE_ITEM) eq 'HASH' ? $ACTIVE_ITEM : {};
    _log_action('Workers cancelled; sending TV calibration exit even if no job is active');
    # Reconnect using the saved pairing when needed; never initiate pairing.
    _ensure_lg_connection();
    my $off=_api('POST','/api/lg/calibration-mode',{
        enabled=>JSON::PP::false,
        picture_mode=>_picture_mode($item),signal_mode=>_signal($item),
    },1,0);
    my $saved=_run();
    my $end=_api('POST','/api/lg/autocal/run/end',{
        status=>'aborted',note=>'Automation stopped',
        run_id=>$saved->{lg_run_id}||$RUN_ID,client_run_token=>$TOKEN,
    },1,0);
    my $status=_api('GET','/api/lg/status',undef,1,0);
    my $exit_ack=_response_ok($off) || (_response_ok($end) && exists($end->{calibration_mode}) && !$end->{calibration_mode} && !$end->{stale_run_ignored});
    my $closed=$exit_ack && _response_ok($status)
        && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode};
    my @problems;
    push @problems,'Workers still alive: '.join(', ',@alive) if @alive;
    push @problems,'Meter release failed: '.($meter_session->{message}||'no acknowledgement') if !_response_ok($meter_session);
    push @problems,'TV calibration exit unconfirmed: '.($off->{message}||$status->{message}||'TV did not acknowledge CAL_END') if !$closed;
    my $cleanup={verified=>@problems?JSON::PP::false:JSON::PP::true,completed_at=>time(),
        calibration_mode=>$off,run_end=>{map {exists($end->{$_})?($_=>$end->{$_}):()} qw(status error_code message calibration_mode stale_run_ignored)},tv_status=>$status,workers_alive=>\@alive,
        message=>@problems?join('; ',@problems):'All workers stopped; meter released; TV acknowledged calibration exit'};
    _update_run(sub {
        $_[0]{stop_cleanup}=$cleanup;
        $_[0]{worker_status}={message=>($cleanup->{verified}?'Cleanup complete: ':'Cleanup failed: ').$cleanup->{message}};
    });
    _log_action(($cleanup->{verified}?'Stop cleanup complete: ':'Stop cleanup FAILED: ').$cleanup->{message});
    if (ref($ACTIVE_ITEM) eq 'HASH') {
        my $number=$item->{item_number}||0;
        my $preserve_failure=ref($item->{failure}) eq 'HASH' && !$STOP_REQUESTED;
        my $interrupted_stage=$ACTIVE_STAGE||$item->{active_stage}||'unknown';
        _write_artifact(PGAutomation::item_dir($RUN_ID,$number).'/calibration/stop-cleanup.json',$cleanup);
        push @{$item->{warnings}},$cleanup->{message} if !$cleanup->{verified};
        # A Stop during final cleanup must not rewrite a completed result.
        if (!$preserve_failure && ($item->{status}||'') !~ /^complete/) {
            $item->{status}='stopped';
            $item->{failure}={stage=>$interrupted_stage,status=>'interrupted',at=>time()};
            _checkpoint_record($number,$item,$interrupted_stage,JSON::PP::false,{interrupted=>JSON::PP::true},'interrupted')
                if $interrupted_stage ne 'unknown';
        }
        _update_item_snapshot($number,$item);
    }
    my $visible=_api('POST','/api/pattern',{name=>'gray50'},1,0);
    _log_action('Stop idle pattern: '.($visible->{status}||'unavailable'));
    $STOPPING = 0;
}

sub _finish {
    my ($status, $failure) = @_;
    my $cleanup=_run()->{stop_cleanup};
    if ($status eq 'stopped' && ref($cleanup) eq 'HASH' && !$cleanup->{verified}) {
        $status='failed';
        $failure={stage=>'stop-cleanup',message=>$cleanup->{message},error_code=>'stop-cleanup-unverified'};
    }
    my $meter_session = _api('POST', '/api/meter/session/stop', {}, 1, 0);
    _log('finish cleanup meter session=' . (($meter_session && ref($meter_session) eq 'HASH' && ($meter_session->{status} || '') eq 'ok') ? 'ok' : 'failed'));
    _update_run(sub {
        my ($run) = @_;
        $run->{status} = $status;
        $run->{completed_at} = time() if $status =~ /^(?:complete|failed|stopped)$/;
        $run->{runner_pid} = 0;
        $run->{active_stage} = '';
        $run->{failure} = $failure if ref($failure) eq 'HASH';
    });
    unlink($RUN_DIR . '/runner.pid');
    _release_execution();
}

sub _restore_hazards {
    my ($item) = @_;
    my $restore = ref($item->{hazard_restore}) eq 'HASH' ? $item->{hazard_restore} : {};
    my @failed;
    foreach my $key (keys %$restore) {
        my $record = $restore->{$key};
        next if $key eq 'energySaving' || $key eq 'aiPicture';
        my ($value,$category);
        if (ref($record) eq 'HASH') {
            $value = $record->{value};
            $category = $record->{category} || 'picture';
        } else {
            $value = $record;
            $category = _setting_category($item, $key);
        }
        next if !defined($value);
        my $result = _api('POST', '/api/lg/picture-settings/set', {
            settings => { $key => $value }, category => $category,
            picture_mode => _picture_mode($item), signal_mode => _signal($item),
        }, 1, 0);
        if (!_response_ok($result) || ($result->{verification_state} || '') ne 'verified') {
            my $message = (ref($result) eq 'HASH' && $result->{message}) || 'restoration was not verified';
            _log("Hazard restoration failed for $key: $message");
            push @failed, { key => $key, value => $value, message => $message };
        }
    }
    return \@failed;
}

sub _restore_run_hazards {
    my ($run, $items) = @_;
    my %restore;
    if (ref($run) eq 'HASH' && ref($run->{hazard_restore}) eq 'HASH') {
        %restore = %{$run->{hazard_restore}};
    }
    if (!%restore) {
        foreach my $item (@{$items || []}) {
            next if ref($item) ne 'HASH';
            foreach my $key (keys %{$item->{hazard_restore} || {}}) {
                $restore{$key} = $item->{hazard_restore}{$key}
                    if !exists($restore{$key});
            }
        }
    }
    return if !%restore;
    my $context = ref($ACTIVE_ITEM) eq 'HASH' ? $ACTIVE_ITEM
        : (ref($items) eq 'ARRAY' && ref($items->[0]) eq 'HASH' ? $items->[0] : {});
    my $failed = _restore_hazards({ %$context, hazard_restore => \%restore });
    # A TV left with its power-off or screen-saver protection disabled must
    # be visible in history, not only in runner.log.
    _update_run(sub { $_[0]{hazard_restore_failures} = $failed; }) if @$failed;
    return $failed;
}

sub _drop_resume_checkpoints {
    my ($item, $names) = @_;
    # A boundary proof belongs to the calibration immediately before it.
    $names->{'greyscale-settings-verified'} = 1 if $names->{'greyscale-done'};
    $names->{'volume-settings-verified'} = 1 if $names->{'volume-done'};
    $item->{checkpoints} = [grep {
        ref($_) eq 'HASH' && !$names->{$_->{name} || ''}
    } @{$item->{checkpoints} || []}];
}

sub _resume_series_artifacts_ok {
    my ($item_number, $item, $which) = @_;
    foreach my $key (_series_selection($item, $which)) {
        my $path = PGAutomation::item_dir($RUN_ID, $item_number) . "/$which/$key.json";
        my $snapshot = PGAutomation::read_json_file($path);
        return 0 if ref($snapshot) ne 'HASH' || ($snapshot->{status} || '') ne 'complete';
    }
    return 1;
}

sub _resume_calibration_artifacts_ok {
    my ($item_number, $item, $kind) = @_;
    my $dir = PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration';
    if ($kind eq 'grey') {
        my $state = PGAutomation::read_json_file($dir . '/grey-state.json');
        return ref($state) eq 'HASH' && ($state->{status} || '') eq 'complete'
            && ($state->{ddc_upload_verified} || $state->{final_1d_lut_upload_verified});
    }
    if (_signal($item) eq 'dv') {
        my $state = PGAutomation::read_json_file($dir . '/dv-profile-state.json');
        my $upload = PGAutomation::read_json_file($dir . '/dv-profile-upload.json');
        return ref($state) eq 'HASH' && ($state->{status} || '') eq 'complete'
            && ref($upload) eq 'HASH' && ($upload->{status} || '') eq 'ok';
    }
    my $state = PGAutomation::read_json_file($dir . '/3d-state.json');
    return 0 if ref($state) ne 'HASH' || ($state->{status} || '') ne 'complete';
    my $export = ref($state->{export}) eq 'HASH' ? $state->{export} : {};
    my @files;
    foreach my $source (map { $export->{$_} || '' } qw(cube_path payload_path)) {
        next if $source !~ m{/([A-Za-z0-9_.-]+)$};
        push @files, $dir . '/' . $1;
    }
    my $files_exist = @files >= 2 && !grep { !-f $_ } @files;
    return ($state->{terminal_commit_verified} || $state->{upload_verified}) && $files_exist;
}

sub _gamut_warning_only_recovery {
    my ($number, $item) = @_;
    return 0 if ($item->{settings_recovery}{point} || '') ne 'c6'
        || ($item->{settings_recovery}{resume_from} || '') ne 'greyscale-done'
        || !_checkpoint_exists($item, 'greyscale-done')
        || !_resume_calibration_artifacts_ok($number, $item, 'grey');
    my $path = PGAutomation::item_dir($RUN_ID, $number).'/settings-checks.ndjson';
    open(my $fh, '<', $path) or return 0;
    my %checks;
    while (my $line = <$fh>) {
        my $c = PGAutomation::decode_json($line);
        if (ref($c) ne 'HASH') { close($fh); return 0; }
        my $point = $c->{checkpoint} || '';
        next if $point !~ /^c6(?:-confirm|-repair|-stable)?$/;
        if (($c->{operation} || '') eq 'write') {
            if ($c->{key} ne 'colorGamut' || ($c->{result} || '') ne 'applied') { close($fh); return 0; }
            next;
        }
        $checks{$point}{$c->{key}} = $c;
    }
    close($fh);
    my %expected = (%{_item_settings($item)}, pictureMode=>_picture_mode($item));
    for my $point (qw(c6 c6-confirm)) {
        my $warning = 0;
        for my $key (keys %expected) {
            my $c = $checks{$point}{$key} || return 0;
            return 0 if !_value_agrees($expected{$key}, $c->{expected}, $key);
            next if $c->{verified};
            return 0 if ($c->{result} || '') ne 'mismatch' || ($c->{error_code} || '') ne ''
                || !_lg_gamut_readback_warning($key, $c->{expected}, $c->{observed});
            $warning = 1;
        }
        return 0 if !$warning;
    }
    return 1;
}

sub _prepare_resume {
    my ($item_number, $item, $context_ready) = @_;
    die($::LAST_ERROR || 'Unable to restore the queued signal format') if !$context_ready && !_apply_signal($item);
    my $last = _last_checkpoint($item);
    return if !ref($last);
    if (ref($item->{settings_recovery}) eq 'HASH') {
        my $from = $item->{settings_recovery}{resume_from} || '';
        if (_gamut_warning_only_recovery($item_number, $item)) {
            $from = 'greyscale-settings-verified';
            _log_action('Resuming Auto requested / Wide reported pause: retaining the verified 1D upload and rechecking the expected LG calibration state before profiling');
        }
        my @order = qw(reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed apply-all-done post-readings-done item-complete);
        my %allowed = map { $_=>1 } qw(greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed);
        die 'Invalid saved settings recovery plan; review this job before starting again' if !$allowed{$from};
        # A saved plan cannot stand in for the actual committed result files.
        if ($from ne 'greyscale-done' && !_resume_calibration_artifacts_ok($item_number, $item, 'grey')) {
            $from = 'greyscale-done';
        } elsif ($from =~ /^(?:volume-settings-verified|session-closed)$/
            && !_resume_calibration_artifacts_ok($item_number, $item, 'volume')) {
            $from = 'volume-done';
        }
        # Recheck before reusing a completed 1D stage, even if its prior menu
        # proof survived the interruption. A reboot/cleanup can change settings.
        my $drop = $from eq 'greyscale-done' ? 'reset-and-reapply-verified' : $from;
        my %names; my $started = 0;
        for my $name (@order) { $started = 1 if $name eq $drop; $names{$name}=1 if $started; }
        $names{'greyscale-settings-verified'}=1 if $from eq 'volume-done';
        _drop_resume_checkpoints($item, \%names);
        $item->{profile_baseline_needs_restore}=1 if _signal($item) ne 'dv'
            && $from =~ /^(?:volume-done|greyscale-settings-verified)$/;
        _log_action('Resuming saved settings review at '.$from.'; earlier valid results are retained');
        delete $item->{settings_recovery};
        delete $item->{drift_recovery_pending};
        return;
    }
    my $failure_stage = ref($item->{failure}) eq 'HASH' ? ($item->{failure}{stage} || '') : '';
    if ($item->{drift_recovery_pending} || $failure_stage =~ /^(?:reset-and-reapply-verified|panel-light-settled|greyscale-done|volume-done|session-closed)$/) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    my $name = $last->{name} || '';
    if (($last->{status} || '') ne 'done') {
        if ($name eq 'apply-all-done') {
            _drop_resume_checkpoints($item, { 'apply-all-done' => 1 });
        } else {
            _drop_resume_checkpoints($item, { map { $_ => 1 } qw(
                reset-and-reapply-verified panel-light-settled greyscale-done
                volume-done session-closed apply-all-done post-readings-done item-complete
            ) });
        }
        return;
    }
    if ($name eq 'pre-readings-done' && !_resume_series_artifacts_ok($item_number, $item, 'pre')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(pre-readings-done reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name =~ /^(?:greyscale-done|greyscale-settings-verified)$/ && !_resume_calibration_artifacts_ok($item_number, $item, 'grey')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    # A successful 1D checkpoint may have been followed by pause cleanup or a
    # failed baseline restoration. Recreate the held unity/1D context on every
    # such resume, not only when consuming a settings-recovery plan.
    $item->{profile_baseline_needs_restore}=1 if _signal($item) ne 'dv'
        && $name =~ /^(?:greyscale-done|greyscale-settings-verified)$/;
    if ($name =~ /^(?:volume-done|volume-settings-verified)$/ && !_resume_calibration_artifacts_ok($item_number, $item, 'volume')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    # Re-enter the lightweight check, not the calibration, after pausing at a
    # successful settings checkpoint. Fresh c7 is also collected before exit.
    _drop_resume_checkpoints($item, {'greyscale-settings-verified'=>1}) if $name eq 'greyscale-settings-verified';
    if ($name eq 'panel-light-settled' && !-f(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name eq 'apply-all-done' && !-f(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(apply-all-done post-readings-done item-complete) });
        return;
    }
    my %verification_point = (
        'tv-setup-verified' => 'resume-c1',
        'reset-and-reapply-verified' => 'resume-c4',
        'panel-light-settled' => 'resume-c5',
        'session-closed' => 'resume-c8',
        'apply-all-done' => 'resume-c9',
        'post-readings-done' => 'resume-c10',
    );
    if (exists($verification_point{$name})) {
        my $check = _read_and_verify_settings($item_number, $item, $verification_point{$name});
        if (!$check->{verified} && $check->{verified} ne 'unverifiable') {
            my %drop_from = (
                'tv-setup-verified' => [qw(tv-setup-verified warmup-done pre-readings-done reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'reset-and-reapply-verified' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'panel-light-settled' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'session-closed' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'apply-all-done' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'post-readings-done' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
            );
            _drop_resume_checkpoints($item, { map { $_ => 1 } @{$drop_from{$name} || []} });
        }
    }
}

sub _save_job_readiness {
    my ($number,$item,$readiness)=@_;
    $item->{readiness}={ready=>$readiness->{ready}?1:0,checked_at=>time(),checks=>$readiness->{checks}||[],message=>$readiness->{message}||''};
    foreach my $check (@{$item->{readiness}{checks}}) {
        $check->{item_number}=$number;
        _log_action(($check->{level}||'info').': '.$check->{message}) if !$check->{ok};
    }
    _update_item_snapshot($number,$item);
    _update_run(sub {$_[0]{items}[$number]=$item;});
}

sub _require_job_ready {
    my ($number,$item,$scope)=@_;
    my $result=_api('POST','/api/automation/readiness',{items=>[$item],scope=>$scope});
    _save_job_readiness($number,$item,$result);
    if (!$result->{ready}) {
        my @errors=map {$_->{message}||$_->{name}} grep {!$_->{ok} && ($_->{level}||'error') eq 'error'} @{$result->{checks}||[]};
        die(@errors ? join('; ',@errors) : $result->{message}||'TV/meter readiness failed');
    }
    return $result;
}

sub _freeze_job_lg_context {
    my ($item)=@_;
    my $live=_api('POST','/api/lg/picture-settings',{keys=>['pictureMode'],include_current_input=>JSON::PP::true,signal_mode=>_signal($item)});
    my $profile=ref($live->{generation_profile}) eq 'HASH' ? $live->{generation_profile} : {};
    my $input=$live->{current_input}||'';
    die 'Unable to confirm LG input and compatibility profile before selecting picture mode'
        if (($live->{status}||'') ne 'ok' || $input!~/^hdmi[1-4](?:_pc)?$/ || ($profile->{capability_profile_hash}||'')!~/^[0-9a-f]{64}$/);
    die 'No reviewed LG platform is available for calibration'
        if ($item->{stages}{calibration} && (!$profile->{capability_library_valid} || !$profile->{capability_platform_profile_applied}));
    $item->{tv_input}=$input;
    $item->{generation_profile}=$profile;
    $item->{capability_profile}={id=>$profile->{capability_profile_id},hash=>$profile->{capability_profile_hash}};
    return 1;
}

sub _prepare_job_context {
    my ($number,$item)=@_;
    $ACTIVE_STAGE='job-readiness';
    _update_run(sub {
        $_[0]{active_item}=$number;$_[0]{active_stage}=$ACTIVE_STAGE;$_[0]{stage_started_at}=time();
        $_[0]{worker_status}={message=>'Rechecking TV connection, meter, storage and calibration mode for this job'};
    });
    _log_action('Checking TV, meter and calibration mode for '.($item->{name}||'this job'));
    _require_job_ready($number,$item,'batch');
    die($::LAST_ERROR||'Unable to activate job signal') if !_apply_signal($item);
    _freeze_job_lg_context($item);
    die($::LAST_ERROR||'Unable to select job picture mode') if !_select_item_picture_mode($number,$item,'job-start');
    _log_action('Signal and picture mode selected; checking this job\'s TV controls');
    my $ready=_require_job_ready($number,$item,'job');
    if(ref($ready->{items}) eq 'ARRAY' && ref($ready->{items}[0]) eq 'HASH') {
        %$item=(%$item,%{$ready->{items}[0]});
    }
    # Capture global power/screen-saver restoration values only on first use,
    # before this job applies them; later jobs may observe our disabled values.
    _update_run(sub {
        my ($run)=@_;$run->{hazard_restore}||={};
        foreach my $key (keys %{$ready->{hazard_restore}||{}}) {
            $run->{hazard_restore}{$key}=$ready->{hazard_restore}{$key} if !exists($run->{hazard_restore}{$key});
        }
        $run->{items}[$number]=$item;
    });
    _update_item_snapshot($number,$item);
    _log_action('Job readiness passed; applying and verifying queued settings next');
    return 1;
}

sub _run_item {
    my ($item_number, $item) = @_;
    $ACTIVE_ITEM = $item;
    $item->{item_number} = $item_number;
    $item->{status} = 'running';
    my $has_prior_checkpoint = ref($item->{checkpoints}) eq 'ARRAY' && @{$item->{checkpoints}};
    # Deliberately outside _stage: a saved checkpoint cannot skip fresh device
    # checks or signal restoration after a pause, process restart or reboot.
    my $prepared=eval {
        _prepare_job_context($item_number,$item);
        _prepare_resume($item_number,$item,1) if $has_prior_checkpoint;
        _restore_profile_baseline($item_number,$item) if $item->{profile_baseline_needs_restore};
        1;
    };
    if (!$prepared) {
        my $message=$@||$::LAST_ERROR||'Job preparation failed';
        $item->{status}='interrupted';
        $item->{failure}={stage=>'job-readiness',message=>"$message",at=>time()};
        _update_item_snapshot($item_number,$item);
        _update_run(sub {$_[0]{status}='interrupted';$_[0]{failure}=$item->{failure};$_[0]{items}[$item_number]=$item;});
        _log_action('Job preparation failed: '.$message);
        return 0;
    }
    delete $item->{failure};
    _update_item_snapshot($item_number, $item);
    _update_run(sub {
        my ($run) = @_;
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        $run->{active_item} = $item_number;
    });
    my $stages = _stages($item);
    return 0 if !_stage($item_number, $item, 'item-started', sub {
        return {readiness=>$item->{readiness}};
    });
    return 0 if _pause_after_checkpoint();
    return 0 if !_stage($item_number, $item, 'tv-setup-verified', sub {
        my $verified = _apply_and_verify($item_number, $item, 'c1', 1);
        die($::LAST_ERROR || 'TV settings failed') if !$verified && $verified ne 'unverifiable';
        my $settle=0+($item->{settle_seconds}//8);
        _log_action('TV setup applied; settling for '.$settle.' s before measurements') if $settle>0;
        _sleep_controlled($settle) or die('Automation stopped');
        return { verified => $verified, signal_mode => _signal($item), picture_mode => _picture_mode($item) };
    });
    return 0 if _pause_after_checkpoint();
    if ($stages->{pre}) {
        return 0 if !_stage($item_number, $item, 'pre-readings-done', sub {
            die($::LAST_ERROR || 'Calibration mode did not close before pre-readings')
                if !_ensure_calibration_mode_off($item);
            die('Unable to switch DV to Absolute map') if !_set_dv_map($item, '1');
            die($::LAST_ERROR || 'Pre-readings failed') if !_run_series($item_number, $item, 'pre');
            return 1;
        });
    } else {
        _skip_stage($item_number, $item, 'pre-readings-done');
    }
    return 0 if _pause_after_checkpoint();
    if ($stages->{calibration}) {
            return 0 if !_stage($item_number, $item, 'reset-and-reapply-verified', sub {
                die($::LAST_ERROR || 'Calibration reset failed') if !_reset_for_calibration($item_number, $item);
                my $verified = _apply_and_verify($item_number, $item, 'c4');
                die($::LAST_ERROR || 'Settings did not survive reset') if !$verified && $verified ne 'unverifiable';
                return { verified => $verified };
            });
            return 0 if _pause_after_checkpoint();
            return 0 if !_stage($item_number, $item, 'panel-light-settled', sub {
                my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
                die('Panel light is only targetable on SDR') if lc($panel->{policy} || $item->{panel_light_policy} || 'fixed') eq 'target' && _signal($item) ne 'sdr';
                die($::LAST_ERROR || 'Calibration mode did not close before panel-light control')
                    if !_ensure_calibration_mode_off($item);
                die($::LAST_ERROR || 'Panel-light stage failed') if !_panel_light_stage($item_number, $item);
                my $evidence = PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json') || {};
                return {verified => $evidence->{settings_verified} // $evidence->{verified} // 'unverifiable',
                    panel_light => $evidence};
            });
            return 0 if _pause_after_checkpoint();
            return 0 if !_stage($item_number, $item, 'greyscale-done', sub {
                my $result = _calibration_greyscale_stage($item_number, $item);
                if (!$result) {
                    return 0 if $STOP_REQUESTED;
                    die($::LAST_ERROR || 'Greyscale calibration failed');
                }
                return $result;
            });
            return 0 if _pause_after_checkpoint();
            # Check the completed 1D result before spending time profiling.
            # Once a volume LUT is committed its menu ownership differs, so a
            # later resume goes directly to the post-upload check instead.
            if (!_checkpoint_exists($item, 'volume-done')) {
                return 0 if !_stage($item_number, $item, 'greyscale-settings-verified', sub {
                    _calibration_settings_boundary($item_number, $item, 'c6');
                });
                return 0 if _pause_after_checkpoint();
            }
            my $before_profile_upload;
            return 0 if !_stage($item_number, $item, 'volume-done', sub {
                my $result = _calibration_volume_stage($item_number, $item);
                if (!$result) {
                    return 0 if $STOP_REQUESTED;
                    die($::LAST_ERROR || 'Volume calibration failed');
                }
                $before_profile_upload = $result->{settings_before_upload};
                return $result;
            });
            return 0 if _pause_after_checkpoint();
            my $before_exit;
            if (!_checkpoint_exists($item, 'session-closed')) {
                # Fresh evidence on every entry (including Resume), not a
                # pre-exit snapshot from before a reboot or another writer.
                _drop_resume_checkpoints($item, {'volume-settings-verified'=>1});
                return 0 if !_stage($item_number, $item, 'volume-settings-verified', sub {
                    $before_exit = _calibration_settings_boundary($item_number, $item, 'c7', $before_profile_upload);
                    return $before_exit;
                });
                return 0 if _pause_after_checkpoint();
            }
            return 0 if !_stage($item_number, $item, 'session-closed', sub {
                my ($closed, $off, $status, $end) = _close_calibration($item);
                my $end_message = ref($end) eq 'HASH' ? $end->{message} : undef;
                die(($end_message || $::LAST_ERROR || 'LG calibration session could not be closed'))
                    if !$closed;
                my $checked = _calibration_settings_boundary($item_number, $item, 'c8', $before_exit);
                return 0 if !$checked;
                return {%$checked, calibration_status=>$status};
            });
        return 0 if _pause_after_checkpoint();
        if ($stages->{apply_all}) {
            return 0 if !_stage($item_number, $item, 'apply-all-done', sub {
                my $result = _apply_all($item_number, $item);
                die($::LAST_ERROR || 'Apply-to-all failed') if !$result;
                return $result;
            });
        } else {
            _skip_stage($item_number, $item, 'apply-all-done');
        }
    } else {
        foreach my $stage (qw(reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed apply-all-done)) {
            _skip_stage($item_number, $item, $stage);
        }
    }
        return 0 if _pause_after_checkpoint();
        if ($stages->{post}) {
        return 0 if !_stage($item_number, $item, 'post-readings-done', sub {
            die($::LAST_ERROR || 'Calibration mode did not close before post-readings')
                if !_ensure_calibration_mode_off($item);
            die('Unable to switch DV to Absolute map') if !_set_dv_map($item, '1');
            my $verified = _read_and_verify_settings($item_number, $item, 'c10')->{verified};
            die($::LAST_ERROR || 'Settings did not verify before post-readings') if !$verified && $verified ne 'unverifiable';
            die($::LAST_ERROR || 'Post-readings failed') if !_run_series($item_number, $item, 'post');
            my $quality = _quality_stage($item_number, $item);
            die($::LAST_ERROR || 'Unable to persist quality results') if ref($quality) ne 'HASH';
            push @{$item->{warnings}}, @{$quality->{warnings} || []} if @{$quality->{warnings} || []};
            return { verified => $verified, quality => $quality };
        });
    } else {
        _skip_stage($item_number, $item, 'post-readings-done');
    }
    return 0 if _pause_after_checkpoint();
    my $warnings = ref($item->{warnings}) eq 'ARRAY' && @{$item->{warnings}};
    $item->{status} = $warnings ? 'complete-with-warnings' : 'complete';
    my $complete_checkpoint = _checkpoint_record($item_number, $item, 'item-complete', $warnings ? 'unverifiable' : JSON::PP::true, {
        warnings => $item->{warnings} || [],
    });
    if (!ref($complete_checkpoint)) {
        my $message = $::LAST_ERROR || 'Unable to persist item completion';
        $item->{status} = 'failed';
        $item->{failure} = { stage => 'item-complete', message => $message, at => time() };
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        return 0;
    }
    return 0 if !_update_item_snapshot($item_number, $item);
    $ACTIVE_ITEM = undef;
    return 1;
}

sub _main {
    die "automation store unavailable\n" if !PGAutomation::ensure_store() || !-d $RUN_DIR;
    my $run = _run();
    die "run manifest unavailable\n" if ref($run) ne 'HASH' || ($run->{token} || '') ne $TOKEN;
    $ETA_HISTORY=eval {PGAutomationETA::history($RUN_ID)} || [];
    return if ($run->{status} || '') eq 'paused';
    return if ($run->{status} || '') =~ /^(?:complete|failed|stopped)$/;
    if (!open($RUNNER_LOCK, '>>', $RUNNER_LOCK_FILE) || !flock($RUNNER_LOCK, LOCK_EX | LOCK_NB)) {
        _log('another automation runner owns the runner lock');
        return;
    }
    die 'Unable to persist automation runner PID'
        if !PGAutomation::write_atomic($RUN_DIR . '/runner.pid', "$$\n", 0664);
    die 'Unable to persist automation runner startup' if !ref(_update_run(sub {
        my ($state) = @_;
        $state->{status} = 'running';
        $state->{runner_pid} = $$;
        $state->{started_at} ||= time();
        $state->{heartbeat} = time();
    }));
    die 'Unable to claim automation execution' if !_write_execution();
    _heartbeat(1);
    _log_action('Automation runner started');
    if (_control()->{request} eq 'stop') {
        $STOP_REQUESTED = 1;
        my $number = $run->{active_item};
        $number = $number->{item_number} if ref($number) eq 'HASH';
        if (defined($number) && ref($run->{items}[$number]) eq 'HASH') {
            $ACTIVE_ITEM = $run->{items}[$number];
            $ACTIVE_ITEM->{item_number} = $number;
            $ACTIVE_STAGE = $run->{active_stage} || $ACTIVE_ITEM->{active_stage} || '';
            my %workers = ('greyscale-done'=>'grey','volume-done'=>_signal($ACTIVE_ITEM) eq 'dv'?'dv':'3d',
                'pre-readings-done'=>'series','post-readings-done'=>'series');
            $ACTIVE_WORKER = $workers{$ACTIVE_STAGE} || '';
            if (ref($run->{active_series}) eq 'HASH') {
                ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE) = @{$run->{active_series}}{qw(key phase)};
            }
        }
        _stop_active();
        _restore_run_hazards($run, $run->{items});
        _finish('stopped');
        return;
    }
    $ACTIVE_STAGE = 'readiness';
    _log_action('Checking TV and meter readiness before preparing the first pending job');
    _update_run(sub {
        $_[0]{active_stage} = $ACTIVE_STAGE;
        $_[0]{stage_started_at} = time();
        $_[0]{worker_status} = {message => 'Rechecking TV and meter before the first pending job; measurement patterns have not started yet.'};
    });
    _ensure_lg_connection();
    my $readiness = _api('POST', '/api/automation/readiness', {
        items => [grep { ($_->{status} || '') !~ /^complete/ } @{$run->{items} || []}],
    });
    if ($STOP_REQUESTED) {
        _stop_active();
        _restore_run_hazards($run,$run->{items});
        _finish('stopped');
        return;
    }
    if (!$readiness->{ready}) {
        _finish('failed', { stage => 'readiness', message => $readiness->{message} || 'Automation readiness failed' });
        return;
    }
    $ACTIVE_STAGE = '';
    _log_action('Runner readiness passed; preparing the first pending job');
    _update_run(sub { $_[0]{readiness} = $readiness; $_[0]{active_stage} = ''; $_[0]{worker_status} = {}; });
    my $items = ref($run->{items}) eq 'ARRAY' ? $run->{items}
        : ref($run->{queue_snapshot}{items}) eq 'ARRAY' ? $run->{queue_snapshot}{items} : [];
    my $aborted = 0;
    for (my $i = 0; ; $i++) {
        my $claimed = _update_run(sub {
            my ($state) = @_;
            if ($i >= @{$state->{items}}) { $state->{status} = 'completing'; return; }
            return if ($state->{items}[$i]{status} || '') =~ /^complete/;
            $state->{active_item} = $i;
            $state->{items}[$i]{status} = 'running';
        });
        die 'Unable to claim next queue item' if !ref($claimed);
        $items = $claimed->{items};
        last if $i >= @$items;
        _refresh_control();
        last if $STOP_REQUESTED;
        my $item = ref($items->[$i]) eq 'HASH' ? $items->[$i] : {};
        next if ($item->{status} || '') =~ /^complete(?:-with-warnings)?$/;
        $::LAST_ERROR = '';
        my $ok = _run_item($i, $item);
        if (!$ok || $STOP_REQUESTED) {
            $aborted = 1 if !$ok;
            last;
        }
        _update_run(sub { $_[0]{items}[$i] = $item; });
    }
    if ($STOP_REQUESTED) {
        _stop_active();
        _restore_run_hazards(_run(), $items);
        _finish('stopped', { stage => $ACTIVE_STAGE || 'unknown', message => 'Automation stopped' });
        return;
    }
    my $latest = _run();
    if (($latest->{status} || '') eq 'paused') {
        return;
    }
    if (($latest->{status} || '') eq 'interrupted') {
        my $failure_stage = ref($latest->{failure}) eq 'HASH' ? ($latest->{failure}{stage} || '') : '';
        _stop_active() if $failure_stage ne 'apply-all-done' && ($ACTIVE_WORKER || ref($ACTIVE_ITEM) eq 'HASH');
        _restore_run_hazards($latest, $items);
        _park_interrupted($latest->{active_stage} || $failure_stage || 'interrupted');
        return;
    }
    if (($latest->{status} || '') eq 'failed') {
        _stop_active() if $ACTIVE_WORKER || ref($ACTIVE_ITEM) eq 'HASH';
        _restore_run_hazards($latest, $items);
        _finish('failed', $latest->{failure});
        return;
    }
    my @unfinished = grep { ref($_) eq 'HASH' && ($_->{status} || '') !~ /^complete(?:-with-warnings)?$/ } @{$latest->{items} || []};
    if ($aborted || @unfinished) {
        # _run_item returned without persisting interrupted/failed (for example
        # a snapshot write failed). Never report that as complete.
        _stop_active() if $ACTIVE_WORKER || ref($ACTIVE_ITEM) eq 'HASH';
        _restore_run_hazards($latest, $items);
        _finish('failed', { stage => $ACTIVE_STAGE || 'item', message => $::LAST_ERROR || 'An item stopped without recording its outcome' });
        return;
    }
    _restore_run_hazards($latest, $items);
    _refresh_control();
    if ($STOP_REQUESTED) { _stop_active(); _finish('stopped'); return; }
    _update_run(sub {
        my ($state) = @_;
        $state->{active_item} = undef;
        $state->{active_stage} = '';
    });
    _finish('complete');
}

# Guarded so a test can `do` this file (with @ARGV set) and call its subs
# without starting a run; both AutoCal workers and pgenerator-lg do the same.
if (!caller()) {
eval { _main(); 1 } or do {
    my $error = $@ || 'automation runner failed';
    _log($error);
    my $run = eval { _run() } || {};
    _stop_active();
    _restore_run_hazards($run, ref($run->{items}) eq 'ARRAY' ? $run->{items} : []);
    my $failure = { stage => $ACTIVE_STAGE || 'startup', message => "$error" };
    $failure->{error_code} = $::LAST_ERROR_CODE if $::LAST_ERROR_CODE;
    # Release the execution claim for every status this runner can die in
    # while it owns the run: 'starting' (a die before the startup update),
    # running, and the completing/stopping tail. A paused or interrupted run
    # is already parked in a resumable state and must stay resumable. Only a
    # manifest carrying our own token is ours to finish.
    _finish('failed', $failure)
        if ref($run) eq 'HASH' && ($run->{token} || '') eq $TOKEN
        && ($run->{status} || '') =~ /^(?:starting|running|completing|stopping)$/;
    exit 1;
};

exit 0;
}
