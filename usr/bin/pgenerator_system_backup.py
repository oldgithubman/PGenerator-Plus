#!/usr/bin/python3
"""Create and restore versioned PGenerator+ user-data backups.

The archive is intentionally limited to persistent PGenerator+ configuration,
profiles and calibration history. Runtime state, device identity, caches,
logs and pairing tokens are never included.
"""

from __future__ import print_function

import argparse
import datetime
import hashlib
import io
import json
import os
import posixpath
import pwd
import grp
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time


FORMAT = "pgenerator-system-backup-v1"
SCHEMA_VERSION = 1
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 100000

# USB rescue paths. PG_USB_SCAN_ROOT overrides the sysfs block root so
# tests can fake a stick; PG_USB_MOUNT_BASE overrides the mount point;
# PG_MOUNT_BIN/PG_UMOUNT_BIN substitute the mount tools for tests.
USB_SCAN_ROOT = os.environ.get("PG_USB_SCAN_ROOT", "/sys/block")
USB_MOUNT_BASE = os.environ.get("PG_USB_MOUNT_BASE", "/var/lib/PGenerator/usb-mnt")
MOUNT_BIN = os.environ.get("PG_MOUNT_BIN", "/bin/mount")
UMOUNT_BIN = os.environ.get("PG_UMOUNT_BIN", "/bin/umount")
# Directories on the stick that never hold a user backup, and never make
# a stick "non-empty" for the export guard either: Windows, macOS and
# ext4 all leave these on a factory-formatted or freshly-touched drive.
USB_SKIP_DIRS = set(["system volume information", ".trash", ".trash-info",
                     ".system volume information", "$recycle.bin", ".fseventsd",
                     ".spotlight-v100", ".documentrevisions-v100",
                     "lost+found", "system volume information.tmp"])
# Rescue opt-in marker. usb-export writes it next to the archive; the
# first-boot rescue only restores from a partition that carries it, so a
# random stick (or a compromised one) planted in an unattended device
# cannot push settings — rescue requires a stick this WebUI prepared.
RESCUE_SENTINEL = "PGEN_USB_RESCUE"
# Conf keys the unattended USB rescue must never apply. The browser
# import is a deliberate user action and may restore them; first-boot
# restore runs with no user and no chance to review, so OTA trust keys
# (the same set the generic conf writer denies, webui.pm) are stripped.
USB_RESTORE_DENY_CONF_KEYS = set(["ota_repo", "ota_repo_trusted", "ota_target"])
CONF_DEST = "/etc/PGenerator/PGenerator.conf"

# kind, source/destination, component label
BACKUP_SPECS = (
    ("file", "/etc/PGenerator/PGenerator.conf", "PGenerator+ configuration"),
    ("file", "/etc/PGenerator/hdr20_postcal_shadow_matrix.json", "HDR calibration configuration"),
    ("file", "/var/lib/PGenerator/meter_settings.json", "meter and calibration settings"),
    ("dir", "/var/lib/PGenerator/custom-series", "custom measurement series"),
    ("dir", "/var/lib/PGenerator/ccss/custom", "custom meter profiles"),
    ("dir", "/var/lib/PGenerator/images", "custom diagnostic images"),
    ("dir", "/var/lib/PGenerator/video", "custom diagnostic videos"),
    ("dir", "/var/lib/PGenerator/icc", "ICC profiles and measurements"),
    ("file", "/var/lib/PGenerator/lg/clients.json", "paired LG displays"),
    ("dir", "/var/lib/PGenerator/lg/calibration-history", "1D LUT and Dolby Vision history"),
    ("dir", "/var/lib/PGenerator/lg/luts", "3D LUT history"),
    ("dir", "/var/lib/PGenerator/lg/autocal-runs", "AutoCal run history"),
    ("dir", "/var/lib/PGenerator/lg/profile-captures", "calibration profile captures"),
    ("dir", "/var/lib/PGenerator/lg/ddc", "LG DDC configuration"),
    ("dir", "/var/lib/PGenerator/reports/full-autocal", "Full AutoCal reports"),
)


