#!/usr/bin/perl
# Regression: deploying any file under usr/share/PGenerator/tv/ must ship the
# whole capability-library subtree. A partial deploy on 2026-09-18 shipped
# tv/lg/index.json without the tv/lg/series/g3.json it references, the device
# failed library validation and fell back to the conservative profile, which
# blocks C1 calibration until fixed by hand.
# capability_library_closure() in github-deployer/server.py is the gate: any
# tv/ selection expands to every tv/ file in the pinned snapshot. Slice the
# function out of the module (same technique as t/deployer_ref_default.t) --
# it is pure list handling, so running it needs only CAPABILITY_TREE_PREFIX
# and PROTECTED_PATHS, taken from the module's OWN lines rather than a stale
# duplicated copy.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $server = File::Spec->catfile($FindBin::Bin, '..', 'github-deployer', 'server.py');
plan skip_all => "github-deployer/server.py not present" unless -f $server;
plan skip_all => "python3 not present"                    unless `python3 -V 2>/dev/null` =~ /Python/;

my $py = do {
    open my $fh, '<', $server or die "open $server: $!";
    local $/; <$fh>;
};

my $start = index($py, 'def capability_library_closure(');
ok($start >= 0, 'capability_library_closure found in server.py');
my $end = index($py, 'def perl_source_paths(', $start);
ok($end > $start, 'function body delimited');
my $body = substr($py, $start, $end - $start);

# Constants from the module itself: if the prefix or the protected set
# changes upstream, this probe exercises the new values, not a copy.
my ($prefix_line) = $py =~ /^(CAPABILITY_TREE_PREFIX\s*=\s*.*)$/m;
ok(defined $prefix_line, 'CAPABILITY_TREE_PREFIX constant line found in module');
my $prot_start = index($py, 'PROTECTED_PATHS = {');
ok($prot_start >= 0, 'PROTECTED_PATHS dict found in module');
my $prot_end = index($py, "\n}", $prot_start);
ok($prot_end > $prot_start, 'PROTECTED_PATHS dict delimited');
my $prot_block = substr($py, $prot_start, $prot_end - $prot_start + 2);

my $probe = "import sys\n" . $prefix_line . "\n" . $prot_block . "\n" . $body . <<'PY';

TV = "usr/share/PGenerator/"
PREFIX = CAPABILITY_TREE_PREFIX

# The module's PROTECTED_PATHS has no tv/ entry today, so the closure's
# protected-skip guard is dead code on current data. Inject one under the
# prefix to keep that guard live under test: remove the skip and this case
# must fail.
PROTECTED_PATHS = dict(PROTECTED_PATHS)
LOCKED = PREFIX + "locked.json"
PROTECTED_PATHS[LOCKED] = "test-injected protected file"

fail = 0
def check(name, cond):
    global fail
    print(("OK " if cond else "FAIL ") + name)
    if not cond:
        fail += 1

def snap(files):
    return {"files": {f: {"mode": "644"} for f in files}}

tv_files = [
    PREFIX + "sources.json",
    PREFIX + "schema-v1.json",
    PREFIX + "lg/index.json",
    PREFIX + "lg/series/g3.json",
]
other = [TV + "webui.pm", "etc/PGenerator/PGenerator.conf"]
all_files = tv_files + other

# Incident scenario: index.json alone must pull the referenced series file.
paths, added = capability_library_closure(snap(all_files), [PREFIX + "lg/index.json"])
check("g3.json auto-included when index.json is selected",
      PREFIX + "lg/series/g3.json" in paths)
check("added lists exactly the not-selected tv files",
      sorted(added) == sorted(f for f in tv_files if f != PREFIX + "lg/index.json"))
check("expanded selection covers whole subtree",
      all(f in paths for f in tv_files) and not any(f not in all_files for f in paths))
check("no duplicates in expanded selection", len(paths) == len(set(paths)))

# Non-tv selection is untouched.
paths, added = capability_library_closure(snap(all_files), [TV + "webui.pm"])
check("non-tv selection unchanged",
      paths == [TV + "webui.pm"] and added == [])

# Full tv selection adds nothing.
paths, added = capability_library_closure(snap(all_files), list(tv_files))
check("full tv selection adds nothing", added == [] and sorted(paths) == sorted(tv_files))

# A protected file sitting under the prefix must never ride in via the walk.
paths, added = capability_library_closure(snap(tv_files + [LOCKED] + other),
                                          [PREFIX + "lg/index.json"])
check("protected file under prefix is never pulled in",
      LOCKED not in paths and LOCKED not in added)

# Adjacent-prefix directories (tv-something/) must NOT be captured.
paths, added = capability_library_closure(snap(all_files + [TV + "tv-sibling/x.json"]),
                                          [PREFIX + "lg/index.json"])
check("no adjacent-prefix capture", TV + "tv-sibling/x.json" not in paths)

# Caller's list must not be mutated by the expansion.
orig = [PREFIX + "lg/index.json"]
capability_library_closure(snap(all_files), orig)
check("input list not mutated", orig == [PREFIX + "lg/index.json"])

# Deterministic across runs (sorted walk).
a1 = capability_library_closure(snap(all_files), [PREFIX + "lg/index.json"])[0]
a2 = capability_library_closure(snap(all_files), [PREFIX + "lg/index.json"])[0]
check("deterministic order", a1 == a2)

print("ALL PASS" if fail == 0 else f"{fail} FAILURES")
sys.exit(1 if fail else 0)
PY

use IPC::Open2;
my ($rh, $wh);
my $pid = open2($rh, $wh, 'python3', '-c', $probe);
close $wh;
my @lines = <$rh>;
close $rh;
waitpid($pid, 0);
is($? >> 8, 0, 'probe ran without traceback');

my $seen = 0;
for my $line (@lines) {
    chomp $line;
    next unless $line =~ /^(OK|FAIL) (.*)/;
    $seen++;
    is($1, 'OK', $2);
}
cmp_ok($seen, '>=', 10, 'all probe cases reported');

done_testing();
