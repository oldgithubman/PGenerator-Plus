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
use File::Path qw(make_path remove_tree);
use JSON::PP ();
use POSIX qw(strftime);
use Time::HiRes qw(time);
use PGMath ();

our $VERSION = '1.0';

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
    eval { make_path($dir, { mode => 0775 }); 1 } or return 0;
    return -d $dir ? 1 : 0;
}

sub ensure_store {
    my @dirs = (base_dir(), recipes_dir(), queues_dir(), runs_dir());
    foreach my $dir (@dirs) {
        return 0 if !_ensure_dir($dir);
    }
    return 1;
}

sub json_encoder {
    return JSON::PP->new->canonical(1)->utf8(1);
}

sub encode_json {
    my ($value) = @_;
    return json_encoder()->encode($value);
}

sub decode_json {
    my ($text) = @_;
    return undef if !defined($text) || $text eq '';
    return eval { JSON::PP::decode_json($text) };
}

sub clone {
    my ($value) = @_;
    return undef if !defined($value);
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

sub write_atomic {
    my ($path, $data, $mode) = @_;
    return 0 if !defined($path) || !defined($data);
    my $parent = _parent_dir($path);
    return 0 if !_ensure_dir($parent);
    my $tmp = $path . '.tmp.' . $$ . '.' . _random_hex(2);
    my $ok = 0;
    if (open(my $fh, '>:raw', $tmp)) {
        $ok = print {$fh} $data;
        # Flush and fsync before the rename so a power cut on the SD card
        # cannot leave the renamed file empty.
        if ($ok) { $fh->flush; $fh->sync; }
        $ok = 0 if !$ok || !close($fh);
    }
    if ($ok && defined($mode)) {
        $ok = chmod($mode, $tmp) ? 1 : 0;
    }
    if ($ok) {
        $ok = rename($tmp, $path) ? 1 : 0;
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
    return (0, undef, "unable to lock $lock_path: $!") if !flock($lock, LOCK_EX);
    my $current = read_json_file($path);
    my ($ok, $result) = (1, undef);
    my $error = '';
    eval { $result = $callback->($current); 1 } or do { $ok = 0; $error = $@ || 'callback failed'; };
    if ($ok && defined($result) && ref($result) eq 'HASH' && exists($result->{__pg_automation_delete})) {
        $ok = unlink($path) ? 1 : (!-e $path ? 1 : 0);
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
    return 0 if !flock($lock, LOCK_EX);
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
    return !-e $dir && !@$errors;
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