class BackupError(Exception):
    pass


def utc_stamp():
    return datetime.datetime.utcnow().strftime("%Y%m%d-%H%M%S")


def utc_iso():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def archive_name(path):
    return "data" + path


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def iter_source_entries(kind, source):
    if kind == "file":
        if os.path.isfile(source) and not os.path.islink(source):
            yield source
        return
    if not os.path.isdir(source) or os.path.islink(source):
        return
    for root, dirs, files in os.walk(source):
        # Diagnostic-video frame caches are regenerated from the original
        # uploaded video and can be many times larger than the source file.
        dirs[:] = sorted([name for name in dirs if name != ".diagseq" and not os.path.islink(os.path.join(root, name))])
        for name in sorted(files):
            path = os.path.join(root, name)
            if os.path.isfile(path) and not os.path.islink(path):
                yield path


def collect_backup_files():
    files = []
    components = []
    total_bytes = 0
    for kind, source, label in BACKUP_SPECS:
        component_count = 0
        component_bytes = 0
        for path in iter_source_entries(kind, source):
            size = os.path.getsize(path)
            item = {
                "path": archive_name(path),
                "size": size,
                "sha256": sha256_file(path),
            }
            files.append((path, item))
            total_bytes += size
            component_bytes += size
            component_count += 1
        if component_count:
            components.append({
                "name": label,
                "source": source,
                "files": component_count,
                "bytes": component_bytes,
            })
    files.sort(key=lambda entry: entry[1]["path"])
    return files, components, total_bytes


def create_archive(output_path, software_version):
    files, components, total_bytes = collect_backup_files()
    if not files:
        raise BackupError("No PGenerator+ settings or profile data were found")
    manifest = {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "created_utc": utc_iso(),
        "software_version": software_version or "unknown",
        "file_count": len(files),
        "uncompressed_bytes": total_bytes,
        "components": components,
        "files": [item for unused_path, item in files],
    }
    parent = os.path.dirname(output_path) or "."
    if not os.path.isdir(parent):
        os.makedirs(parent)
    temp_path = output_path + ".tmp"
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    with tarfile.open(temp_path, "w:gz", dereference=True) as archive:
        raw = json.dumps(manifest, sort_keys=True, indent=2).encode("utf-8")
        info = tarfile.TarInfo("manifest.json")
        info.size = len(raw)
        info.mode = 0o644
        info.mtime = int(time.time())
        archive.addfile(info, io.BytesIO(raw))
        for source, item in files:
            archive.add(source, arcname=item["path"], recursive=False)
    os.chmod(temp_path, 0o644)
    os.rename(temp_path, output_path)
    return manifest


def normalized_member_name(name):
    if not isinstance(name, str):
        raise BackupError("Archive contains an invalid path")
    name = name.replace("\\", "/")
    if name.startswith("/") or "\x00" in name:
        raise BackupError("Archive contains an unsafe path")
    normalized = posixpath.normpath(name)
    if normalized in ("", ".") or normalized == ".." or normalized.startswith("../"):
        raise BackupError("Archive contains an unsafe path")
    return normalized


def allowed_archive_path(name):
    if name == "manifest.json":
        return True
    for kind, destination, unused_label in BACKUP_SPECS:
        base = archive_name(destination)
        if kind == "file" and name == base:
            return True
        if kind == "dir" and (name == base or name.startswith(base + "/")):
            return True
    return False


