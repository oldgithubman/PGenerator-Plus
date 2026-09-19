package PGCalibrationLog;
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock);
use JSON::PP ();
use MIME::Base64 ();
use POSIX qw(strftime);
use Time::HiRes ();
use PGAutomation ();

# Context contains identifiers only: never copy configuration, credentials or
# arbitrary paths into a trace header. Dynamic scope isolates daemon threads
# and nests meter/TV operations beneath their caller without changing results.
our $CONTEXT = {};
our $MAX_BYTES = 16 * 1024 * 1024;
our $SINK;
our $WARN_SINK;
my $sequence = 0;
my %warned;
my $json = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(1);

sub monotonic { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) }
sub elapsed_ms { int((monotonic() - $_[0]) * 1000 + 0.5) }
sub timestamp {
    my $t = defined($_[0]) ? $_[0] : Time::HiRes::time();
    return strftime('%Y-%m-%dT%H:%M:%S', gmtime($t)).sprintf('.%03dZ',int(($t-int($t))*1000));
}
sub context {
    my ($source) = @_;
    return {} if ref($source) ne 'HASH';
    my %out;
    for my $key (qw(run stage worker op parent)) {
        my $v = $source->{$key};
        $out{$key} = "$v" if defined($v) && !ref($v) && $v =~ /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}\z/;
    }
    delete $out{run} if exists($out{run}) && PGAutomation::safe_component($out{run}) ne $out{run};
    for my $key (qw(job attempt)) {
        my $v = $source->{$key};
        $out{$key} = 0+$v if defined($v) && !ref($v) && $v =~ /\A\d{1,6}\z/;
    }
    if (defined($source->{patch}) && !ref($source->{patch})) {
        ($out{patch} = substr($source->{patch},0,100)) =~ s/[\x00-\x1f\x7f]/ /g;
    }
    return \%out;
}
sub from_config {
    my ($config) = @_;
    return context($CONTEXT) if ref($config) ne 'HASH';
    my $c = context($config->{calibration_trace});
    $c->{worker} = $config->{automation_worker_id} if PGAutomation::worker_id($config);
    return context({%$c,%{context($CONTEXT)}});
}
sub child_context {
    my ($base) = @_;
    my $c = context($base);
    $c->{parent} = $c->{op} if $c->{op};
    $c->{op} = sprintf('%x-%x-%x', $$, int(Time::HiRes::time()*1000000), ++$sequence);
    return $c;
}
sub header_value { MIME::Base64::encode_base64($json->encode(context($CONTEXT)), '') }
sub header_line { 'X-PGenerator-Trace: '.header_value()."\r\n" }
sub from_header {
    my ($value) = @_;
    return {} if !defined($value) || length($value)>2048 || $value !~ /\A[A-Za-z0-9+\/=]+\z/;
    return context(eval { $json->decode(MIME::Base64::decode_base64($value)) });
}

