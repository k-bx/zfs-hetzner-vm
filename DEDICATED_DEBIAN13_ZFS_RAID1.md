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
mdadm --stop --scan || true
```

5. Ensure the two target disks are not mounted/in-use and are the ones you intend to wipe:

```bash
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT,RO
blkid || true
```

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

The script will reboot at the end.

## After Boot: Verify RAID-1 And Networking

1. Verify the pool is mirrored:

```bash
zpool status
zpool get ashift,bootfs,cachefile
```

You should see a `mirror-0` vdev with both member partitions.

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

## Notes / Troubleshooting

- If the box boots but has no network:
  - Double-check the `MACAddress=` in `/etc/systemd/network/10-hetzner.network` matches your NIC.
  - Ensure the IPv4 address/prefix and gateway match what Hetzner provides for the server.
- If you selected two disks but the pool is not mirrored:
  - Re-run `zpool status`. You should see `mirror-0`. If you see two devices without `mirror`, you created a stripe and should reinstall (or rebuild the pool).

