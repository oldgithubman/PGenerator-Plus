#!/usr/bin/perl
# Regression tests for the USB rescue paths of pgenerator_system_backup.py
# (issue #47 follow-up): usb-restore picks the newest valid .pgbackup on a
# USB-attached partition that carries the PGEN_USB_RESCUE sentinel (and
# strips OTA trust keys from the restored conf), usb-export writes only to
# a completely empty one (and writes the sentinel), and the scan skips the
# device holding root and non-USB disks.
#
# Real mounting is faked: PG_USB_SCAN_ROOT points at a synthetic sysfs
# tree that MIRRORS THE REAL KERNEL LAYOUT (whole disks at the scan root,
# partition directories NESTED INSIDE the disk directory — the old fixture
# symlinked block/sdb1 as a sibling, which real kernels never do and
# which hid the scan failure on real devices). PG_MOUNT_BIN/PG_UMOUNT_BIN
# are stubs that "mount" by copying the fake stick contents and "unmount"
# by copying them back when WRITEBACK=1, so export writes are observable.
# MOUNT_LOG records every mount/umount so the mount-leak and ro-first
# behaviors are pinned. BACKUP_SPECS, CONF_DEST and ROLLBACK_DIR are
# monkeypatched in a python driver so nothing ever touches live paths.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More tests => 59;

my $script = "$Bin/../usr/bin/pgenerator_system_backup.py";
ok(-f $script, 'backup helper is present');
my $src = do { local(@ARGV,$/); open(my $fh,'<',$script) or die "$script: $!"; <$fh> };
like($src, qr/def usb_restore/, 'helper defines usb_restore');
like($src, qr/def usb_export/, 'helper defines usb_export');
# Python 3.5 (device runtime) must stay parseable: ask the interpreter,
# not a grep — greps for f-strings/walrus miss every other 3.6+ syntax.
SKIP: {
 my $py = `command -v python3`;
 chomp($py);
 skip 'python3 not available', 1 unless $py;
 my $r = `$py -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3,5)); print("PY35OK")' '$script' 2>&1`;
 like($r, qr/PY35OK/, 'helper parses under Python 3.5 (ast feature_version)');
}

my $tmp = tempdir(CLEANUP => 1);
my $mount_log = "$tmp/mount.log";
open(my $ml,'>',$mount_log) or die $!; close($ml);

# Fake mount/umount (POSIX sh: the suite must pass on macOS bash 3.2 and
# plain /bin/sh alike — no bash arrays, no ${args[-1]}). mount copies
# <stick>/<part> into the mountpoint; umount copies back when WRITEBACK=1
# (so export writes land on the fake stick) and deletes the copy. Both
# append verb+args to $MOUNT_LOG so tests pin mount/umount pairing and
# the ro-first order; "remount" is accepted and logged.
my $mount_stub = "$tmp/mount";
open(my $ms,'>',$mount_stub) or die $!;
print $ms <<'STUB';
#!/bin/sh
printf 'MOUNT %s\n' "$*" >> "$MOUNT_LOG"
case "$*" in
 *"remount"*)
   if [ "${FAILRW:-0}" = 1 ]; then exit 32; fi
   exit 0;;