# Keep diagnostic records bounded. Large arrays stay in their existing
# artifacts; log their size and a sample. Redact credentials recursively.
sub compact {
    my ($v,$depth) = @_; $depth ||= 0;
    return '[depth limit]' if $depth>5;
    if (ref($v) eq 'HASH') {
        my %out;
        my @keys = sort keys %$v;
        for my $key (@keys[0..($#keys<31?$#keys:31)]) {
            $out{$key} = $key =~ /token|password|secret|client.?key|authorization/i
                ? '[redacted]' : compact($v->{$key},$depth+1);
        }
        $out{omitted_fields} = @keys-32 if @keys>32;
        return \%out;
    }
    if (ref($v) eq 'ARRAY') {
        return [map {compact($_,$depth+1)} @$v] if @$v<=12;
        return {count=>scalar(@$v),sample=>[map {compact($_,$depth+1)} @$v[0..5]]};
    }
    return $v if ref($v) eq 'JSON::PP::Boolean' || !defined($v);
    return '[unsupported value]' if ref($v);
    my $s = "$v";
    return substr($s,0,509).'...' if length($s)>512;
    return $s if $s =~ s/[\x00-\x1f\x7f]/ /g;
    return $v;
}

sub _warn {
    my ($path,$reason) = @_;
    return if $warned{$path}++;
    eval {
        my $message='Diagnostics unavailable: '.$reason;
        if (ref($WARN_SINK) eq 'CODE') { $WARN_SINK->($message); }
        else { print STDERR '['.timestamp()."] $message\n"; }
        1;
    };
}
sub event {
    # A failed diagnostic sink must not alter an API result or a pending
    # exception. This also covers record construction and test/custom sinks.
    local ($@,$!,$?);
    my $ok=eval { _event_impl(@_) };
    _warn('event',$@) if $@;
    return $ok ? 1 : 0;
}
sub _event_impl {
    my ($source,$event,$fields,$ctx) = @_;
    my $c = context($ctx || $CONTEXT);
    my $record = {%{compact($fields||{})},time=>timestamp(),source=>$source,event=>$event,%$c};
    return $SINK->($record) if ref($SINK) eq 'CODE';
    return 1 if !$c->{run};
    # Never create a run from a request header, follow a symlink or let an
    # invalid job number turn a diagnostic write into an arbitrary path.
    my $dir = PGAutomation::run_dir($c->{run});
    return 0 if !-d $dir || -l $dir || -l PGAutomation::runs_dir();
    if (exists($c->{job})) {
        return 0 if $c->{job}<1;
        return 0 if -l "$dir/items";
        $dir .= '/items/'.($c->{job}-1);
        return 0 if !-d $dir || -l $dir;
    }
    my $path = "$dir/diagnostics.ndjson";
    return 1 if -e "$path.full";
    my $ok = eval {
        sysopen(my $fh,$path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600) or die "open: $!";
        if (!PGAutomation::lock_exclusive($fh,0.05)) { close($fh); die "writer busy"; }
        if (-e "$path.full") { close($fh); return 1; }
        my $size = (stat($fh))[7];
        my $line = $json->encode($record)."\n";
        if ($size+length($line)>$MAX_BYTES) {
            $line = $json->encode({time=>timestamp(),source=>'Diagnostics',event=>'retention-limit',%$c,
                limit_bytes=>$MAX_BYTES,message=>'Diagnostic limit reached; worker logs and measurement artifacts retained'})."\n";
            _warn($path,'per-job diagnostic limit reached');
            sysopen(my $full,"$path.full",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600)
                or die "retention marker: $!";
            close($full);
        }
        print {$fh} $line or die "write: $!";
        close($fh) or die "close: $!";
        1;
    };
    _warn($path,$@||'write failed') if !$ok;
    return $ok ? 1 : 0;
}

# Polls carry correlation but produce no routine events. A failed or slow
# poll still records its result; writes get begin/end records so a crash
# cannot make an unacknowledged write look like an operation never sent.
sub api_call {
    my ($source,$base,$method,$path,$payload,$timeout,$call) = @_;
    local $CONTEXT = child_context($base);
    my $poll = $method eq 'GET' && $path =~ m{/(?:status|result|current)(?:\?|$)};
    my %detail = (method=>$method,path=>$path);
    $detail{timeout_s}=$timeout if defined($timeout);
    if (ref($payload) eq 'HASH') {
        for my $key (qw(request_id name delay_ms read_timeout)) {
            $detail{$key}=$payload->{$key} if defined($payload->{$key}) && !ref($payload->{$key});
        }
    }
    event($source,'request-start',\%detail) if !$poll;
    my $started=monotonic();
    my $result=eval {$call->()}; my $error=$@;
    my $ms=elapsed_ms($started);
    my $status=ref($result) eq 'HASH' ? ($result->{status}||'unknown') : 'invalid-response';
    my $delivery=ref($result) eq 'HASH' ? $result->{delivery_state} : undef;
    my $message=ref($result) eq 'HASH' ? $result->{message}||'' : '';
    $delivery='outcome-unknown' if !defined($delivery) && $method ne 'GET'
        && ($error || ref($result) ne 'HASH' || $result->{_transport_error}
            || ($result->{error_code}||'') eq 'stopped' || $status =~ /cancelled|canceled|stopped/
            || $message =~ /timed out|unavailable|invalid .*response|read failed|\bcancell?ed\b/i);
    if (!$poll || $error || $status =~ /error|failed|cancelled/ || $ms>=5000) {
        event($source,'request-end',{%detail,elapsed_ms=>$ms,status=>$error?'exception':$status,
            (ref($result) eq 'HASH' ? (map {exists($result->{$_})?($_=>$result->{$_}):()} qw(error_code delivery_state request_id message)) : ()),
            (defined($delivery)?(delivery_state=>$delivery):()),
            ($error ? (error=>$error) : ())});
    }
    die $error if $error;
    return $result;
}

sub measurement {
    my ($source,$base,$step,$attempt,$call) = @_;
    local $CONTEXT=child_context({%{context($base)},patch=>$step->{name}||$step->{kind}||'patch',
        (defined($attempt)?(attempt=>$attempt):())});
    event($source,'measurement-start',{ire=>$step->{ire}});
    my $started=monotonic();
    my @result=eval {$call->()}; my $error=$@;
    my $reading=$result[0];
    my %values;
    if (ref($reading) eq 'HASH') {
        for my $key (qw(X Y Z x y luminance request_id sample_count timing_ms)) {
            $values{$key}=$reading->{$key} if exists($reading->{$key});
        }
    }
    event($source,'measurement-end',{elapsed_ms=>elapsed_ms($started),%values,
        status=>$error || $result[1] ? 'error' : $reading ? 'measured' : 'no-reading',
        ($error || $result[1] ? (reason=>$error||$result[1]) : ())});
    die $error if $error;
    return @result;
}
1;