def verify_archive_hashes(archive_path):
    # Stream every manifest-listed member through sha256 without writing
    # anything: usb rescue uses this to rank/validate candidates before
    # choosing one, so a corrupt newest archive falls back to an older
    # valid one instead of failing the whole restore.
    archive, members, manifest, expected = inspect_archive(archive_path)
    try:
        by_name = {}
        for member in members:
            name = normalized_member_name(member.name)
            if member.isfile() and name in expected:
                by_name[name] = member
        for name, member in by_name.items():
            digest = hashlib.sha256()
            source = archive.extractfile(member)
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            if digest.hexdigest() != str(expected[name].get("sha256", "")):
                raise BackupError("Backup integrity check failed for %s" % name)
    finally:
        archive.close()


def inspect_archive(archive_path):
    if not os.path.isfile(archive_path):
        raise BackupError("Backup upload is missing")
    if os.path.getsize(archive_path) > MAX_ARCHIVE_BYTES:
        raise BackupError("Backup exceeds the 512 MB size limit")
    try:
        archive = tarfile.open(archive_path, "r:*")
    except (tarfile.TarError, IOError) as error:
        raise BackupError("Backup archive is invalid: %s" % error)
    members = archive.getmembers()
    if len(members) > MAX_MEMBERS:
        archive.close()
        raise BackupError("Backup contains too many files")
    expanded = 0
    seen = set()
    manifest_member = None
    for member in members:
        name = normalized_member_name(member.name)
        if name in seen:
            archive.close()
            raise BackupError("Backup contains duplicate paths")
        seen.add(name)
        if not allowed_archive_path(name):
            archive.close()
            raise BackupError("Backup contains unsupported data: %s" % name)
        if not (member.isfile() or member.isdir()):
            archive.close()
            raise BackupError("Backup contains links or special files")
        if member.isfile():
            expanded += member.size
            if expanded > MAX_EXPANDED_BYTES:
                archive.close()
                raise BackupError("Expanded backup exceeds the safety limit")
        if name == "manifest.json":
            manifest_member = member
    if manifest_member is None or not manifest_member.isfile():
        archive.close()
        raise BackupError("Backup manifest is missing")
    try:
        manifest_raw = archive.extractfile(manifest_member).read()
        manifest = json.loads(manifest_raw.decode("utf-8"))
    except Exception as error:
        archive.close()
        raise BackupError("Backup manifest is invalid: %s" % error)
    if manifest.get("format") != FORMAT or int(manifest.get("schema_version", 0)) != SCHEMA_VERSION:
        archive.close()
        raise BackupError("This is not a supported PGenerator+ system backup")
    listed = manifest.get("files")
    if not isinstance(listed, list) or len(listed) > MAX_MEMBERS:
        archive.close()
        raise BackupError("Backup file manifest is invalid")
    expected = {}
    for item in listed:
        if not isinstance(item, dict):
            archive.close()
            raise BackupError("Backup file manifest is invalid")
        name = normalized_member_name(item.get("path", ""))
        if name == "manifest.json" or not allowed_archive_path(name) or name in expected:
            archive.close()
            raise BackupError("Backup file manifest contains an invalid path")
        expected[name] = item
    actual_files = set(normalized_member_name(member.name) for member in members if member.isfile() and normalized_member_name(member.name) != "manifest.json")
    if actual_files != set(expected.keys()):
        archive.close()
        raise BackupError("Backup contents do not match its manifest")
    return archive, members, manifest, expected


def extract_and_verify(archive_path, staging_dir):
    archive, members, manifest, expected = inspect_archive(archive_path)
    try:
        for member in members:
            name = normalized_member_name(member.name)
            if name == "manifest.json":
                continue
            target = os.path.join(staging_dir, *name.split("/"))
            if member.isdir():
                if not os.path.isdir(target):
                    os.makedirs(target)
                continue
            parent = os.path.dirname(target)
            if not os.path.isdir(parent):
                os.makedirs(parent)
            source = archive.extractfile(member)
            digest = hashlib.sha256()
            size = 0
            with open(target, "wb") as output:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
            item = expected[name]
            if size != int(item.get("size", -1)) or digest.hexdigest() != str(item.get("sha256", "")):
                raise BackupError("Backup integrity check failed for %s" % name)
    finally:
        archive.close()
    return manifest


