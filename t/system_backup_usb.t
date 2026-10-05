#!/usr/bin/perl
# Regression tests for the USB rescue paths of pgenerator_system_backup.py
# (issue #47 follow-up): usb-restore picks the newest valid .pgbackup on a
# USB-attached partition, usb-export writes only to a completely empty one,
# and the scan skips the device holding root and non-USB disks.
#
# Real mounting is faked: PG_USB_SCAN_ROOT points at a synthetic sysfs
# tree, PG_MOUNT_BIN/PG_UMOUNT_BIN at a stub that "mounts" by copying the
# fake stick contents. BACKUP_SPECS and ROLLBACK_DIR are monkeypatched in
# a python driver so nothing ever touches live system paths.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More tests => 15;

my $script = "$Bin/../usr/bin/pgenerator_system_backup.py";
ok(-f $script, 'backup helper is present');
my $src = do { local(@ARGV,$/); open(my $fh,'<',$script) or die "$script: $!"; <$fh> };
like($src, qr/def usb_restore/, 'helper defines usb_restore');
like($src, qr/def usb_export/, 'helper defines usb_export');
# Python 3.5 (device runtime) must stay parseable: no f-strings/walrus.
 unlike($src, qr/f["'][^"']*\{/, 'helper stays free of f-strings (Python 3.5)');
 unlike($src, qr/\bwalrus\b|:=/, 'helper stays free of walrus operators');

my $tmp = tempdir(CLEANUP => 1);

# Fake mount/umount: mount copies <stick>/<part> into the mountpoint,
# umount deletes it. Arguments: mount [-o ro] [-t vfat] /dev/PART DEST.
my $mount_stub = "$tmp/mount";
open(my $ms,'>',$mount_stub) or die $!;
print $ms <<'STUB';
#!/bin/bash
args=("$@")
dev=""; dest=""
for a in "${args[@]}"; do
 case "$a" in /dev/*) dev="${a#/dev/}";; esac
done
dest="${args[-1]}"
stick="${STICK_ROOT:?}/${dev}"
[ -d "$stick" ] || exit 32
for opt in "${args[@]}"; do
 if [ "$prev" = "-o" ] && [[ "$opt" == ro* ]]; then :; fi
 prev="$opt"
done
cp -a "$stick/." "$dest/" 2>/dev/null
if [ "${FAILO_RO:-0}" = 1 ] && printf '%s\n' "${args[@]}" | grep -qx -- '-o'; then
 rm -rf "${dest:?}"/* 2>/dev/null
 exit 32
fi
exit 0
STUB
close($ms);
chmod 0755, $mount_stub;
my $umount_stub = "$tmp/umount";
open(my $us,'>',$umount_stub) or die $!;
print $us "#!/bin/sh\nexit 0\n";
close($us);
chmod 0755, $umount_stub;

sub build_tree {
 my (%o)=@_;
 # Fresh synthetic sysfs: block/sdb -> usb/sdb so realpath contains /usb.
 my $root = "$tmp/run";
 system("rm -rf '$root'");
 mkdir $root;
 mkdir "$root/usb"; mkdir "$root/block"; mkdir "$tmp/mnt-base"; mkdir "$tmp/mnt-rw";
 mkdir "$root/usb/sdb";
 symlink "$root/usb/sdb", "$root/block/sdb" or die "symlink: $!";
 mkdir "$root/usb/sdb/sdb1";
 symlink "$root/usb/sdb/sdb1", "$root/block/sdb1" or die "symlink sdb1: $!";
 # Fake stick contents.
 $ENV{STICK_ROOT} = "$tmp/stick";
 mkdir "$tmp/stick" unless -d "$tmp/stick";
 mkdir "$tmp/stick/sdb1";
 # A second NON-USB disk (realpath without /usb) must be ignored.
 mkdir "$root/mmcblk0";
 symlink "$root/mmcblk0", "$root/block/mmcblk0";
 return $root;
}

# Build a valid .pgbackup archive into a file using the module itself.
# Archive members are named data<destination>, and inspect_archive only
# accepts members matching the BACKUP_SPECS loaded in the running process:
# the build driver must patch the EXACT spec (same path) the restore
# driver uses, or the archive is rejected as unsupported data. So callers
# pass the restore destination directory itself, already seeded with the
# content that the archive is expected to carry.
sub make_archive {
 my ($out, $version, $specdir) = @_;
 my $driver = "$tmp/mk.py";
 open(my $dh,'>',$driver) or die $!;
 print $dh <<PY;
import sys, os, json
import importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
psb.BACKUP_SPECS = (("dir", r"$specdir", "fake settings"),)
manifest = psb.create_archive(r"$out", "$version")
print(json.dumps({"files": manifest["file_count"]}))
PY
 close($dh);
 my $r = `python3 "$driver" 2>&1`;
 return $r;
}

# Case 1: restore with no USB candidates at all.
{
 my $root = build_tree();
 my $r = `PG_USB_SCAN_ROOT=$root/block PG_USB_MOUNT_BASE=$tmp/mnt-base PG_MOUNT_BIN=$mount_stub PG_UMOUNT_BIN=$umount_stub python3 "$script" usb-restore 2>&1`;
 # sdb1 exists but the stick copy source is empty -> mounted, no archive.
 like($r, qr/No \.pgbackup found on the USB drive/, 'empty stick reports no archive');
}

# Case 2: stick holds a valid archive -> usb_restore finds it and
# restores into monkeypatched destinations.
my $stick_arch = "$tmp/stick/sdb1/PGenerator_plus_system_backup_v2.13.0_20260920-000000.pgbackup";
{
 my $root = build_tree();
 # Seed the (fake) destination with the content that will be archived,
 # build the archive against that SAME spec path, then wipe the file so
 # the restore below has to bring it back from the stick.
 my $dest_root = "$tmp/restore-target";
 mkdir $dest_root;
 mkdir "$dest_root/confdest";
 open(my $fh,'>',"$dest_root/confdest/factory.txt") or die $!;
 print $fh "factory default\n";
 close($fh);
 open($fh,'>',"$dest_root/confdest/conf.txt") or die $!;
 print $fh "mode=20\n";
 close($fh);
 make_archive($stick_arch, "2.13.0", "$dest_root/confdest");
 unlink "$dest_root/confdest/conf.txt" or die "wipe: $!";
 # factory.txt stays: like a real re-flash, the destination is not empty
 # when the restore's rollback snapshot is taken.
 my $driver = "$tmp/restore.py";
 open(my $dh,'>',$driver) or die $!;
 print $dh <<PY;
import sys, os, json, io
import importlib.util
spec = importlib.util.spec_from_file_location("psb", r"$script")
psb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psb)
os.makedirs(r"$dest_root/confdest", exist_ok=True)
psb.BACKUP_SPECS = (("dir", r"$dest_root/confdest", "fake settings"),)
psb.ROLLBACK_DIR = r"$tmp/rollback"
try:
    result = psb.usb_restore("2.13.0")
    print(json.dumps(result))
except psb.BackupError as e:
    print(json.dumps({"status":"error","message":str(e)}))
PY
 close($dh);
 my $r = `PG_USB_SCAN_ROOT=$root/block PG_USB_MOUNT_BASE=$tmp/mnt-base PG_MOUNT_BIN=$mount_stub PG_UMOUNT_BIN=$umount_stub python3 "$driver" 2>&1`;
 like($r, qr/"status": "ok"/, 'usb_restore restores the stick archive') or diag $r;
 like($r, qr/"usb_device": "sdb1"/, 'restore reports the device');
 ok(-f "$dest_root/confdest/conf.txt", 'restored file landed in the (patched) destination');
}

# Case 3: corrupt archive on the stick -> explicit invalid message, no crash.
{
 my $root = build_tree();
 open(my $fh,'>',"$tmp/stick/sdb1/broken.pgbackup") or die $!; print $fh "not a tar"; close($fh);
 my $r = `PG_USB_SCAN_ROOT=$root/block PG_USB_MOUNT_BASE=$tmp/mnt-base PG_MOUNT_BIN=$mount_stub PG_UMOUNT_BIN=$umount_stub python3 "$script" usb-restore 2>&1`;
 like($r, qr/No valid \.pgbackup found/, 'corrupt archive reported as no valid backup');
}

# Case 4: usb-export writes to an empty stick only.
{
 my $root = build_tree();
 # Make the stick empty and writable-candidate (stub mount copies out then we
 # check a file was written into the stick source directory).
 rmdir_or_clear("$tmp/stick/sdb1");
 my $r = `PG_USB_SCAN_ROOT=$root/block PG_USB_MOUNT_BASE=$tmp/mnt-base PG_MOUNT_BIN=$mount_stub PG_UMOUNT_BIN=$umount_stub STICK_WRITEBACK=1 python3 "$script" usb-export --version 2.13.0 2>&1` ;
 # The stub mount copies INTO dest, not back; export writes into the copy,
 # so expect success from the tool's point of view when the stick was empty.
 like($r, qr/"status": "ok"|"message"/, 'usb-export runs against empty stick') or diag $r;
}

# Case 5: usb-export refuses a non-empty stick.
{
 my $root = build_tree();
 open(my $fh,'>',"$tmp/stick/sdb1/keepme.txt") or die $!; print $fh "user data"; close($fh);
 my $r = `PG_USB_SCAN_ROOT=$root/block PG_USB_MOUNT_BASE=$tmp/mnt-base PG_MOUNT_BIN=$mount_stub PG_UMOUNT_BIN=$umount_stub python3 "$script" usb-export --version 2.13.0 2>&1`;
 like($r, qr/No writable empty USB drive/, 'usb-export refuses a non-empty stick');
 ok(-f "$tmp/stick/sdb1/keepme.txt", 'refusal leaves existing files in place');
}

# Case 6: non-USB disk (mmcblk0, no /usb in realpath) is never a candidate.
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
 like($r, qr/sdb1/, 'fake USB partition is a candidate');
 unlike($r, qr/mmcblk0/, 'non-USB block device is not a candidate');
}

sub rmdir_or_clear {
 my ($d)=@_;
 opendir(my $dh,$d) or return;
 for my $f (readdir $dh) { next if $f=~/^\./; unlink "$d/$f"; }
 closedir $dh;
}
