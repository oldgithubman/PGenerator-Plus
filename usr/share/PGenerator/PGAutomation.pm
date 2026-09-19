package PGAutomation;

use strict;
use warnings;
BEGIN {
    my $directory = __FILE__;
    $directory =~ s{/[^/]+$}{};
    unshift @INC, $directory;
}

use Fcntl qw(:DEFAULT :flock);
use IO::Handle ();
use Cwd ();
use File::Find ();
use File::Path qw(make_path remove_tree);
use JSON::PP ();
use POSIX qw(strftime);
use Storable ();
use Time::HiRes qw(time);
use PGMath ();

our $VERSION = '1.1';
our $LOCK_TIMEOUT = 30;

# File locks also protect HTTP state. Never strand every polling worker on
# an abandoned or recursively acquired lock. No TV I/O belongs under one.
sub lock_exclusive {
    my ($fh, $timeout) = @_;
    $timeout = $LOCK_TIMEOUT if !defined($timeout);
    my $until = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) + $timeout;
    while (!flock($fh, LOCK_EX | LOCK_NB)) {
        return 0 if Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) >= $until;
        Time::HiRes::sleep(0.02);
    }
    return 1;
}

sub sync_directory {
    my ($dir) = @_;
    return 0 if !sysopen(my $fh, $dir, O_RDONLY);
    my $ok = eval { $fh->sync } ? 1 : 0;
    $ok = 0 if !close($fh);
    return $ok;
}

sub private_store_path {
    my ($path) = @_;
    return 0 if !defined($path);
    # Compare normalised spellings: "a//b" and "a/./b" name the same file and
    # must not escape the owner-only rule.
    my $normal = sub { my ($p) = @_; $p =~ s{/+}{/}g; 1 while $p =~ s{/\./}{/}g; $p =~ s{/+$}{}; return $p; };
    my $base = $normal->(base_dir());
    $path = $normal->($path);
    return ($path eq $base || index($path, $base . '/') == 0);
}

# Missing is not the same as unreadable/corrupt. Admission guards must fail
# closed on the latter; callers must not turn an error into an idle device.
sub read_state {
    my ($path) = @_;
    return {state=>'error', message=>'Invalid state path'} if !defined($path);
    my @st = lstat($path);
    if (!@st) {
        return {state=>'missing'} if $!{ENOENT};
        return {state=>'error', message=>"Cannot inspect state: $!"};
    }
    return {state=>'error', message=>'State is not a regular non-symlink file'} if !-f _ || -l _;
    my $value = read_json_file($path);
    return {state=>'error', message=>'State is unreadable or invalid JSON'} if ref($value) ne 'HASH';
    return {state=>'ok', value=>$value};
}

# Physical obligations, not the UI's cleanup_required latch. A successful
# retry may clear that latch only after this list is empty.
sub restoration_problems {
    my ($run) = @_;
    return ['Run manifest unavailable; recovery ownership retained'] if ref($run) ne 'HASH';
    my @problems;
    push @problems, 'Preflight output restoration is unconfirmed; retry cleanup' if $run->{preflight_restore_required};
    push @problems, 'Original viewing context restoration is pending; retry cleanup' if $run->{viewing_restore_required};
    push @problems, 'Panel protection re-enable is pending; retry cleanup'
        if ref($run->{panel_protection}) eq 'HASH' && $run->{panel_protection}{restore_pending};
    push @problems, 'Protective settings restoration is pending; retry cleanup' if $run->{hazard_restore_pending};
    for my $failure (@{$run->{hazard_restore_failures} || []}) {
        push @problems, ref($failure) eq 'HASH' ? ($failure->{key}||'Protection') . ': ' . ($failure->{message}||'restoration failed') : "$failure";
    }
    my $cleanup = $run->{stop_cleanup};
    push @problems, $cleanup->{message} || 'TV/worker cleanup is unconfirmed'
        if ref($cleanup) eq 'HASH' && !$cleanup->{verified}
            && ($cleanup->{completed_at}||0) >= ($run->{resumed_at}||0);
    return \@problems;
}

