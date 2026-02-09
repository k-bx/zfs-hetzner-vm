# Debian 13 (Trixie) + ZFS Mirror (RAID-1) on Hetzner Dedicated

This repo includes `hetzner-debian13-zfs-setup.sh`, which installs Debian 13 on ZFS using ZFSBootMenu and supports a 2-disk ZFS mirror (RAID-1) for dedicated servers.

## Preconditions (Before Running The Script)

1. Boot the server into **Rescue mode** from Hetzner Robot.
1. SSH into the rescue system as `root`.
1. Strongly recommended: run inside `screen` so you do not lose progress:

```bash
export LC_ALL=en_US.UTF-8
screen -S zfs
```

4. Stop any automatic Linux software RAID (common on some Hetzner images):

```bash
vgchange -an || true
mdadm --stop --scan || true
mdadm --remove --scan || true
cat /proc/mdstat
```

5. Ensure the two target disks are not mounted/in-use and are the ones you intend to wipe:

```bash
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT,RO
blkid || true
```

If you still see `/dev/md*` devices or LVM volumes (`vg0-*`) in `lsblk`, it means something is still active:
- Deactivate LVM again: `vgchange -an`
- Then stop the specific arrays: `mdadm --stop /dev/md0 /dev/md1 /dev/md2` (adjust to what `cat /proc/mdstat` shows)

If `blkid` shows `linux_raid_member` or other leftover signatures on the target disks, wipe signatures (pick one approach):

```bash
# Option A (broad): wipe filesystem/RAID signatures
wipefs -a /dev/nvme0n1
wipefs -a /dev/nvme1n1

# Option B (mdraid-specific): remove md superblocks
mdadm --zero-superblock /dev/nvme0n1 || true
mdadm --zero-superblock /dev/nvme1n1 || true
```

## Run

From this repo directory:

```bash
bash hetzner-debian13-zfs-setup.sh
```

During the prompts:

1. Select **both** disks (two identical drives) to build a mirror.
1. When asked about ZFS mirror mode, choose **Yes**.
1. For networking:
   - On dedicated servers, choose **STATIC** networking when the script offers to use the detected config from rescue.
   - The script detects DNS via `resolvectl` (not `/etc/resolv.conf`), so it works even when rescue uses `127.0.0.53`.

The script will reboot at the end.

## After Boot: Verify RAID-1 And Networking

1. Verify the pool is mirrored:

```bash
zpool status
zpool get ashift,bootfs,cachefile
```

You should see a `mirror-0` vdev with both member partitions.

2. Verify the root dataset properties (important for ZFSBootMenu boot):

```bash
zfs get mountpoint,canmount rpool/ROOT/debian
```

Expected:
- `mountpoint=/`
- `canmount=noauto`

2. Verify networking:

```bash
networkctl status
ip -4 addr
ip -4 route
resolvectl status || true
```

3. Confirm the applied network config:

```bash
cat /etc/systemd/network/10-hetzner.network
```

If your rescue system uses a routed-subnet style route (common on Hetzner dedicated), you should see IPv4 configured as `/32` plus explicit routes.

## How Long To Wait After Reboot

- If the install succeeded, you typically get ping/SSH within **2-5 minutes** after power cycling (UEFI firmware + ZFSBootMenu + Debian boot).
- If you still have no ping/SSH after **5 minutes**, assume it did not boot the OS (boot order / boot menu) and go back to rescue to check UEFI boot entries.

## Notes / Troubleshooting

- If the box boots but has no network:
  - Double-check the `MACAddress=` in `/etc/systemd/network/10-hetzner.network` matches your NIC.
  - Ensure the IPv4 address/prefix and gateway match what Hetzner provides for the server.
  - Compare `ip -4 route` in rescue vs the installed OS. If rescue shows your subnet routed via the gateway, your OS must replicate it (script does this automatically when detected).
- If you selected two disks but the pool is not mirrored:
  - Re-run `zpool status`. You should see `mirror-0`. If you see two devices without `mirror`, you created a stripe and should reinstall (or rebuild the pool).
- If you need to mount the root dataset from rescue after installation:
  - ZFS datasets with `mountpoint=/` cannot be mounted via `mount -t zfs ...`.
  - Use `zfs set mountpoint=/mnt/debian rpool/ROOT/debian; zfs mount rpool/ROOT/debian` temporarily, then restore it to `/` afterwards.
- If the system does not boot from disk (common on some dedicated firmware):
  - In rescue, install `efibootmgr` and create explicit UEFI boot entries pointing at `\\EFI\\Boot\\bootx64.efi` on each ESP.
  - Verify with `efibootmgr -v` that the `BootOrder` begins with the `ZFSBootMenu` entries and optionally set `BootNext` for the next reboot.

## Example (pve-hz-3, 2026-02-09)

Detected in rescue mode:
- Boot mode: UEFI (`/sys/firmware/efi` present)
- Disks: `/dev/nvme0n1` and `/dev/nvme1n1` (1.92TB each)
- Active mdraid to stop before install: `md0`, `md1`, `md2` (RAID-1)
- Network:
  - Primary link in rescue: `eth0`
  - MAC: `10:7c:61:56:f1:5c`
  - IPv4: `142.132.150.135/26`, gateway `142.132.150.129`
  - IPv6: `2a01:4f8:261:2684::2/64`, gateway `fe80::1`
  - DNS: `185.12.64.1`, `185.12.64.2`, `2a01:4ff:ff00::add:1`, `2a01:4ff:ff00::add:2`