def copy_file_atomic(source, destination):
    parent = os.path.dirname(destination)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    temp_path = destination + ".restore.tmp"
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    shutil.copyfile(source, temp_path)
    os.chmod(temp_path, 0o644)
    os.rename(temp_path, destination)


def merge_tree(source, destination):
    if not os.path.isdir(destination):
        os.makedirs(destination)
    for root, dirs, files in os.walk(source):
        relative = os.path.relpath(root, source)
        target_root = destination if relative == "." else os.path.join(destination, relative)
        if not os.path.isdir(target_root):
            os.makedirs(target_root)
        for name in dirs:
            target_dir = os.path.join(target_root, name)
            if not os.path.isdir(target_dir):
                os.makedirs(target_dir)
        for name in files:
            copy_file_atomic(os.path.join(root, name), os.path.join(target_root, name))


def apply_pgenerator_ownership(path):
    try:
        uid = pwd.getpwnam("pgenerator").pw_uid
        gid = grp.getgrnam("pgenerator").gr_gid
    except KeyError:
        return
    paths = [path]
    if os.path.isdir(path):
        paths = []
        for root, dirs, files in os.walk(path):
            paths.append(root)
            paths.extend(os.path.join(root, name) for name in dirs)
            paths.extend(os.path.join(root, name) for name in files)
    for item in paths:
        try:
            os.chown(item, uid, gid)
            mode = os.stat(item).st_mode & 0o777
            if os.path.isdir(item):
                os.chmod(item, mode | 0o700)
            else:
                os.chmod(item, mode | 0o600)
        except OSError:
            pass


ROLLBACK_DIR = "/var/lib/PGenerator/system-backups"


def create_rollback_snapshot(software_version):
    directory = ROLLBACK_DIR
    if not os.path.isdir(directory):
        os.makedirs(directory)
    path = os.path.join(directory, "pre-import-%s.pgbackup" % utc_stamp())
    create_archive(path, software_version)
    backups = sorted(
        [os.path.join(directory, name) for name in os.listdir(directory) if name.startswith("pre-import-") and name.endswith(".pgbackup")],
        key=lambda item: os.path.getmtime(item),
        reverse=True,
    )
    for stale in backups[3:]:
        try:
            os.unlink(stale)
        except OSError:
            pass
    return path


def strip_denied_conf_keys(conf_path):
    # Unattended first-boot restore must not plant the OTA trust keys
    # (same set the generic conf writer denies in webui.pm): a restored
    # ota_repo + ota_repo_trusted=1 would let pgenerator-update apply an
    # unsigned tarball as root with nobody having chosen the repo.
    try:
        with open(conf_path, "r") as handle:
            lines = handle.readlines()
    except IOError:
        return
    kept = []
    dropped = False
    for line in lines:
        match = re.match(r"^\s*([A-Za-z0-9_]+)\s*=", line)
        if match and match.group(1) in USB_RESTORE_DENY_CONF_KEYS:
            dropped = True
            continue
        kept.append(line)
    if not dropped:
        return
    temp_path = conf_path + ".deny.tmp"
    with open(temp_path, "w") as handle:
        handle.writelines(kept)
    os.chmod(temp_path, 0o644)
    os.rename(temp_path, conf_path)