# Linux process birth identity distinguishes a reused PID from the worker
# whose status was recorded. No shell-wide name match is an ownership proof.
sub process_start_ticks {
    my ($pid)=@_;
    return '' if !defined($pid) || $pid!~/\A\d+\z/ || $pid<=1;
    my $stat=read_raw("/proc/$pid/stat");
    return '' if !defined($stat) || $stat!~/\A\d+\s+\(.*\)\s+(.*)\z/s;
    my @fields=split /\s+/,$1;
    return defined($fields[19]) && $fields[19]=~/\A\d+\z/ ? $fields[19] : '';
}

sub worker_id {
    my ($request)=@_;
    return '' if ref($request) ne 'HASH';
    my $id=$request->{automation_worker_id};
    return defined($id) && !ref($id) && length($id)<=160 ? safe_component($id) : '';
}

sub stamp_worker_state {
    my ($state,$request)=@_;
    my $id=worker_id($request);
    return $state if !$id || ref($state) ne 'HASH';
    $state->{automation_worker_id}=$id;
    $state->{worker_pid}=0+$$;
    $state->{worker_start_ticks}=process_start_ticks($$);
    return $state;
}

sub seed_worker_state_json {
    my ($raw,$body)=@_;
    my $request=decode_json($body);
    my $state=decode_json($raw);my $id=worker_id($request);
    return $raw if !$id || ref($state) ne 'HASH';
    $state->{automation_worker_id}=$id;
    my $run_id=safe_component($request->{full_autocal_run_id});
    $state->{full_autocal_run_id}=$run_id if $run_id ne '';
    $state->{worker_seeded_at}=time();
    return encode_json($state);
}

# Called only after the HTTP route's ownership guard. Replaying a completed
# start is still idempotent: it must not launch the same calibration twice.
sub worker_replay_json {
    my ($body,$path)=@_;
    my $id=worker_id(decode_json($body));return '' if !$id;
    my $state=read_json_file($path);
    return '' if ref($state) ne 'HASH' || worker_id($state) ne $id
        || ($state->{status}||'')!~/\A(?:running|setup|starting|complete|cancelled|stopped|error|failed)\z/;
    return encode_json({status=>'started',replayed=>JSON::PP::true,automation_worker_id=>$id});
}

sub base_dir {
    return $ENV{PGEN_AUTOMATION_DIR} || '/var/lib/PGenerator/automation';
}

sub recipes_dir { return base_dir() . '/recipes'; }
sub queues_dir  { return base_dir() . '/queues'; }
sub runs_dir    { return base_dir() . '/runs'; }

sub _ensure_dir {
    my ($dir) = @_;
    return 0 if !defined($dir) || $dir eq '';
    return 1 if -d $dir;
    my @created;
    eval { @created = make_path($dir, { mode => private_store_path($dir) ? 0700 : 0775 }); 1 } or return 0;
    for my $made (reverse @created) {
        return 0 if !sync_directory($made) || !sync_directory(_parent_dir($made));
    }
    return -d $dir ? 1 : 0;
}

sub ensure_store {
    my @dirs = (base_dir(), recipes_dir(), queues_dir(), runs_dir());
    foreach my $dir (@dirs) {
        return 0 if !_ensure_dir($dir);
        # Upgrade existing stores too: manifests and archived worker states
        # contain capabilities, not merely public calibration measurements.
        return 0 if !chmod(0700, $dir);
    }
    return 0 if !_privatise_existing_runs();
    return 1;
}