esac
dev=""
for a in "$@"; do
 case "$a" in /dev/*) dev="${a#/dev/}";; esac
done
# Any rw attempt (remount or plain mount) fails when FAILRW=1, so the
# export's rw-gate failure path is exercised end-to-end.
case "$*" in
 *"-o ro"*) :;;
 *) if [ "${FAILRW:-0}" = 1 ]; then exit 32; fi;;
esac
# last argument is the mountpoint
dest=""
for a in "$@"; do dest="$a"; done
stick="${STICK_ROOT:?}/${dev}"
[ -d "$stick" ] || exit 32
cp -a "$stick/." "$dest/" 2>/dev/null
exit 0
STUB
close($ms);
chmod 0755, $mount_stub;
my $umount_stub = "$tmp/umount";
open(my $us,'>',$umount_stub) or die $!;
print $us <<'STUB';
#!/bin/sh
printf 'UMOUNT %s\n' "$*" >> "$MOUNT_LOG"
# recover the partition name from the mountpoint basename
# (<base>-rw/PART or <base>/PART) for write-back
base=$(basename "$1")
stick="${STICK_ROOT:?}/${base}"
if [ "${WRITEBACK:-0}" = 1 ] && [ -d "$stick" ]; then
 # REPLACE the stick with the mountpoint contents: a plain cp -a over
 # the top cannot express files the export PRUNED (superseded rescue
 # archives), so deletions during the mounted phase must survive too.
 rm -rf "$stick" 2>/dev/null
 mkdir -p "$stick"
 cp -a "$1/." "$stick/" 2>/dev/null
fi
rm -rf "$1" 2>/dev/null
exit 0
STUB
close($us);
chmod 0755, $umount_stub;

my $env_common = "MOUNT_LOG=$mount_log STICK_ROOT=$tmp/stick PG_MOUNT_BIN=$mount_stub PG_UMOUNT_BIN=$umount_stub PG_USB_MOUNT_BASE=$tmp/mnt-base";

sub clear_mount_log { open(my $fh,'>',$mount_log) or die $!; close($fh); }
sub mount_log { my $l=""; open(my $fh,'<',$mount_log) or return ""; while(<$fh>){$l.=$_} return $l; }

sub build_tree {
 # Fresh synthetic sysfs mirroring the REAL kernel layout: /sys/block
 # holds whole disks only; the partition directory is NESTED under the
 # disk directory (/sys/block/sdb/sdb1), never a sibling. A sibling
 # decoy directory must NOT be honored.
 my $root = "$tmp/run";
 system("rm -rf '$root'");
 mkdir $root;
 mkdir "$root/usb"; mkdir "$root/block"; mkdir "$tmp/mnt-base"; mkdir "$tmp/mnt-rw";
 mkdir "$root/usb/sdb";
 symlink "$root/usb/sdb", "$root/block/sdb" or die "symlink: $!";
 mkdir "$root/usb/sdb/sdb1";
 mkdir "$root/block/sdbX";
 # Fake stick contents.
 mkdir "$tmp/stick" unless -d "$tmp/stick";
 mkdir "$tmp/stick/sdb1";
 # A second NON-USB disk (realpath without /usb) must be ignored.
 mkdir "$root/mmcblk0";
 symlink "$root/mmcblk0", "$root/block/mmcblk0";
 return $root;
}

sub clear_stick {
 my $d="$tmp/stick/sdb1";
 # The writeback umount stub may have replaced the stick dir; recreate.
 mkdir "$tmp/stick" unless -d "$tmp/stick";
 mkdir $d unless -d $d;
 # Recursive: cases may nest (deep/nested fixtures); a leftover top
 # level directory would make the next case's stick read as non-blank.
 system("rm", "-rf", "--", $d);
 mkdir $d;
}

sub copy_file {
 my ($from,$to)=@_;
 open(my $in,'<:raw',$from) or die "$from: $!";
 open(my $out,'>:raw',$to) or die "$to: $!";
 local $/;
 my $data = <$in>;
 print {$out} $data;
 close($in); close($out);
}

# Driver that runs usb_export with patched BACKUP_SPECS: on the test
# host the real /etc/PGenerator paths do not exist, so create_archive
# aborts with "no settings found" — the ORIGINAL test hid that behind a
# regex matching every error JSON. Patched specs give the export real
# content to archive without touching live paths.
sub export_driver {
 my $drv = "$tmp/export.py";
 open(my $dh,'>',$drv) or die $!;
 print $dh <<PY;
import sys, os, json
import importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
spec_dir = r"$tmp/export-spec"
os.makedirs(spec_dir, exist_ok=True)
with open(os.path.join(spec_dir, "seed.txt"), "w") as h:
    h.write("export seed\\n")
psb.BACKUP_SPECS = (("dir", spec_dir, "fake settings"),)
try:
    result = psb.usb_export("2.13.0")
    print(json.dumps(result))
except psb.BackupError as e:
    print(json.dumps({"status":"error","message":str(e)}))
PY
 close($dh);
 return $drv;
}

# The (fake) destination root shared by the archive-build and restore
# drivers. Archive members are named data<destination>, and
# inspect_archive only accepts members matching the BACKUP_SPECS loaded
# in the running process: the build driver must patch the EXACT specs
# (same paths) the restore driver uses, or the archive is rejected as
# unsupported data. So both drivers patch the destination paths
# themselves, already seeded with the content to be archived.
my $dest_root = "$tmp/restore-target";
my $conf_spec = "$dest_root/ota_conf.txt";
my $built_arch = "$tmp/mk.pgbackup";

# Case 1: restore with no archives at all.
{
 my $root = build_tree();
 clear_mount_log();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common python3 "$script" usb-restore 2>&1`;
 # sdb1 exists but the stick copy source is empty -> mounted, no archive.
 like($r, qr/No \.pgbackup found on the USB drive/, 'empty stick reports no archive');
}

# Case 2: stick holds a sentinel + valid archive (dir spec + a conf FILE
# spec carrying OTA trust keys) -> usb_restore restores the dir AND the
# conf with the denied trust keys stripped, into patched destinations.
{
 my $root = build_tree();
 clear_stick();
 # Seed the (fake) destinations with the content that will be archived,
 # build the archive against those SAME spec paths, then wipe the files
 # so the restore below has to bring them back from the stick.
 mkdir $dest_root;
 mkdir "$dest_root/confdest";
 open(my $fh,'>',"$dest_root/confdest/factory.txt") or die $!;
 print $fh "factory default\n";
 close($fh);
 open($fh,'>',"$dest_root/confdest/conf.txt") or die $!;
 print $fh "mode=20\n";
 close($fh);
 open($fh,'>',$conf_spec) or die $!;
 print $fh "mode=21\nota_repo=evil/pwned\nota_repo_trusted=1\nota_target=wrong_board\nwifi_ssid=keepme\n";
 close($fh);
 my $driver = "$tmp/mk.py";
 my $dh;
 open($dh,'>',$driver) or die $!;
 print $dh <<PY;
import sys, os, json
import importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
psb.BACKUP_SPECS = (
    ("dir", r"$dest_root/confdest", "fake settings"),
    ("file", r"$conf_spec", "fake conf"),
)
manifest = psb.create_archive(r"$built_arch", "2.13.0")
print(json.dumps({"files": manifest["file_count"]}))
PY
 close($dh);
 `python3 "$driver" 2>&1`;
 copy_file($built_arch, "$tmp/stick/sdb1/PGenerator_plus_system_backup_v2.13.0_20260920-000000.pgbackup");
 unlink "$dest_root/confdest/conf.txt" or die "wipe: $!";
 unlink $conf_spec or die "wipe: $!";
 # factory.txt stays: like a real re-flash, the destination is not empty
 # when the restore's rollback snapshot is taken.
 open($fh,'>',"$tmp/stick/sdb1/PGEN_USB_RESCUE") or die $!;
 print $fh "pgenerator-usb-rescue\n";
 close($fh);
 $driver = "$tmp/restore.py";
 open($dh,'>',$driver) or die $!;
 print $dh <<PY;
import sys, os, json, io
import importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
os.makedirs(r"$dest_root/confdest", exist_ok=True)
psb.BACKUP_SPECS = (
    ("dir", r"$dest_root/confdest", "fake settings"),
    ("file", r"$conf_spec", "fake conf"),
)
psb.ROLLBACK_DIR = r"$tmp/rollback"
psb.CONF_DEST = r"$conf_spec"
# Capture what the conf looks like AT COPY TIME: the OTA trust keys must
# already be stripped from the STAGED copy before it is atomically
# installed, so the live conf never holds them even momentarily.
_atomic = psb.copy_file_atomic
def _watched(source, destination):
    with open(source, "r") as h:
        text = h.read()
    with open(r"$tmp/staging_watch.txt", "a") as h:
        h.write("OTA_IN_SOURCE" if "ota_repo" in text else "CLEAN")
        h.write(chr(10))
    return _atomic(source, destination)
psb.copy_file_atomic = _watched
try:
    result = psb.usb_restore("2.13.0")
    print(json.dumps(result))
except psb.BackupError as e:
    print(json.dumps({"status":"error","message":str(e)}))
PY
 close($dh);
 clear_mount_log();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common python3 "$driver" 2>&1`;
 like($r, qr/"status": "ok"/, 'usb_restore restores the stick archive') or diag $r;
 like($r, qr/"usb_device": "sdb1"/, 'restore reports the device');
 ok(-f "$dest_root/confdest/conf.txt", 'restored file landed in the (patched) destination');
 ok(-f $conf_spec, 'conf file restored');
 my $conf = do { local(@ARGV,$/); open(my $f,'<',$conf_spec) or die $!; <$f> };
 unlike($conf, qr/^ota_repo=/m, 'unattended restore strips ota_repo');
 unlike($conf, qr/^ota_repo_trusted=/m, 'unattended restore strips ota_repo_trusted');
 unlike($conf, qr/^ota_target=/m, 'unattended restore strips ota_target');
 like($conf, qr/^wifi_ssid=keepme/m, 'unattended restore keeps non-gated keys');
 unlike(mount_log(), qr/^MOUNT (?!-o ro)/m, 'restore never mounts read-write');
 # Staged-copy strip: the file handed to copy_file_atomic must already
 # be free of the trust keys (a post-copy strip leaves the live conf
 # momentarily holding ota_repo_trusted=1).
 {
  my $watch = do { local(@ARGV,$/); open(my $f,'<',"$tmp/staging_watch.txt") or die "staging_watch: $!"; <$f> };
  unlike($watch, qr/OTA_IN_SOURCE/, 'conf handed to copy_file_atomic is already stripped (staged strip, not post-copy)');
  like($watch, qr/CLEAN/, 'staging watch observed the conf copy');
 }
}

# Case 3: ONLY a corrupt archive on the stick (the valid archive from
# case 2 is cleared first — before the fix this case passed vacuously on
# the leftover valid archive failing spec-matching, never exercising the
# corrupt file at all).
{
 my $root = build_tree();
 clear_stick();
 open(my $fh,'>',"$tmp/stick/sdb1/broken.pgbackup") or die $!; print $fh "not a tar"; close($fh);
 open($fh,'>',"$tmp/stick/sdb1/PGEN_USB_RESCUE") or die $!; print $fh "x\n"; close($fh);
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common python3 "$script" usb-restore 2>&1`;
 like($r, qr/No valid \.pgbackup found/, 'corrupt archive alone reported as no valid backup');
}

# Case 3b: an archive WITHOUT the rescue sentinel is not a rescue
# source: rescue is opt-in, a random stick cannot push settings onto an
# unattended first boot.
{
 my $root = build_tree();
 clear_stick();
 copy_file($built_arch, "$tmp/stick/sdb1/unmarked.pgbackup");
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common python3 "$script" usb-restore 2>&1`;
 like($r, qr/No \.pgbackup found/, 'archive without the rescue sentinel is ignored');
}

# Case 4: usb-export writes to an empty stick only, ro-first, always
# unmounts, and leaves the sentinel behind. WRITEBACK makes the umount
# stub copy the mountpoint back so the written archive is observable
# (the old stub never wrote back and its assertion regex matched every
# error JSON, so export success was untested).
{
 my $root = build_tree();
 clear_stick();
 clear_mount_log();
 my $edriver = export_driver();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common WRITEBACK=1 python3 "$edriver" 2>&1`;
 like($r, qr/"status": "ok"/, 'usb-export succeeds against empty stick') or diag $r;
 like($r, qr/"usb_device": "sdb1"/, 'usb-export reports the device');
 my $log = mount_log();
 my $mounts = () = $log =~ /^MOUNT (?!.*remount)/mg;
 my $umounts = () = $log =~ /^UMOUNT/mg;
 cmp_ok($mounts, '>=', 1, 'stick was mounted');
 is($mounts, $umounts, 'every mount is matched by an unmount');
 like($log, qr/^MOUNT -o ro /m, 'stick is first mounted read-only');
 like($log, qr/remount,rw/, 'blank stick is remounted rw for the write');
 ok(-f "$tmp/stick/sdb1/PGEN_USB_RESCUE", 'export writes the rescue sentinel');
 ok(scalar(grep { /\.pgbackup$/ } `ls $tmp/stick/sdb1`), 'archive written back to stick');
}

# Case 5: usb-export refuses a non-empty stick but STILL unmounts it
# (the mount-leak pin: before the fix the refusal skipped unmount and
# left data sticks mounted read-write until reboot).
{
 my $root = build_tree();
 clear_stick();
 open(my $fh,'>',"$tmp/stick/sdb1/keepme.txt") or die $!; print $fh "user data"; close($fh);
 clear_mount_log();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common python3 "$script" usb-export --version 2.13.0 2>&1`;
 like($r, qr/USB drive is not empty/, 'usb-export refuses a non-empty stick') or diag $r;
 ok(-f "$tmp/stick/sdb1/keepme.txt", 'refusal leaves existing files in place');
 my $log = mount_log();
 my $mounts = () = $log =~ /^MOUNT/mg;
 my $umounts = () = $log =~ /^UMOUNT/mg;
 is($mounts, $umounts, 'refused stick is still unmounted');
 unlike($log, qr/^MOUNT (?!-o ro)/m, 'stick with data is never mounted read-write');
}

# Case 5b: OS junk (System Volume Information etc.) and a stranded
# .pgbackup.tmp do NOT make a stick non-empty.
{
 my $root = build_tree();
 clear_stick();
 mkdir "$tmp/stick/sdb1/System Volume Information";
 open(my $fh,'>',"$tmp/stick/sdb1/System Volume Information/desktop.ini") or die $!; print $fh "x"; close($fh);
 open($fh,'>',"$tmp/stick/sdb1/old.pgbackup.tmp") or die $!; print $fh "partial"; close($fh);
 clear_mount_log();
 my $edriver = export_driver();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common WRITEBACK=1 python3 "$edriver" 2>&1`;
 like($r, qr/"status": "ok"/, 'OS junk and a stranded temp still count as blank') or diag $r;
}

# Case 6: non-USB disk (mmcblk0, no /usb in realpath) is never a
# candidate; sibling decoy dirs are never honored either.
{
 my $root = build_tree();
 my $probe = "$tmp/probe.py";
 open(my $dh,'>',$probe) or die $!;
 print $dh <<PY;
import sys, importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
print(" ".join(psb.list_usb_backup_candidates()))
PY
 close($dh);
 my $r = `PG_USB_SCAN_ROOT=$root/block python3 "$probe" 2>&1`;
 chomp $r;
 like($r, qr/\bsdb1\b/, 'nested partition dir is a candidate (real sysfs layout)');
 unlike($r, qr/mmcblk0/, 'non-USB block device is not a candidate');
 unlike($r, qr/sdbX/, 'sibling decoy dir under the scan root is not a candidate');
}

# Case 6b: superfloppy stick (unpartitioned whole-disk filesystem):
# block/sdb with NO nested partition directory must STILL be a
# candidate. The nested-partition check applied to the disk itself
# (/sys/block/sdb/sdb never exists) silently dropped every real
# unpartitioned stick.
{
 my $sf = "$tmp/sfroot";
 system("rm -rf '$sf'");
 mkdir $sf;
 mkdir "$sf/usb"; mkdir "$sf/block";
 mkdir "$sf/usb/sdb";
 symlink "$sf/usb/sdb", "$sf/block/sdb" or die "symlink: $!";
 my $probe = "$tmp/sfprobe.py";
 open(my $dh,'>',$probe) or die $!;
 print $dh <<PY;
import sys, importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
print(" ".join(psb.list_usb_backup_candidates()))
PY
 close($dh);
 my $r = `PG_USB_SCAN_ROOT=$sf/block python3 "$probe" 2>&1`;
 chomp $r;
 like($r, qr/\bsdb\b/, 'unpartitioned superfloppy disk is a candidate (no sysfs partition node)');
}

# Case 6c: full rescue FROM a superfloppy stick: sentinel + valid
# archive on the whole-disk filesystem restore end-to-end (the scan
# alone could pass while mounting/restore never ran on this shape).
{
 my $sf = "$tmp/sfroot2";
 system("rm -rf '$sf'");
 mkdir $sf;
 mkdir "$sf/usb"; mkdir "$sf/block";
 mkdir "$sf/usb/sdb";
 symlink "$sf/usb/sdb", "$sf/block/sdb" or die "symlink: $!";
 # Stick contents keyed by candidate name ("sdb" here).
 mkdir "$tmp/stick/sdb" unless -d "$tmp/stick/sdb";
 opendir(my $dh,"$tmp/stick/sdb") or die $!;
 for my $f (readdir $dh) { next if $f=~/^\./; unlink "$tmp/stick/sdb/$f" }
 closedir $dh;
 copy_file($built_arch, "$tmp/stick/sdb/PGenerator_plus_system_backup_v2.13.0_20260921-000000.pgbackup");
 open(my $fh,'>',"$tmp/stick/sdb/PGEN_USB_RESCUE") or die $!; print $fh "x\n"; close($fh);
 # Wipe the destinations so the restore must bring the files back.
 unlink "$dest_root/confdest/conf.txt" if -f "$dest_root/confdest/conf.txt";
 unlink $conf_spec if -f $conf_spec;
 clear_mount_log();
 my $driver = "$tmp/sfrestore.py";
 open($dh,'>',$driver) or die $!;
 print $dh <<PY;
import sys, os, json
import importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
os.makedirs(r"$dest_root/confdest", exist_ok=True)
psb.BACKUP_SPECS = (
    ("dir", r"$dest_root/confdest", "fake settings"),
    ("file", r"$conf_spec", "fake conf"),
)
psb.ROLLBACK_DIR = r"$tmp/rollback"
psb.CONF_DEST = r"$conf_spec"
try:
    result = psb.usb_restore("2.13.0")
    print(json.dumps(result))
except psb.BackupError as e:
    print(json.dumps({"status":"error","message":str(e)}))
PY
 close($dh);
 my $r = `PG_USB_SCAN_ROOT=$sf/block $env_common python3 "$driver" 2>&1`;
 like($r, qr/"status": "ok"/, 'superfloppy stick restores end-to-end') or diag $r;
 like($r, qr/"usb_device": "sdb"/, 'restore reports the whole-disk device');
 ok(-f $conf_spec, 'superfloppy restore landed the conf');
 unlike($conf_spec ? do { local(@ARGV,$/); open(my $f,'<',$conf_spec); <$f> } : '', qr/^ota_repo=/m,
  'superfloppy restore also strips OTA trust keys');
}

# Case 6d: a stick that ALREADY holds a rescue backup (sentinel +
# *.pgbackup from a previous export) is refreshable: exporting again
# must succeed without a manual wipe. Third-party data still refuses.
{
 my $root = build_tree();
 clear_stick();
 open(my $fh,'>',"$tmp/stick/sdb1/PGEN_USB_RESCUE") or die $!; print $fh "x\n"; close($fh);
 open($fh,'>',"$tmp/stick/sdb1/PGenerator_plus_system_backup_v2.12.0_20260101-000000.pgbackup") or die $!;
 print $fh "previous rescue export\n"; close($fh);
 clear_mount_log();
 my $edriver = export_driver();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common WRITEBACK=1 python3 "$edriver" 2>&1`;
 like($r, qr/"status": "ok"/, 'rescue stick with a previous backup is refreshable without a wipe') or diag $r;
 # But the same stick PLUS someone's file is still off-limits.
 open($fh,'>',"$tmp/stick/sdb1/taxes.txt") or die $!; print $fh "data"; close($fh);
 $r = `PG_USB_SCAN_ROOT=$root/block $env_common WRITEBACK=1 python3 "$edriver" 2>&1`;
 like($r, qr/USB drive is not empty/, 'rescue files plus third-party data still refuses export') or diag $r;
}

# Case 8: a stick whose ONLY content is a hand-copied *.pgbackup (no
# sentinel) is somebody's data stick: export must REFUSE it, so the
# button can never turn a user drive into a rescue source. Provenance
# is the sentinel, not the file extension.
{
 my $root = build_tree();
 clear_stick();
 copy_file($built_arch, "$tmp/stick/sdb1/my_family_photos_backup.pgbackup");
 clear_mount_log();
 my $edriver = export_driver();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common WRITEBACK=1 python3 "$edriver" 2>&1`;
 like($r, qr/USB drive is not empty/, 'stick with only a hand-copied backup (no sentinel) is refused by export') or diag $r;
 ok(-f "$tmp/stick/sdb1/my_family_photos_backup.pgbackup", 'the hand-copied archive stays untouched');
 ok(!-f "$tmp/stick/sdb1/PGEN_USB_RESCUE", 'refused stick gets no rescue sentinel');
}

# Case 9: refreshing a rescue stick prunes superseded rescue archives
# (they would each be re-validated on every first boot and push the
# stick toward ENOSPC); the newest old one is kept as a fallback and
# the fresh write lands next to it.
{
 my $root = build_tree();
 clear_stick();
 open(my $fh,'>',"$tmp/stick/sdb1/PGEN_USB_RESCUE") or die $!; print $fh "x\n"; close($fh);
 open($fh,'>',"$tmp/stick/sdb1/PGenerator_plus_system_backup_v2.11.0_20250101-000000.pgbackup") or die $!;
 print $fh "oldest\n"; close($fh);
 open($fh,'>',"$tmp/stick/sdb1/PGenerator_plus_system_backup_v2.12.0_20260101-000000.pgbackup") or die $!;
 print $fh "newer\n"; close($fh);
 clear_mount_log();
 my $edriver = export_driver();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common WRITEBACK=1 python3 "$edriver" 2>&1`;
 like($r, qr/"status": "ok"/, 'refresh export succeeds on a rescue stick with old archives') or diag $r;
 my @arch = sort grep { /^PGenerator_plus_system_backup_.*\.pgbackup$/ } `ls $tmp/stick/sdb1`;
 is(scalar(@arch), 2, 'superseded rescue archives pruned; newest-old fallback kept beside the fresh write') or diag join " ", @arch;
 ok(-f "$tmp/stick/sdb1/PGenerator_plus_system_backup_v2.12.0_20260101-000000.pgbackup", 'the fallback kept is the NEWEST old archive');
 ok(!-f "$tmp/stick/sdb1/PGenerator_plus_system_backup_v2.11.0_20250101-000000.pgbackup", 'the older archive is gone');
}

# Case 10: rescue lookup is TOP-LEVEL only — a sentinel buried in a
# subdirectory of a data stick does not arm rescue (usb-export always
# writes both files at the stick root, and a huge data stick is never
# walked).
{
 my $root = build_tree();
 clear_stick();
 mkdir "$tmp/stick/sdb1/deep";
 mkdir "$tmp/stick/sdb1/deep/nested";
 copy_file($built_arch, "$tmp/stick/sdb1/deep/nested/some.pgbackup");
 open(my $fh,'>',"$tmp/stick/sdb1/deep/nested/PGEN_USB_RESCUE") or die $!; print $fh "x\n"; close($fh);
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common python3 "$script" usb-restore 2>&1`;
 like($r, qr/No \.pgbackup found/, 'sentinel in a subdirectory does not arm rescue (top-level only)') or diag $r;
}

# Case 11: a stick whose rw mount fails reports the MOUNT failure, not
# the misleading "not empty" (nit: swallowed write errors).
{
 my $root = build_tree();
 clear_stick();
 clear_mount_log();
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common FAILRW=1 python3 "$script" usb-export --version 2.13.0 2>&1`;
 like($r, qr/could not be mounted read-write/, 'rw-mount failure reported as such, not as a contents problem') or diag $r;
 my $log = mount_log();
 # The rw fallback path unmounts once before the fresh-rw retry and once
 # in the finally: the pin is that a UMOUNT followed the rw attempts.
 like($log, qr/^UMOUNT/m, 'stick with failed rw remount is still unmounted');
}

# Case 12: mount_ro that fails BOTH attempts leaves no empty mount dir
# behind (nit: litter per unreadable partition).
{
 my $root = build_tree();
 my $probe = "$tmp/mrprobe.py";
 open(my $dh,'>',$probe) or die $!;
 print $dh <<PY;
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
# sdbZ has no stick content: the stub mount exits 32 (mount failure).
print("MROK" if psb.mount_ro("sdbZ") is None else "MRFAIL")
print("NODIR" if not os.path.isdir(os.path.join(psb.USB_MOUNT_BASE, "sdbZ")) else "LITTER")
PY
 close($dh);
 my $r = `PG_USB_SCAN_ROOT=$root/block $env_common python3 "$probe" 2>&1`;
 like($r, qr/MROK/, 'failed mount_ro returns None');
 like($r, qr/NODIR/, 'failed mount_ro removes the empty mount dir it created');
}

# Case 13: a mount that HANGS must not wedge the helper (first-boot
# path blocks the daemon). PG_USB_CMD_TIMEOUT=1 with a sleeping stub
# mount: the run_cmd timeout kills it and restore completes.
{
 my $root = build_tree();
 clear_stick();
 my $hang = "$tmp/mount-hang";
 open(my $hs,'>',$hang) or die $!;
 print $hs "#!/bin/sh\nsleep 30\n";
 close($hs);
 chmod 0755, $hang;
 my $start = time();
 my $r = `PG_USB_SCAN_ROOT=$root/block MOUNT_LOG=$mount_log STICK_ROOT=$tmp/stick PG_MOUNT_BIN=$hang PG_UMOUNT_BIN=$umount_stub PG_USB_MOUNT_BASE=$tmp/mnt-base PG_USB_CMD_TIMEOUT=1 timeout 20 python3 "$script" usb-restore 2>&1`;
 my $elapsed = time() - $start;
 like($r, qr/No \.pgbackup found|No USB drive found/, 'hanging mount is timed out; restore completes with an error') or diag $r;
 cmp_ok($elapsed, '<', 15, 'helper returns on the 1 s bound, not the stub 30 s hang') or diag "elapsed=$elapsed";
}

# Case 7: the Perl route must assign _webui_system_backup_run in LIST
# context — a scalar assignment keeps only $ok and the route answers
# 400 with body "1" even when the export succeeded (structure guard:
# no Perl harness for this route exists in the repo).
{
 my $pm = "$Bin/../usr/share/PGenerator/webui.pm";
 ok(-f $pm, 'webui.pm is present');
 my $psrc = do { local(@ARGV,$/); open(my $fh,'<',$pm) or die "$pm: $!"; <$fh> };
 # Scope the regex to the usb-export route block.
 my ($block) = $psrc =~ /(elsif\(\$path eq "\/api\/system-backup\/usb-export".*?\n   \}\n)/s;
 ok($block, 'usb-export route block found');
 like($block, qr/my \(\$result,\$ok\)=&_webui_system_backup_run\("usb-export"/,
  'usb-export route assigns helper result in list context');
 unlike($block, qr/my \$result=&_webui_system_backup_run/,
  'usb-export route has no scalar-context result assignment');
}