def restore_archive(archive_path, software_version, unattended=False):
    staging_dir = tempfile.mkdtemp(prefix="pgenerator-backup-restore-")
    try:
        manifest = extract_and_verify(archive_path, staging_dir)
        rollback_path = create_rollback_snapshot(software_version)
        restored_components = []
        restored_files = 0
        for kind, destination, label in BACKUP_SPECS:
            source = os.path.join(staging_dir, *archive_name(destination).split("/"))
            if kind == "file":
                if not os.path.isfile(source):
                    continue
                if unattended and destination == CONF_DEST:
                    # Strip OTA trust keys from the STAGED copy first: the
                    # live conf must never hold them, even momentarily —
                    # strip-then-rename means the atomic install either
                    # shows the old conf or the clean one, never the raw
                    # restored one.
                    strip_denied_conf_keys(source)
                copy_file_atomic(source, destination)
                restored_files += 1
            else:
                if not os.path.isdir(source):
                    continue
                restored_files += sum(len(files) for unused_root, unused_dirs, files in os.walk(source))
                merge_tree(source, destination)
            if destination.startswith("/var/lib/PGenerator/"):
                apply_pgenerator_ownership(destination)
            restored_components.append(label)
        return {
            "status": "ok",
            "message": "System settings and profile history imported",
            "source_version": manifest.get("software_version", "unknown"),
            "restored_files": restored_files,
            "components": restored_components,
            "rollback_backup": rollback_path,
            "restart_required": True,
        }
    finally:
        shutil.rmtree(staging_dir, ignore_errors=True)


def run_cmd(argv):
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate()
    except Exception:
        proc.kill()
        return (1, b"", b"")
    return (proc.returncode, out or b"", err or b"")


def root_block_nodes():
    # Block node names holding the root filesystem (avoids touching the
    # boot device itself when the appliance boots from USB): base name of
    # the /dev node and, for a partition, its parent disk name.
    roots = set()
    try:
        with open("/proc/mounts", "r") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) < 2 or parts[1] != "/":
                    continue
                node = parts[0].rsplit("/", 1)[-1]
                # Kernel-less setups (and some vendor images) mount root
                # as /dev/root, a symlink to the real node: resolve it or
                # the boot disk is never excluded on a USB-booted unit.
                dev_link = "/dev/" + node
                if os.path.islink(dev_link) or os.path.exists(dev_link):
                    node = os.path.realpath(dev_link).rsplit("/", 1)[-1]
                roots.add(node)
                match = re.match(r"^(.*(?:mmcblk\d|sd[a-z]+|nvme\d+n\d+))p?\d+$", node)
                if match:
                    roots.add(match.group(1))
    except IOError:
        pass
    return roots


def list_usb_backup_candidates():
    # USB-attached block partitions, excluding the one holding root
    # (the appliance may boot from USB; never touch its own disk).
    candidates = []
    try:
        devs = sorted(os.listdir(USB_SCAN_ROOT))
    except OSError:
        return candidates
    root_nodes = root_block_nodes()
    for dev in devs:
        if not re.match(r"^sd[a-z]+$", dev):
            continue
        real = os.path.realpath(os.path.join(USB_SCAN_ROOT, dev))
        if "/usb" not in real:
            continue
        if dev in root_nodes:
            continue
        try:
            entries = sorted(os.listdir(os.path.join(USB_SCAN_ROOT, dev)))
        except OSError:
            entries = []
        parts = [name for name in entries if re.match("^%s[0-9]+$" % dev, name)]
        if not parts:
            # Unpartitioned stick (superfloppy): the whole disk is the
            # candidate, and its sysfs node lives at the scan root.
            parts = [dev]
        for part in parts:
            if part in root_nodes:
                continue
            if part != dev:
                # Real kernels nest partitions INSIDE the disk directory
                # (/sys/block/sdb/sdb1), never as siblings — checking
                # /sys/block/sdb1 drops every partitioned stick.
                if not os.path.isdir(os.path.join(USB_SCAN_ROOT, dev, part)):
                    continue
            # Superfloppy case (part == dev): the whole disk is a single
            # filesystem with NO sysfs subdirectory beneath it, so the
            # nested check must not apply or every unpartitioned stick
            # is silently dropped.
            candidates.append(part)
    return candidates


def mount_ro(part):
    dest = os.path.join(USB_MOUNT_BASE, part)
    if not os.path.isdir(dest):
        os.makedirs(dest)
    rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "/dev/" + part, dest])
    if rc == 0:
        return dest
    rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "-t", "vfat", "/dev/" + part, dest])
    if rc == 0:
        return dest
    return None


