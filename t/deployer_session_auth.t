#!/usr/bin/perl
# Regression (issue #51): the Deploy Console API had no auth and SSH host-key
# checking was disabled. Now:
#   * every POST (except /api/health, a GET) requires the X-Deployer-Session
#     token; a wrong/missing token is 401, a non-loopback Host or a
#     cross-origin Origin is 403;
#   * /session.js hands the page a fresh token, no-store;
#   * ssh_base() uses StrictHostKeyChecking=yes and paramiko_client() rejects
#     unknown hosts (no AutoAddPolicy, no trust-on-first-use).
# The auth cases run against a real throwaway server on an ephemeral port;
# the host-key cases are static assertions because they need an actual Pi.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use IO::Socket::INET;

my $deployer = File::Spec->catdir($FindBin::Bin, '..', 'github-deployer');
my $server = File::Spec->catfile($deployer, 'server.py');
plan skip_all => "github-deployer/server.py not present" unless -f $server;

# --- static assertions -------------------------------------------------------
my $py = do {
    open my $fh, '<', $server or die "open $server: $!";
    local $/; <$fh>;
};
unlike($py, qr/StrictHostKeyChecking=no/, 'ssh: StrictHostKeyChecking=no gone');
like($py,   qr/StrictHostKeyChecking=yes/, 'ssh: StrictHostKeyChecking=yes set');
unlike($py, qr/AutoAddPolicy\(\)/,         'paramiko: AutoAddPolicy gone');
like($py,   qr/load_host_keys\(KNOWN_HOSTS\)/, 'paramiko: known_hosts loaded');
like($py,   qr/ssh-keyscan/,               'host-key error names ssh-keyscan');
like($py,   qr/check_local_request\(self\.headers/, 'POST gate runs in do_POST');

# --- live server -------------------------------------------------------------
my $port = do {
    my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', Listen => 1)
        or die "cannot allocate probe port: $!";
    my $p = $sock->sockport;
    $sock->close;
    $p;
};
my $token = 'probe-token-' . ('x' x 24);
local $ENV{PGEN_DEPLOYER_TOKEN} = $token;
my $pid = open my $SERVER, '-|', 'python3', $server, '--port', $port, '--no-open'
    or die "fork: $!";

sub wait_ready {
    for (1 .. 50) {
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 1);
        if ($s) { $s->close; return 1 }
        select undef, undef, undef, 0.2;
    }
    return 0;
}
plan skip_all => 'server did not start' unless wait_ready();

# raw_request(body, headers) -> (status, header_block, body)
sub raw_request {
    my ($method, $path, %opt) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1:' . $port, Timeout => 10)
        or return (0, '', '');
    my $body = $opt{body} // '';
    my @headers = ("Host: $opt{host}" , "Connection: close");
    push @headers, "Origin: $opt{origin}" if defined $opt{origin};
    push @headers, "X-Deployer-Session: $opt{token}" if defined $opt{token};
    if ($method eq 'POST') {
        push @headers, 'Content-Type: application/json', "Content-Length: " . length($body);
    }
    my $req = "$method $path HTTP/1.0\r\n" . join("\r\n", @headers) . "\r\n\r\n$body";
    print $s $req;
    local $/;
    my $res = <$s>;
    $s->close;
    $res //= '';
    my ($head, $resp_body) = split /\r\n\r\n/, $res, 2;
    my ($status) = $head =~ m{^HTTP/1\.[01] (\d{3})};
    return ($status // 0, $head, $resp_body // '');
}

my ($status) = raw_request('GET', '/api/health', host => "127.0.0.1:$port");
is($status, 200, 'health still open on loopback');

($status) = raw_request('POST', '/api/restart', host => "127.0.0.1:$port",
                        body => '{}');
is($status, 401, 'POST without session token rejected');

($status) = raw_request('POST', '/api/restart', host => "127.0.0.1:$port",
                        token => 'wrong-token-aaaaaaaaaaaaaaaa', body => '{}');
is($status, 401, 'POST with wrong session token rejected');

($status) = raw_request('POST', '/api/refs', host => "attacker.example:$port",
                        token => $token, body => '{"repository":"owner/repo"}');
is($status, 403, 'DNS-rebinding Host rejected even with the token');

($status) = raw_request('POST', '/api/refs', host => "127.0.0.1:$port",
                        origin => 'http://evil.example', token => $token,
                        body => '{"repository":"owner/repo"}');
is($status, 403, 'cross-origin request rejected even with the token');

# The token itself is valid auth: /api/refs with a bogus repo must fail later
# in the pipeline (400 from validation), proving the gate passed it through.
($status) = raw_request('POST', '/api/refs', host => "127.0.0.1:$port",
                        token => $token, body => '{"repository":"not a repo"}');
is($status, 400, 'correct token passes the gate (fails later on validation)');

my ($s2, $head, $sess_body) = raw_request('GET', '/session.js', host => "127.0.0.1:$port");
is($s2, 200, 'session.js served');
like($sess_body, qr/\Q$token\E/, 'session.js carries the startup token');
like($head,      qr/[Cc]ache-[Cc]ontrol: no-store/, 'session.js is no-store');

($s2, $head) = raw_request('GET', '/', host => "127.0.0.1:$port");
like($sess_body, qr/__PGEN_SESSION__/, 'session.js defines the token global');

# kill the throwaway server
kill 'TERM', $pid;
close $SERVER;
waitpid $pid, 0;

done_testing();