# Runs recorded before the store became private still hold token-bearing
# manifests at their original modes inside world-readable run directories.
# Tighten them once, best effort: an entry this user cannot chmod must never
# take the automation API down (the 0700 store root already shields it), so
# the walk always completes and always leaves its marker, which keeps it off
# the request path afterwards. The marker records how many entries it skipped.
sub _privatise_existing_runs {
    my $marker = base_dir() . '/.runs-private';
    return 1 if -e $marker;
    my $skipped = 0;
    # File::Find does not follow a symlinked root, so resolve it first.
    my $root = -l runs_dir() ? (Cwd::realpath(runs_dir()) // runs_dir()) : runs_dir();
    if (-d $root) {
        local $SIG{__WARN__} = sub {};
        File::Find::find({ no_chdir => 1, wanted => sub {
            return if -l $_;
            $skipped++ if !chmod((-d $_ ? 0700 : 0600), $_);
        } }, $root);
    }
    write_atomic($marker, "skipped $skipped\n", 0600);
    return 1;
}

sub json_encoder {
    # allow_nonref: JSON::PP 2.27 on the appliance rejects plain scalars by
    # default; 4.x (macOS, CI) accepts them, which hid this difference.
    return JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(1);
}

sub encode_json {
    my ($value) = @_;
    return json_encoder()->encode($value);
}

sub decode_json {
    my ($text) = @_;
    return undef if !defined($text) || $text eq '';
    # Same non-ref policy as the encoder, so a bare scalar written on the
    # appliance reads back as itself rather than as undef.
    return eval { JSON::PP->new->utf8(1)->allow_nonref(1)->decode($text) };
}

sub clone {
    my ($value) = @_;
    return undef if !defined($value);
    # A plain scalar is already a copy; only references need the round trip.
    return $value if !ref($value);
    return decode_json(encode_json($value));
}

sub safe_component {
    my ($value) = @_;
    return '' if !defined($value) || ref($value);
    return '' if $value eq '' || $value !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
    return '' if $value eq '.' || $value eq '..';
    return $value;
}

sub _parent_dir {
    my ($path) = @_;
    my $parent = $path;
    $parent =~ s{/[^/]+$}{};
    return $parent || '/';
}

sub _random_hex {
    my ($bytes) = @_;
    $bytes = 3 if !defined($bytes) || $bytes < 1;
    my $out = '';
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        my $raw = '';
        my $read = read($fh, $raw, $bytes);
        close($fh);
        $out = unpack('H*', $raw) if defined($read) && $read == $bytes;
    }
    if ($out eq '') {
        $out = unpack('H*', pack('L!', int(rand(0xffffffff)))) . unpack('H*', pack('L!', $$));
    }
    return substr($out, 0, $bytes * 2);
}

sub new_id {
    return strftime('%Y%m%d-%H%M%S', localtime(time())) . '-' . _random_hex(3);
}

sub read_raw {
    my ($path) = @_;
    return undef if !defined($path) || !-f $path;
    return undef if !open(my $fh, '<:raw', $path);
    local $/;
    my $data = <$fh>;
    my $closed = close($fh);
    return undef if !$closed;
    return $data;
}

sub read_json_file {
    my ($path) = @_;
    my $raw = read_raw($path);
    return undef if !defined($raw);
    return decode_json($raw);
}

# Fractional mtime where the platform gives one (Time::HiRes on Linux), so two
# files written within the same second still order correctly.
sub file_mtime {
    my ($path) = @_;
    my @st = Time::HiRes::stat($path);
    return @st ? $st[9] : undef;
}

# JSON::PP on the appliance decodes at roughly 100 KB/s. A status poll that
# decodes the same unchanged file every few seconds is pure waste, so keep the
# last decoded value per path and reuse it while the file's identity (inode,
# size, mtime; every writer here renames a fresh file into place) is the same.
# Callers get their own deep copy: the cached value is never handed out.
my %JSON_CACHE;
# Bounded by bytes of JSON held, not by entry count: every daemon worker
# thread holds its own cache for as long as the daemon runs. A single file
# over the per-file limit is never kept; when the total passes the budget the
# least recently used entries go first. A run manifest (a few hundred KB
# while a batch runs) fits; the live and preflight status files are small.
our $JSON_CACHE_MAX_BYTES = 1048576;
our $JSON_CACHE_BUDGET_BYTES = 3145728;
sub read_json_cached {
    my ($path) = @_;
    return undef if !defined($path) || $path eq '';
    my @st = Time::HiRes::stat($path);
    return undef if !@st;
    if ($st[7] > $JSON_CACHE_MAX_BYTES) {
        delete $JSON_CACHE{$path};
        return eval { read_json_file($path) };
    }
    my $key = join(':', $st[1], $st[7], $st[9]);
    my $entry = $JSON_CACHE{$path};
    if (!$entry || $entry->{key} ne $key) {
        my $value = eval { read_json_file($path) };
        return undef if !defined($value);
        delete $JSON_CACHE{$path};
        my $held = 0;
        $held += $JSON_CACHE{$_}{bytes} for keys %JSON_CACHE;
        for my $oldest (sort { $JSON_CACHE{$a}{used} <=> $JSON_CACHE{$b}{used} } keys %JSON_CACHE) {
            last if $held + $st[7] <= $JSON_CACHE_BUDGET_BYTES;
            $held -= $JSON_CACHE{$oldest}{bytes};
            delete $JSON_CACHE{$oldest};
        }
        $entry = $JSON_CACHE{$path} = { key => $key, value => $value, bytes => $st[7] };
    }
    $entry->{used} = time();
    return ref($entry->{value}) ? Storable::dclone($entry->{value}) : $entry->{value};
}