def umount_path(dest):
    run_cmd([UMOUNT_BIN, dest])
    try:
        os.rmdir(dest)
    except OSError:
        pass


def find_archives_on(part):
    # Returns (archives, mount_point_or_None); archives are
    # (part, relative_name, absolute_path) tuples. A partition only
    # counts as a rescue source if it carries the PGEN_USB_RESCUE
    # sentinel written by usb-export: rescue is opt-in, so an arbitrary
    # stick cannot push settings onto an unattended first boot.
    dest = mount_ro(part)
    found = []
    if dest is None:
        return (found, None)
    sentinel = None
    for root, dirs, files in os.walk(dest):
        dirs[:] = [d for d in dirs if d.lower() not in USB_SKIP_DIRS]
        if RESCUE_SENTINEL in files:
            sentinel = os.path.join(root, RESCUE_SENTINEL)
        for name in files:
            if name.lower().endswith(".pgbackup"):
                full = os.path.join(root, name)
                found.append((part, os.path.relpath(full, dest), full))
    if sentinel is None:
        found = []
    return (found, dest)


def usb_restore(software_version):
    parts = list_usb_backup_candidates()
    if not parts:
        raise BackupError("No USB drive found")
    archives = []
    mounts = []
    try:
        for part in parts:
            found, dest = find_archives_on(part)
            if dest is not None:
                mounts.append(dest)
            archives.extend(found)
        if not archives:
            raise BackupError("No .pgbackup found on the USB drive")
        usable = []
        for part, rel, full in archives:
            try:
                inspect_archive(full)
                # Per-file sha256 for EVERY candidate, streamed from the
                # archive (no staging writes): an archive that fails
                # integrity must fall through to an older valid one, not
                # abort the rescue after ranking it newest.
                verify_archive_hashes(full)
                usable.append((part, rel, full))
            except BackupError:
                continue
        if not usable:
            raise BackupError("No valid .pgbackup found on the USB drive")
        # Newest first by embedded created_utc (fallback: file mtime).
        def sort_key(entry):
            full = entry[2]
            created = ""
            try:
                arch, _m, manifest, _e = inspect_archive(full)
                arch.close()
                created = str(manifest.get("created_utc", ""))
            except BackupError:
                pass
            return (created, os.path.getmtime(full))
        usable.sort(key=sort_key, reverse=True)
        part, rel, full = usable[0]
        result = restore_archive(full, software_version, unattended=True)
        result["usb_device"] = part
        result["usb_archive"] = rel
        return result
    finally:
        for dest in mounts:
            umount_path(dest)


def stick_is_blank(dest):
    # A freshly formatted or Windows/macOS-touched stick counts as blank:
    # only entries outside USB_SKIP_DIRS are somebody's data. A stranded
    # write temp from an interrupted export also does not count, or the
    # retry could never proceed. A rescue stick THIS button already wrote
    # (sentinel + *.pgbackup) counts as blank too, so the backup can be
    # refreshed without a manual wipe; restore ranks by created_utc, so
    # the newest archive wins and older ones are simply superseded.
    for entry in os.listdir(dest):
        if entry.lower() in USB_SKIP_DIRS:
            continue
        if entry.endswith(".pgbackup.tmp"):
            continue
        if entry == RESCUE_SENTINEL:
            continue
        if entry.lower().endswith(".pgbackup"):
            continue
        return False
    return True


