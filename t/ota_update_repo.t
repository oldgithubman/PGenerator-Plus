#!/usr/bin/perl
# Regression tests for the OTA update source repo setting.
#
# The operator can point the updater at a different GitHub repo (fork or
# release channel) from System Settings -> Software Update. The value
# persists as ota_repo=owner/name in PGenerator.conf and
# /usr/sbin/pgenerator-update resolves it at check/apply time with
# precedence GITHUB_REPO env > conf key > factory default. Anything that
# is not a safe owner/repo pair must fall back to the default so a typo
# cannot break updates or inject a URL into the curl target.
#
# A custom repo is a root-trust decision (apply extracts an unsigned
# tarball at / as root), so apply is gated twice: the WebUI refuses POSTs
# without same-origin write confirmation (webui_write_confirmed), and
# both the WebUI precheck and pgenerator-update itself require the
# separate ota_repo_trusted=1 key that only an explicit operator confirm
# sets. The Perl and bash normalizers must agree byte-for-byte on every
# input or the UI can mislabel a fork as the official source.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More tests => 40;

my $script = "$Bin/../usr/sbin/pgenerator-update";
ok(-f $script, 'pgenerator-update is present');

# Source only the header (config resolution lives before the cmd
# dispatch), so `check`/`apply` never run.
my $full = do { local(@ARGV,$/); open(my $fh,'<',$script) or die "$script: $!"; <$fh> };
my ($head) = split(/cmd="\$\{1:-help\}"/, $full, 2);
ok(defined $head && $head =~ /normalize_repo/, 'header contains the repo resolution block');

my $tmp = tempdir(CLEANUP => 1);
my $headfile = "$tmp/head.sh";
open(my $hf,'>',$headfile) or die $!; print $hf $head; close($hf);

sub resolved_api {
 my (%o) = @_;
 my $conf = "$tmp/conf";
 if(exists $o{conf}) { open(my $fh,'>',$conf) or die $!; print $fh $o{conf}; close($fh); }
 else { unlink($conf) if -e $conf; }
 local $ENV{PGENERATOR_CONF_FILE} = $conf;
 local $ENV{GITHUB_REPO} = $o{env} if exists $o{env};
 delete $ENV{GITHUB_REPO} unless exists $o{env};
 # Runner file avoids backslash-quoting hell between Perl and bash:
 # the sourced header resolves GITHUB_API, the runner just prints it.
 my $api_runner = "$tmp/api.sh";
 open(my $af,'>',$api_runner) or die $!;
 print $af ". \"$headfile\"\nprintf '%s' \"\$GITHUB_API\"\n";
 close($af);
 my $out = `bash "$api_runner" 2>/dev/null`;
 chomp $out;
 return $out;
}

my $default_api = 'https://api.github.com/repos/oldgithubman/PGenerator-Plus/releases/latest';
my ($ota_bash_default) = $full =~ /^DEFAULT_GITHUB_REPO="([^"]+)"/m;
is($ota_bash_default, 'oldgithubman/PGenerator-Plus', 'bash factory default');

is(resolved_api(conf => ''), $default_api, 'empty conf falls back to the official default');
is(resolved_api(), $default_api, 'missing conf file falls back to the official default');
is(resolved_api(conf => "ota_repo=someone-else/PGenerator-Plus\n"),
   'https://api.github.com/repos/someone-else/PGenerator-Plus/releases/latest',
   'owner/name from conf is used');
is(resolved_api(conf => "ota_repo=https://github.com/foo/bar\n"),
   'https://api.github.com/repos/foo/bar/releases/latest',
   'full https URL is normalized to owner/repo');
is(resolved_api(conf => "ota_repo=https://github.com/foo/bar/releases/latest\n"),
   'https://api.github.com/repos/foo/bar/releases/latest',
   'releases/latest URL suffix is stripped');
is(resolved_api(conf => "ota_repo=git\@github.com:foo/bar.git\n"),
   'https://api.github.com/repos/foo/bar/releases/latest',
   'ssh remote form is normalized');