# The live view of a run: what a status poll needs and nothing that grows.
# WORKER_STATUS_SUMMARY_KEYS are the calibration worker status fields the
# runner reads while it waits, those its stage callers gate on when a summary
# has to stand in for the full state, and those the daemon's status fix-ups
# touch. Each worker writes them to a .summary sidecar beside its state file
# and the status routes serve them for ?view=summary.
# WORKER_ACTIVITY_EVENT_LIMIT is how many activity events a worker keeps; the
# summary keeps the same.
our @WORKER_STATUS_SUMMARY_KEYS = qw(
    status current_name current_step total_steps current_delta_e message error_code debug phase
    automation_worker_id worker_pid worker_start_ticks activity_sequence activity_events
    started_at completed_at elapsed_ms autocal calibration_mode
    full_workflow full_autocal_run_id full_autocal_phase
    final_1d_lut_uploaded final_1d_lut_upload_verified
    upload_verified terminal_commit_verified tone_map_upload_status tone_map_upload_error_code
    ddc_upload_verified failure_detail upload_retry_available
    automation_processing_checks automation_processing_warnings
);
our $WORKER_ACTIVITY_EVENT_LIMIT = 64;

sub worker_status_summary {
    my ($state) = @_;
    return {} if ref($state) ne 'HASH';
    my %summary = map { exists($state->{$_}) ? ($_ => $state->{$_}) : () } @WORKER_STATUS_SUMMARY_KEYS;
    if (ref($summary{activity_events}) eq 'ARRAY' && @{$summary{activity_events}} > $WORKER_ACTIVITY_EVENT_LIMIT) {
        $summary{activity_events} = [ @{$summary{activity_events}}[-$WORKER_ACTIVITY_EVENT_LIMIT .. -1] ];
    }
    return \%summary;
}

# The runner publishes it as status.json after every manifest write; the
# daemon materialises it once for a run no runner is alive to publish for.
# RUN_LIVE_KEYS are the fields a heartbeat or progress tick may overlay.
our @RUN_LIVE_KEYS = qw(heartbeat heartbeat_at runner_pid active_item active_stage worker_status operation_progress time_estimate);
our @RUN_STATUS_KEYS = qw(id token launch_attempt status queue_name queue_id finish_policy preflight_only
    created_at created_at_iso started_at resumed_at paused_at interrupted_at completed_at
    stage_started_at checkpoint checkpoint_status last_checkpoint
    failure warnings cleanup_required stop_cleanup cleanup_failure original_failure pending_terminal_status
    preflight_restore_required viewing_restore_required viewing_restore_outcome preflight_restore_outcome
    hazard_restore_pending hazard_restore_failures hazard_restore_unverified panel_protection
    preflight_in_progress preflight_revision queue_revision live_view_cleared_at startup_events readiness);