def usb_export(software_version):
    parts = list_usb_backup_candidates()
    if not parts:
        raise BackupError("No USB drive found")
    for part in parts:
        # Write only to an empty stick: a drive that already holds files
        # is somebody's data stick, not a rescue target. Check emptiness
        # READ-ONLY first — mounting rw would set the vfat dirty bit
        # before we even know the stick is blank — and remount rw only
        # for the winning stick. The finally below unmounts EVERY stick
        # we mounted, empty or not, so nothing stays mounted rw.
        dest = os.path.join(USB_MOUNT_BASE + "-rw", part)
        if not os.path.isdir(dest):
            os.makedirs(dest)
        rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "/dev/" + part, dest])
        if rc != 0:
            rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "ro", "-t", "vfat", "/dev/" + part, dest])
        if rc != 0:
            continue
        try:
            try:
                if not stick_is_blank(dest):
                    continue
            except OSError:
                continue
            rc, _out, _err = run_cmd([MOUNT_BIN, "-o", "remount,rw", dest])
            if rc != 0:
                # Filesystems without remount support: try a fresh rw mount.
                run_cmd([UMOUNT_BIN, dest])
                rc, _out, _err = run_cmd([MOUNT_BIN, "/dev/" + part, dest])
                if rc != 0:
                    rc, _out, _err = run_cmd([MOUNT_BIN, "-t", "vfat", "/dev/" + part, dest])
            if rc != 0:
                continue
            try:
                # A failed create_archive can leave <name>.pgbackup.tmp;
                # clear one before writing so the stick is never poisoned
                # for the next attempt (stick_is_blank tolerates it too).
                for stale in os.listdir(dest):
                    if stale.endswith(".pgbackup.tmp"):
                        try:
                            os.unlink(os.path.join(dest, stale))
                        except OSError:
                            pass
                stamp = utc_stamp()
                out_path = os.path.join(dest, "PGenerator_plus_system_backup_v%s_%s.pgbackup" % (
                    (software_version or "unknown"), stamp))
                manifest = create_archive(out_path, software_version)
                try:
                    os.chmod(out_path, 0o644)
                except OSError:
                    pass
                # Opt-in marker the first-boot rescue looks for: no
                # sentinel, no rescue from this stick.
                with open(os.path.join(dest, RESCUE_SENTINEL), "w") as handle:
                    handle.write("pgenerator-usb-rescue\n")
                run_cmd(["/bin/sync"])
                return {
                    "status": "ok",
                    "message": "Backup written to the USB drive",
                    "usb_device": part,
                    "usb_archive": os.path.basename(out_path),
                    "file_count": manifest["file_count"],
                    "uncompressed_bytes": manifest["uncompressed_bytes"],
                }
            except (BackupError, OSError, IOError):
                continue
        finally:
            run_cmd([UMOUNT_BIN, dest])
            try:
                os.rmdir(dest)
            except OSError:
                pass
    raise BackupError("No writable empty USB drive found")


def main():
    parser = argparse.ArgumentParser(description="PGenerator+ system backup")
    subparsers = parser.add_subparsers(dest="command")
    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--version", default="unknown")
    import_parser = subparsers.add_parser("import")
    import_parser.add_argument("--input", required=True)
    import_parser.add_argument("--version", default="unknown")
    usb_restore_parser = subparsers.add_parser("usb-restore")
    usb_restore_parser.add_argument("--version", default="unknown")
    usb_export_parser = subparsers.add_parser("usb-export")
    usb_export_parser.add_argument("--version", default="unknown")
    args = parser.parse_args()
    try:
        if args.command == "export":
            manifest = create_archive(args.output, args.version)
            result = {
                "status": "ok",
                "file_count": manifest["file_count"],
                "uncompressed_bytes": manifest["uncompressed_bytes"],
                "components": manifest["components"],
            }
        elif args.command == "import":
            result = restore_archive(args.input, args.version)
        elif args.command == "usb-restore":
            result = usb_restore(args.version)
        elif args.command == "usb-export":
            result = usb_export(args.version)
        else:
            parser.error("an export or import command is required")
            return 2
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except BackupError as error:
        print(json.dumps({"status": "error", "message": str(error)}, separators=(",", ":")))
        return 1
    except Exception as error:
        print(json.dumps({"status": "error", "message": "System backup failed: %s" % error}, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())