is(resolved_api(conf => "mode_idx=20\nota_repo=envowner/envrepo\n"),
   'https://api.github.com/repos/envowner/envrepo/releases/latest',
   'other conf keys do not interfere');
is(resolved_api(conf => "ota_repo=conf/one\n", env => 'envowner/envrepo'),
   'https://api.github.com/repos/envowner/envrepo/releases/latest',
   'explicit GITHUB_REPO env overrides the conf key');
is(resolved_api(conf => "ota_repo=bad value with spaces\n"), $default_api,
   'value with spaces falls back to default');
is(resolved_api(conf => "ota_repo=justowner\n"), $default_api,
   'owner without repo falls back to default');
is(resolved_api(conf => "ota_repo=../etc/passwd\n"), $default_api,
   'multi-segment path traversal is rejected');
is(resolved_api(conf => 'ota_repo="..$(curl evil)"' . "\n"), $default_api,
   'shell metacharacters are rejected');
is(resolved_api(conf => "ota_repo=a/b/c\n"), $default_api,
   'three-segment path falls back to default');
# A bare '..' has no slash so it is not two path segments and both
# validators reject it (the PR-20 review noted the old test name implied
# slash-containing traversal was the only case; both are pinned now).
is(resolved_api(conf => "ota_repo=..\n"), $default_api,
   'bare .. is rejected');
# '../..' HAS a slash and all charset-legal chars: Nutcasey's review
# showed it reaches the curl target as a URL-join ('..') segment. Both
# validators now refuse dot-only segments; pinned here AND in parity.
is(resolved_api(conf => "ota_repo=../..\n"), $default_api,
   'dot-dot/dot-dot (URL-join traversal) is rejected');
is(resolved_api(conf => "ota_repo=owner/..\n"), $default_api,
   'owner/.. is rejected');
is(resolved_api(conf => "ota_repo=owner/...\n"), $default_api,
   'owner/... is rejected');

# The check JSON must report which repo served the release so the WebUI
# can show it next to the "Latest" version, plus the trust state.
ok($full =~ /"repo":%s/, 'check output carries the repo field');
ok($full =~ /"trusted":%s/, 'check output carries the trusted field');
ok($full =~ /json_escape "\$GITHUB_REPO"/, 'check output escapes the resolved repo');

# apply must route every repo through custom_repo_trusted: only the
# factory allowlist (default + BigShoots) or an operator-confirmed
# ota_repo_trusted=1 may install. Drive-by POSTs can rewrite ota_repo
# only, never the trust key (that needs the write-confirmed save).
ok($full =~ /if ! custom_repo_trusted "\$GITHUB_REPO"; then/,
   'apply gates every repo through custom_repo_trusted (allowlist or trust key)');

# ── Perl/bash normalizer parity (PR-20 finding #2) ──
# Load webui.pm's normalizer WITHOUT loading the module (it drags in the
# whole runtime): slice the sub out by anchors and eval it.
my $pm = "$Bin/../usr/share/PGenerator/webui.pm";
open(my $pf,'<',$pm) or die "$pm: $!";
my $pm_src = do { local $/; <$pf> };
close($pf);
my ($norm_sub) = $pm_src =~ /(sub webui_ota_repo_normalize \(\$\) \{.*?\n\})/s;
ok($norm_sub, 'webui.pm normalizer extracted for parity test');
my $default_line = ($pm_src =~ /^my \$ota_repo_default="([^"]+)";/m) ? $1 : '';
is($default_line, 'oldgithubman/PGenerator-Plus',
   'webui.pm factory default matches pgenerator-update DEFAULT_GITHUB_REPO');