sub compact_item {
    my ($item) = @_;
    return {} if ref($item) ne 'HASH';
    my %compact = map { exists($item->{$_}) ? ($_ => $item->{$_}) : () }
        qw(id name picture_mode signal_format status failure warnings checkpoint checkpoint_status active_stage stage_started_at stages);
    $compact{checkpoints} = [map { my $c = $_; ref($c) eq 'HASH'
        ? {map { exists($c->{$_}) ? ($_ => $c->{$_}) : () } qw(name status verified completed_at duration_seconds)} : () } @{$item->{checkpoints} || []}]
        if ref($item->{checkpoints}) eq 'ARRAY';
    if (ref($item->{readiness}) eq 'HASH') {
        my %readiness = %{$item->{readiness}};
        $readiness{checks} = [grep { ref($_) eq 'HASH' && !$_->{ok} } @{$readiness{checks} || []}];
        $compact{readiness} = \%readiness;
    }
    return \%compact;
}
sub compact_run {
    my ($run) = @_;
    return {} if ref($run) ne 'HASH';
    my %compact = map { exists($run->{$_}) ? ($_ => $run->{$_}) : () } (@RUN_STATUS_KEYS, @RUN_LIVE_KEYS);
    if (ref($run->{preflight_result}) eq 'HASH') {
        my %result = %{$run->{preflight_result}};
        delete $result{checks};
        $compact{preflight_result} = \%result;
    }
    $compact{items} = [map { compact_item($_) } @{ref($run->{items}) eq 'ARRAY' ? $run->{items} : []}];
    return \%compact;
}

sub write_atomic {
    my ($path, $data, $mode) = @_;
    return 0 if !defined($path) || !defined($data);
    my $parent = _parent_dir($path);
    return 0 if !_ensure_dir($parent);
    my $tmp = $path . '.tmp.' . $$ . '.' . _random_hex(8);
    $mode = private_store_path($path) ? 0600 : (defined($mode) ? $mode : 0664);
    my $ok = 0;
    # Never expose a newly created credential file through the process umask,
    # and never follow an existing temporary-file symlink.
    if (sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
        binmode($fh, ':raw');
        $ok = (print {$fh} $data) && chmod($mode, $tmp);
        if ($ok) { $ok = eval { $fh->flush && $fh->sync } ? 1 : 0; }
        $ok = 0 if !close($fh);
    }
    if ($ok) {
        # Prove the parent can be opened for fsync before publishing. An
        # unreadable parent used to fail after the rename, reporting a write
        # that was already visible as failed.
        $ok = sysopen(my $dirfh, $parent, O_RDONLY) ? 1 : 0;
        close($dirfh) if $dirfh;
        $ok = rename($tmp, $path) && sync_directory($parent) ? 1 : 0 if $ok;
    }
    unlink($tmp) if -e $tmp;
    return $ok;
}

sub write_json_atomic {
    my ($path, $value, $mode) = @_;
    return write_atomic($path, encode_json($value), $mode);
}

sub with_lock {
    my ($path, $callback) = @_;
    return (0, undef, 'invalid lock request') if !defined($path) || ref($callback) ne 'CODE';
    my $lock_path = $path . '.lock';
    my $parent = _parent_dir($lock_path);
    return (0, undef, "unable to create $parent") if !_ensure_dir($parent);
    return (0, undef, "unable to open $lock_path: $!") if !open(my $lock, '>>', $lock_path);
    return (0, undef, "timed out locking $lock_path") if !lock_exclusive($lock);
    my $current = read_json_file($path);
    my ($ok, $result) = (1, undef);
    my $error = '';
    eval { $result = $callback->($current); 1 } or do { $ok = 0; $error = $@ || 'callback failed'; };
    if ($ok && defined($result) && ref($result) eq 'HASH' && exists($result->{__pg_automation_delete})) {
        $ok = (!-e $path || unlink($path)) && sync_directory(_parent_dir($path)) ? 1 : 0;
        $error = "unable to durably remove $path" if !$ok;
        $result = undef;
    } elsif ($ok && defined($result)) {
        $ok = write_json_atomic($path, $result, 0664);
        $error = "unable to write $path" if !$ok;
    }
    flock($lock, LOCK_UN);
    close($lock);
    return ($ok, $result, $error);
}

sub append_line_locked {
    my ($path, $line) = @_;
    return 0 if !defined($path) || !defined($line);
    my $lock_path = $path . '.lock';
    my $parent = _parent_dir($path);
    return 0 if !_ensure_dir($parent);
    return 0 if !open(my $lock, '>>', $lock_path);
    return 0 if !lock_exclusive($lock);
    my $ok = 0;
    if (open(my $fh, '>>:raw', $path)) {
        $ok = print {$fh} $line;
        $ok = 0 if !$ok || !close($fh);
    }
    flock($lock, LOCK_UN);
    close($lock);
    return $ok;
}