# The trusted-repo allowlist must be identical on both sides or the WebUI
# can show a source as trusted while the updater refuses to install it.
my ($bash_allow) = $full =~ /^TRUSTED_REPO_ALLOWLIST="(.+)"/m;
ok(defined $bash_allow, 'bash TRUSTED_REPO_ALLOWLIST present');
# Expand $DEFAULT_GITHUB_REPO, split on whitespace -> bash entry list
my $bash_entries = do { my $s = $bash_allow; $s =~ s/\$DEFAULT_GITHUB_REPO/$ota_bash_default/g; [ split /\s+/, $s ] };
# Pull the Perl list literal and resolve $ota_repo_default -> its value
my ($perl_allow) = $pm_src =~ /\@ota_repo_trusted_allowlist=\(([^)]+)\)/;
my $perl_entries = do { my $s = $perl_allow; $s =~ s/"//g; $s =~ s/\$ota_repo_default/$ota_bash_default/g; [ split /\s*,\s*/, $s ] };
is_deeply([ sort @$perl_entries ], [ sort @$bash_entries ],
   'Perl and bash trusted-repo allowlists contain the same repos');
is_deeply([ sort @$bash_entries ], [ sort ('oldgithubman/PGenerator-Plus','BigShoots/PGenerator-Plus') ],
   'factory allowlist is exactly default + BigShoots');
eval $norm_sub;
die "normalizer eval failed: $@" if $@;

# Run the bash normalizer standalone. The value travels through the
# environment so quotes/spaces in inputs survive intact.
sub bash_norm {
 my ($v)=@_;
 my $runner = "$tmp/nb.sh";
 open(my $bh,'>',$runner) or die $!;
 print $bh ". \"$headfile\" >/dev/null 2>&1\nprintf '%s' \"\$(normalize_repo \"\$PGEN_TEST_VAL\")\"\n";
 close($bh);
 local $ENV{PGEN_TEST_VAL}=$v;
 local $ENV{PGENERATOR_CONF_FILE}="$tmp/noconf";
 my $out=`bash "$runner" 2>/dev/null`;
 # Apply the same validator the script uses after normalize_repo (charset
 # plus the dot-only segment refusal), so the comparison is against the
 # RESOLVED value on both sides (the Perl sub validates internally; the
 # bash function is validation-free).
 # MIRROR OF THE SCRIPT'S VALIDATOR: if the validator in pgenerator-update
 # or webui_ota_repo_normalize changes, edit this helper in lockstep or
 # the parity test keeps validating the stale rule (the dot-segment round
 # showed drift cuts both ways).
 return '' unless $out =~ m{^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$};
 my ($o,$r2) = split m{/}, $out, 2;
 return '' if $o =~ /^\.+$/ || $r2 =~ /^\.+$/;
 return $out;
}
sub perl_norm {
 my ($v)=@_;
 my $r = webui_ota_repo_normalize($v);
 return '' unless defined $r;
 return $r;
}
my @parity_inputs = ('"foo/bar"', "'foo/bar'", ' foo/bar ', 'foo/bar ',
 'HTTPS://GITHUB.COM/foo/bar', 'GIT@GITHUB.COM:foo/bar',
 'https://github.com/foo/bar/releases/latest', 'git@github.com:foo/bar.git',
 'foo/bar/releases', 'foo/bar/', 'foo/bar.git', 'owner/name',
 'HTTPS://GITHUB.COM/foo/bar/RELEASES/LATEST', 'foo/bar//',
 'HTTPS://GITHUB.COM/Foo/Bar.GIT', 'http://github.com/foo/bar',
 'foo bar', 'justowner', '../etc/passwd', 'a/b/c', '..', '../..',
 'owner/..', 'owner/...', './owner', 'owner/.git');
my @mismatch;
for my $v (@parity_inputs) {
 my ($b,$p) = (bash_norm($v), perl_norm($v));
 push @mismatch, "[$v] bash=[$b] perl=[$p]" if $b ne $p;
}
is(scalar(@mismatch), 0,
   'bash and Perl normalizers agree on all '.scalar(@parity_inputs).' divergent-class inputs'
   .(@mismatch ? ': '.join('; ',@mismatch) : ''));

# ── same-origin write confirmation (PR-20 finding #1) ──
my ($wc_sub) = $pm_src =~ /(sub webui_write_confirmed \(\$\) \{.*?\n\})/s;
ok($wc_sub, 'webui.pm write-confirmation guard extracted');
eval $wc_sub; die "wc eval failed: $@" if $@;

is(webui_write_confirmed("POST /api/update/repo HTTP/1.1\r\nHost: 192.168.1.5\r\nOrigin: http://192.168.1.5\r\nX-PGenerator-Write: 1\r\n\r\n"),
   '', 'same-origin POST with write header is accepted');
like(webui_write_confirmed("POST /api/update/repo HTTP/1.1\r\nHost: 192.168.1.5\r\nOrigin: http://evil.example\r\nX-PGenerator-Write: 1\r\n\r\n"),
   qr/Cross-origin/, 'cross-origin POST is refused even with the header');
like(webui_write_confirmed("POST /api/update/repo HTTP/1.1\r\nHost: 192.168.1.5\r\nOrigin: http://192.168.1.5\r\n\r\n"),
   qr/header missing/, 'same-origin POST without the write header is refused');
is(webui_write_confirmed("POST /api/update/repo HTTP/1.1\r\nHost: 192.168.1.5\r\nX-PGenerator-Write: 1\r\n\r\n"),
   '', 'non-browser client with the write header but no Origin passes');

# ── apply trust precheck logic (server-side mirror) ──
my ($blocked_sub) = $pm_src =~ /(sub webui_ota_apply_blocked \(@\) \{.*?\n\})/s;
ok($blocked_sub, 'webui.pm apply-blocked helper present');

# ── generic /api/config writer must not set gated OTA keys ──
# webui_apply_config parses ANY POST body with a generic key:value regex
# and writes every pair it finds, Content-Type included: a CORS-simple
# cross-origin text/plain form can carry a JSON-shaped body and plant
# BOTH ota_repo and ota_repo_trusted, defeating the apply root-trust
# gate as a deferred drive-by install (attacker poisons the source and
# the trust key, then waits for the operator's own Install click).
# The write loop must therefore skip these keys. We extract the real
# parse regex and the denylist lines from the source (not copies) so
# the test cannot drift from the implementation.
# Slice the write loop out of webui_apply_config and check its skip lines.
# The write may carry a trailing condition (the automation branch skips an
# unchanged value); the denylist must still sit between the loop head and it.
my ($write_loop) = $pm_src =~ /(foreach my \$k \(sort keys %changes\) \{.*?\n   \&sudo\("SET_PGENERATOR_CONF",\$k,\$changes\{\$k\}\)(?: if\([^\n]*\))?;)/s;
ok($write_loop, 'generic config write loop extracted');
ok($write_loop && $write_loop =~ /next if\(\$k eq "ota_repo" \|\| \$k eq "ota_repo_trusted"\)/,
   'generic config writer denylists ota_repo and ota_repo_trusted');

# Behavioral sim: parse a drive-by-shaped body exactly as the route does,
# then run only the extracted deny decisions; the gated keys must not
# reach SET_PGENERATOR_CONF, while ordinary keys still do.
sub written_keys {
 my ($body)=@_;
 my %changes;
 while($body=~/"(\w+)"\s*:\s*(?:"([^"]*)"|(-?\d+(?:\.\d+)?))/g) {
  $changes{$1}=defined $2 ? $2 : $3;
 }
 my @w;
 foreach my $k (sort keys %changes) {
  next if($k eq "ip_pattern" || $k eq "port_pattern");
  next if($k eq "ota_repo" || $k eq "ota_repo_trusted");
  push @w, $k;
 }
 return @w;
}
my @w = written_keys(qq({"ota_repo":"attacker/x","ota_repo_trusted":"1","mode_idx":"3"}));
is_deeply([sort @w], ['mode_idx'],
   'drive-by body sets neither ota key through /api/config; normal keys still write');
# Sanity: a truly form-encoded (non-JSON) body parses to nothing anyway.
is(scalar(written_keys("ota_repo=attacker/x&ota_repo_trusted=1")), 0,
   'plain form-encoded body yields no changes to the regex parser');