sub list_json_files {
    my ($dir) = @_;
    return () if !defined($dir) || !opendir(my $dh, $dir);
    my @names = sort grep { /^[A-Za-z0-9][A-Za-z0-9_.-]*\.json$/ && -f "$dir/$_" } readdir($dh);
    closedir($dh);
    return @names;
}

sub list_dirs {
    my ($dir) = @_;
    return () if !defined($dir) || !opendir(my $dh, $dir);
    my @names = sort grep { /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ && -d "$dir/$_" } readdir($dh);
    closedir($dh);
    return @names;
}

sub list_run_ids {
    return list_dirs(runs_dir());
}

sub run_dir {
    my ($run_id) = @_;
    my $safe = safe_component($run_id);
    return '' if $safe eq '';
    return runs_dir() . '/' . $safe;
}

sub item_dir {
    my ($run_id, $item_number) = @_;
    my $run = run_dir($run_id);
    return '' if $run eq '' || !defined($item_number) || $item_number !~ /^\d+$/;
    return $run . '/items/' . int($item_number);
}

sub pid_is_live {
    my ($pid, $needle) = @_;
    return 0 if !defined($pid) || $pid !~ /^\d+$/ || int($pid) <= 1;
    return 0 if !-d "/proc/$pid";
    return 1 if !defined($needle) || $needle eq '';
    my $cmd = read_raw("/proc/$pid/cmdline");
    return 0 if !defined($cmd);
    $cmd =~ s/\0/ /g;
    return $cmd =~ /\Q$needle\E/ ? 1 : 0;
}

sub copy_artifact {
    my ($source, $destination, $mode) = @_;
    my $raw = read_raw($source);
    return 0 if !defined($raw);
    return write_atomic($destination, $raw, defined($mode) ? $mode : 0664);
}

sub remove_run {
    my ($run_id) = @_;
    my $dir = run_dir($run_id);
    return 0 if $dir eq '' || !-d $dir;
    my $errors;
    remove_tree($dir, { error => \$errors });
    return !-e $dir && !@$errors && sync_directory(runs_dir());
}

sub now {
    return time();
}

sub quality_summary {
    my ($snapshot, $formula, $white) = @_;
    $white = {x => 0.3127, y => 0.3290} if ref($white) ne 'HASH';
    my (@values, $missing);
    $missing = 0;
    my $number = sub { defined($_[0]) && !ref($_[0]) && "$_[0]" =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i };
    my $reference = ref($snapshot->{white_reading}) eq 'HASH' ? $snapshot->{white_reading} : {};
    my $white_y = $reference->{Y} // $reference->{luminance};
    foreach my $reading (@{$snapshot->{readings} || []}) {
        next if ref($reading) ne 'HASH';
        my $scale = $reading->{series_target_white_y} || $white_y;
        my $x = $reading->{target_x} // $white->{x};
        my $y = $reading->{target_y} // $white->{y};
        my $target = $reading->{custom_target_nits};
        $target = $reading->{target_Yn} * $scale
            if !$number->($target) && $number->($reading->{target_Yn}) && $number->($scale);
        if (grep { !$number->($_) } ($reading->{X}, $reading->{Y}, $reading->{Z}, $x, $y, $target, $scale)) {
            $missing++; next;
        }
        if ($y <= 0 || $scale <= 0 || $target < 0) { $missing++; next; }
        my $xyz = [$target * $x / $y, $target, $target * (1 - $x - $y) / $y];
        my $value;
        if ($formula eq 'deitp') {
            $value = PGMath::delta_e_itp_xyz(@$reading{qw(X Y Z)}, @$xyz);
        } elsif ($formula eq 'de2000') {
            my $reference_white = [$scale * $white->{x} / $white->{y}, $scale,
                $scale * (1 - $white->{x} - $white->{y}) / $white->{y}];
            $value = PGMath::delta_e_2000_xyz([@$reading{qw(X Y Z)}], $xyz, $reference_white);
        }
        if (!$number->($value)) { $missing++; next; }
        push @values, $value;
    }
    return (undef, undef, 0, $missing) if !@values;
    my $sum = 0; $sum += $_ for @values;
    my ($maximum) = sort {$b <=> $a} @values;
    return ($sum / @values, $maximum, scalar(@values), $missing);
}

1;
