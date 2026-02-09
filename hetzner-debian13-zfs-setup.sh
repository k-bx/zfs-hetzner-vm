#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Debian 13 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info

set -euo pipefail

# ---- Configuration ----
SYSTEM_HOSTNAME=""
ROOT_PASSWORD=""
ZFS_POOL=""
DEBIAN_CODENAME="trixie"   # Debian 13
TARGET="/mnt/debian"

ZBM_BIOS_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.tar.gz"
ZBM_EFI_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.EFI"

MAIN_BOOT="/main_boot"

# Hetzner mirrors for Debian
MIRROR_SITE="https://mirror.hetzner.com"
MIRROR_MAIN="deb ${MIRROR_SITE}/debian/packages ${DEBIAN_CODENAME} main contrib non-free non-free-firmware"
MIRROR_UPDATES="deb ${MIRROR_SITE}/debian/packages ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware"
MIRROR_SECURITY="deb ${MIRROR_SITE}/debian/security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware"
MIRROR_BACKPORTS="deb ${MIRROR_SITE}/debian/packages ${DEBIAN_CODENAME}-backports main contrib non-free non-free-firmware"

# Global variables
INSTALL_DISKS=()
USE_MIRROR=true

EFI_MODE=false

BOOT_PARTS=()
ZFS_PARTS=()

# Network (auto-detected from rescue for dedicated servers)
NETWORK_MODE="static" # "static" (recommended for dedicated) or "dhcp"
NET_IFACE=""
NET_MAC=""
NET_IPV4_CIDR=""
NET_GW4=""
NET_IPV6_CIDR=""
NET_GW6=""
NET_DNS_SERVERS=()

# ---- Helpers ----
function part_path {
    local disk="$1"
    local part_num="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

# ---- User Input Functions ----
function setup_whiptail_colors {
    # Green text on black background - classic terminal theme
    export NEWT_COLORS='
    root=green,black
    window=green,black
    shadow=green,black
    border=green,black
    title=green,black
    textbox=green,black
    button=black,green
    listbox=green,black
    actlistbox=black,green
    actsellistbox=black,green
    checkbox=green,black
    actcheckbox=black,green
    entry=green,black
    label=green,black
    '
}

function check_whiptail {
    if ! command -v whiptail &> /dev/null; then
        echo "Installing whiptail..."
        apt update
        apt install -y whiptail
    fi
    setup_whiptail_colors
}

function get_hostname {
    while true; do
        SYSTEM_HOSTNAME=$(whiptail \
            --title " System Hostname " \
            --inputbox "\nEnter the hostname for the new system:" \
            10 60 "zfs-debian" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Validate hostname
        if [[ "$SYSTEM_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ${#SYSTEM_HOSTNAME} -le 63 ]]; then
            break
        else
            whiptail \
                --title " Invalid Hostname " \
                --msgbox "Invalid hostname. Please use only letters, numbers, and hyphens. Must start and end with alphanumeric character. Maximum 63 characters." \
                12 60
        fi
    done
}

function get_zfs_pool_name {
    while true; do
        ZFS_POOL=$(whiptail \
            --title " ZFS Pool Name " \
            --inputbox "\nEnter the name for the ZFS pool:" \
            10 60 "rpool" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Validate ZFS pool name
        if [[ "$ZFS_POOL" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] && [[ ${#ZFS_POOL} -le 255 ]]; then
            break
        else
            whiptail \
                --title " Invalid Pool Name " \
                --msgbox "Invalid ZFS pool name. Must start with a letter and contain only letters, numbers, hyphens, and underscores. Maximum 255 characters." \
                12 60
        fi
    done
}

function get_root_password {
    while true; do
        # Get first password input
        local password1
        local password2
        
        password1=$(whiptail \
            --title " Root Password " \
            --passwordbox "\nEnter root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Get password confirmation
        password2=$(whiptail \
            --title " Confirm Root Password " \
            --passwordbox "\nConfirm root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Check if passwords match
        if [ "$password1" = "$password2" ]; then
            if [ -n "$password1" ]; then
                ROOT_PASSWORD="$password1"
                break
            else
                whiptail \
                    --title " Empty Password " \
                    --msgbox "Password cannot be empty. Please enter a password." \
                    10 50
            fi
        else
            whiptail \
                --title " Password Mismatch " \
                --msgbox "Passwords do not match. Please try again." \
                10 50
        fi
    done
}

function show_summary_and_confirm {
    local disks_display
    disks_display="$(printf '%s ' "${INSTALL_DISKS[@]}" | sed 's/[[:space:]]*$//')"

    local net_display="Mode: ${NETWORK_MODE}"
    if [[ "$NETWORK_MODE" == "static" && -n "${NET_MAC}" ]]; then
        local dns_display
        dns_display="$(printf '%s ' "${NET_DNS_SERVERS[@]}" | sed 's/[[:space:]]*$//')"
        net_display="Mode: static
MAC: ${NET_MAC}
IPv4: ${NET_IPV4_CIDR}
GW4: ${NET_GW4}
IPv6: ${NET_IPV6_CIDR}
GW6: ${NET_GW6}
DNS: ${dns_display}"
    fi

    local summary
    summary="Please review the installation settings:

Hostname: $SYSTEM_HOSTNAME
ZFS Pool: $ZFS_POOL
Debian Version: $DEBIAN_CODENAME (13)
Target: $TARGET
Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")
Install Disk(s): ${disks_display}
ZFS Layout: $([ "$USE_MIRROR" = true ] && echo "mirror (RAID-1)" || echo "single/stripe")
Networking:
${net_display}

*** WARNING: This will DESTROY ALL DATA on the selected disk(s)! ***

Do you want to continue with the installation?"
    
    if whiptail \
        --title " Installation Summary " \
        --yesno "$summary" \
        18 60; then
        # User confirmed - just continue silently
        echo "User confirmed installation. Starting now..."
    else
        echo "Installation cancelled by user."
        exit 1
    fi
}

function get_user_input {
    echo "======= Gathering Installation Parameters =========="
    check_whiptail
    
    # Show welcome message
    whiptail \
        --title " ZFS Debian Installer " \
        --msgbox "Welcome to the ZFS Debian Installer for Hetzner Cloud.\n\nThis script will install Debian 13 with ZFS root on your server." \
        12 60
    
    # Get user inputs
    get_hostname
    get_zfs_pool_name
    get_root_password
}

# ---- System Detection Functions ----
function detect_efi {
    echo "======= Detecting EFI support =========="
    
    if [ -d /sys/firmware/efi ]; then
        echo "✓ EFI firmware detected"
        EFI_MODE=true
    else
        echo "✓ Legacy BIOS mode detected"
        EFI_MODE=false
    fi
}

function detect_network_from_rescue {
    # Best-effort auto-detection: use the current rescue system's default route and IP config.
    local def4 def6
    def4="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
    def6="$(ip -6 route show default 2>/dev/null | head -n1 || true)"

    if [[ -n "$def4" ]]; then
        NET_GW4="$(awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"$def4" || true)"
        NET_IFACE="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$def4" || true)"
    fi

    if [[ -n "$NET_IFACE" ]]; then
        NET_IPV4_CIDR="$(ip -4 -o addr show dev "$NET_IFACE" scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)"
        NET_MAC="$(cat "/sys/class/net/$NET_IFACE/address" 2>/dev/null || true)"
    fi

    if [[ -n "$def6" ]]; then
        NET_GW6="$(awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"$def6" || true)"
        local iface6
        iface6="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$def6" || true)"
        if [[ -n "$iface6" ]]; then
            NET_IPV6_CIDR="$(ip -6 -o addr show dev "$iface6" scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)"
        fi
    fi

    NET_DNS_SERVERS=()

    # Prefer resolvectl (rescue often uses stub /etc/resolv.conf -> 127.0.0.53).
    if command -v resolvectl &>/dev/null; then
        mapfile -t NET_DNS_SERVERS < <(
            resolvectl dns 2>/dev/null \
                | awk '{for (i=2;i<=NF;i++) print $i}' \
                | grep -vE '^(127\.0\.0\.53|::1)$' \
                | head -n 4 \
                || true
        )

        if [[ ${#NET_DNS_SERVERS[@]} -eq 0 ]]; then
            # Fallback: parse the "DNS Servers" block from `resolvectl status`.
            mapfile -t NET_DNS_SERVERS < <(
                resolvectl status 2>/dev/null \
                    | awk '
                        $1=="DNS" && $2=="Servers" {in=1; for (i=3;i<=NF;i++) print $i; next}
                        in && $1 ~ /^[0-9a-fA-F:.]+$/ {for (i=1;i<=NF;i++) print $i; next}
                        in && NF==0 {exit}
                    ' \
                    | head -n 4 \
                    || true
            )
        fi
    fi

    # Last resort: /etc/resolv.conf (ignore systemd-resolved stub)
    if [[ ${#NET_DNS_SERVERS[@]} -eq 0 ]]; then
        mapfile -t NET_DNS_SERVERS < <(
            awk '/^nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null \
                | grep -vE '^(127\.0\.0\.53|::1)$' \
                | head -n 3 \
                || true
        )
    fi
}

function select_install_disks {
    echo "======= Selecting installation disks =========="
    
    local candidate_disks=()
    
    # Use lsblk to find all unmounted, writable disks
    while IFS= read -r disk; do
        [[ -n "$disk" ]] && candidate_disks+=("$disk")
    done < <(lsblk -npo NAME,TYPE,RO,MOUNTPOINT | awk '
        $2 == "disk" && $3 == "0" && $4 == "" {print $1}
    ')
    
    if [[ ${#candidate_disks[@]} -eq 0 ]]; then
        echo "No suitable installation disks found" >&2
        echo "Looking for: unmounted, writable disks without partitions in use" >&2
        exit 1
    fi

    # Build whiptail checklist entries: TAG ITEM STATUS
    local menu_entries=()
    for disk in "${candidate_disks[@]}"; do
        local size model
        size="$(lsblk -dnpo SIZE "$disk" 2>/dev/null | head -n1 || true)"
        model="$(lsblk -dnpo MODEL "$disk" 2>/dev/null | sed 's/[[:space:]]\+/ /g' | head -n1 || true)"
        menu_entries+=("$disk" "${size} ${model}" "OFF")
    done

    # Show all available disks for operator sanity
    echo "All available disks:"
    lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT,RO | grep -v loop || true

    while true; do
        mapfile -t INSTALL_DISKS < <(whiptail \
            --title " Installation Disks " \
            --separate-output \
            --checklist "\nSelect ONE or TWO disks for installation.\n\nFor RAID-1 (mirror), select both identical drives.\n\nWARNING: all selected disks will be wiped." \
            20 78 10 \
            "${menu_entries[@]}" \
            3>&1 1>&2 2>&3)

        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi

        if [[ ${#INSTALL_DISKS[@]} -eq 0 ]]; then
            continue
        fi

        if [[ ${#INSTALL_DISKS[@]} -gt 2 ]]; then
            whiptail \
                --title " Too Many Disks " \
                --msgbox "\nPlease select at most TWO disks.\n\nSelected:\n$(printf '%s\n' "${INSTALL_DISKS[@]}")" \
                16 70
            continue
        fi

        if [[ ${#INSTALL_DISKS[@]} -ge 1 ]]; then
            break
        fi
    done

    USE_MIRROR=false
    if [[ ${#INSTALL_DISKS[@]} -gt 1 ]]; then
        if whiptail \
            --title " ZFS Mirror " \
            --yesno "\nYou selected multiple disks:\n\n$(printf '%s\n' "${INSTALL_DISKS[@]}")\n\nCreate a ZFS mirror (RAID-1) across them?\n\nRecommended for 2 identical drives." \
            18 70; then
            USE_MIRROR=true
        else
            USE_MIRROR=false
        fi
    fi

    # Dedicated servers typically require static config; auto-detect from rescue.
    detect_network_from_rescue
    if [[ -n "${NET_IPV4_CIDR}" && -n "${NET_GW4}" && -n "${NET_MAC}" ]]; then
        local dns_display
        dns_display="$(printf '%s ' "${NET_DNS_SERVERS[@]}" | sed 's/[[:space:]]*$//')"
        if whiptail \
            --title " Networking " \
            --yesno "\nDetected network configuration from rescue:\n\nInterface: ${NET_IFACE}\nMAC: ${NET_MAC}\nIPv4: ${NET_IPV4_CIDR}\nGateway: ${NET_GW4}\nDNS: ${dns_display}\n\nUse STATIC networking (recommended for dedicated servers)?" \
            18 72; then
            NETWORK_MODE="static"
        else
            NETWORK_MODE="dhcp"
        fi
    else
        # If we cannot detect, fall back to DHCP.
        NETWORK_MODE="dhcp"
    fi
}

# ---- Rescue System Preparation Functions ----
function remove_unused_kernels {
    echo "=========== Removing unused kernels in rescue system =========="
    for kver in $(find /lib/modules/* -maxdepth 0 -type d \
                    | grep -v "$(uname -r)" \
                    | cut -s -d "/" -f 4); do

        for pkg in "linux-headers-$kver" "linux-image-$kver"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                echo "Purging $pkg ..."
                apt purge --yes "$pkg"
            else
                echo "Package $pkg not installed, skipping."
            fi
        done
    done
}

function install_zfs_on_rescue_system {
    echo "======= Installing ZFS on rescue system =========="
    echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections
    # Enable backports for newer ZFS version
    echo "deb http://mirror.hetzner.com/debian/packages bookworm-backports main contrib" > /etc/apt/sources.list.d/backports.list
    apt update
    apt -t bookworm-backports install -y zfsutils-linux
}

function stop_mdraid_and_lvm {
    # Some rescue environments auto-assemble mdraid/LVM from previous installs, which can make disks "busy".
    echo "======= Stopping mdraid/LVM (if present) =========="
    swapoff -a 2>/dev/null || true
    vgchange -an 2>/dev/null || true
    mdadm --stop --scan 2>/dev/null || true
    mdadm --remove --scan 2>/dev/null || true
}

# ---- Disk Partitioning Functions ----
function partition_disk {
    echo "======= Partitioning disk =========="
    BOOT_PARTS=()
    ZFS_PARTS=()

    for disk in "${INSTALL_DISKS[@]}"; do
        echo "Wiping partition table on: $disk"
        sgdisk -Z "$disk"

        if [ "$EFI_MODE" = true ]; then
            echo "Creating EFI partition layout on: $disk"
            sgdisk -n1:1M:+128M -t1:ef00 -c1:"EFI" "$disk"
            sgdisk -n2:0:0     -t2:bf00 -c2:"zfs" "$disk"
        else
            echo "Creating BIOS partition layout on: $disk"
            sgdisk -n1:1M:+128M -t1:8300 -c1:"boot" "$disk"
            sgdisk -n2:0:0     -t2:bf00 -c2:"zfs" "$disk"
            sgdisk -A 1:set:2 "$disk"
        fi

        BOOT_PARTS+=("$(part_path "$disk" 1)")
        ZFS_PARTS+=("$(part_path "$disk" 2)")
    done

    # Re-read partition tables
    for disk in "${INSTALL_DISKS[@]}"; do
        partprobe "$disk" || true
    done
    udevadm settle

    # Format boot partitions
    if [ "$EFI_MODE" = true ]; then
        for boot_part in "${BOOT_PARTS[@]}"; do
            mkfs.fat -F 32 -n EFI "$boot_part"
        done
    else
        for boot_part in "${BOOT_PARTS[@]}"; do
            mkfs.ext4 -F -L boot "$boot_part"
        done
    fi

    # Convenience: first disk is treated as "primary" for any single-disk assumptions.
    :
}

# ---- ZFS Pool and Dataset Functions ----
function create_zfs_pool {
    echo "======= Creating ZFS pool =========="
    # Clean up any existing ZFS binaries in PATH
    rm -f "$(which zfs)" 2>/dev/null || true
    rm -f "$(which zpool)" 2>/dev/null || true
    
    export PATH=/usr/sbin:$PATH
    modprobe zfs

    local vdev_args=()
    if [[ "$USE_MIRROR" == "true" && ${#ZFS_PARTS[@]} -gt 1 ]]; then
        vdev_args+=(mirror)
    fi
    vdev_args+=("${ZFS_PARTS[@]}")

    zpool create -f -o ashift=12 \
        -o cachefile="/etc/zfs/zpool.cache" \
        -O compression=lz4 \
        -O acltype=posixacl \
        -O xattr=sa \
        -O mountpoint=none \
        "$ZFS_POOL" "${vdev_args[@]}"

    zfs create -o mountpoint=none "$ZFS_POOL/ROOT"

    # During install we mount the dataset explicitly to $TARGET using `mount -t zfs`,
    # which requires mountpoint=legacy. We'll switch it to mountpoint=/ and
    # canmount=noauto during finalization.
    zfs create -o mountpoint=legacy "$ZFS_POOL/ROOT/debian"

    echo "======= Assigning $ZFS_POOL/ROOT/debian dataset as bootable =========="
    zpool set bootfs="$ZFS_POOL/ROOT/debian" "$ZFS_POOL"
    zpool set cachefile="/etc/zfs/zpool.cache" "$ZFS_POOL"
}

function create_additional_zfs_datasets {
    echo "======= Creating additional ZFS datasets with TEMPORARY mountpoints =========="
    
    # Ensure parent datasets are created first
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/debian/var"
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/debian/var/cache"
    
    # Create leaf datasets with temporary mountpoints under $TARGET
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/tmp" "$ZFS_POOL/ROOT/debian/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/debian/tmp"
    
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/var/tmp" "$ZFS_POOL/ROOT/debian/var/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/debian/var/tmp"
    
    zfs create -o mountpoint="$TARGET/var/log" "$ZFS_POOL/ROOT/debian/var/log"    
    zfs set atime=off "$ZFS_POOL/ROOT/debian/var/log"
    
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/var/cache/apt" "$ZFS_POOL/ROOT/debian/var/cache/apt"    
    zfs set atime=off "$ZFS_POOL/ROOT/debian/var/cache/apt"
    
    # Create home dataset separately
    zfs create -o mountpoint="$TARGET/home" "$ZFS_POOL/home"
    
    # Mount all datasets
    zfs mount -a
    
    # Set permissions on the actual ZFS datasets
    echo "Setting permissions on ZFS datasets..."
    chmod 1777 "$TARGET/tmp"
    chmod 1777 "$TARGET/var/tmp"
    echo "✓ Temp directory permissions set (1777)"
}

function set_final_mountpoints {
    echo "======= Setting final mountpoints =========="

    # ZFSBootMenu expects the boot environment dataset to be mountpoint=/ and
    # canmount=noauto so it does not auto-mount during imports.
    zfs set mountpoint=/ "$ZFS_POOL/ROOT/debian"
    zfs set canmount=noauto "$ZFS_POOL/ROOT/debian"
    
    # Leaf datasets - actual system mountpoints
    zfs set mountpoint=/tmp "$ZFS_POOL/ROOT/debian/tmp"
    zfs set mountpoint=/var/tmp "$ZFS_POOL/ROOT/debian/var/tmp"
    zfs set mountpoint=/var/log "$ZFS_POOL/ROOT/debian/var/log"
    zfs set mountpoint=/var/cache/apt "$ZFS_POOL/ROOT/debian/var/cache/apt"
    
    # Home dataset - separate from OS
    zfs set mountpoint=/home "$ZFS_POOL/home"    
    echo ""
    echo "Detailed dataset listing:"
    zfs list -o name,mountpoint -r "$ZFS_POOL"
}

# ---- System Bootstrap Functions ----
function bootstrap_debian_system {
    echo "======= Bootstrapping Debian to temporary directory =========="
    
    # Install debootstrap if not available
    if ! command -v debootstrap &> /dev/null; then
        echo "Installing debootstrap..."
        apt update
        apt install -y debootstrap
    fi

    # Mount the root dataset at $TARGET for the installation phase.
    # This does not change the dataset's mountpoint property.
    mkdir -p "$TARGET"
    mount -t zfs "$ZFS_POOL/ROOT/debian" "$TARGET"

    create_additional_zfs_datasets

    # Bootstrap Debian 13 (Trixie) - include dbus to satisfy systemd-resolved dependency
    debootstrap \
        --components=main,contrib,non-free,non-free-firmware \
        --include=initramfs-tools,dbus,locales,debconf-i18n,apt-utils,keyboard-configuration,console-setup,kbd,zstd,systemd-resolved,systemd-timesyncd \
        "$DEBIAN_CODENAME" \
        "$TARGET" \
        "$MIRROR_SITE/debian/packages"    

}

function setup_chroot_environment {
    echo "======= Mounting virtual filesystems for chroot =========="
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sysfs "$TARGET/sys"
    
    # Only mount specific tmpfs directories, not the entire /run
    mkdir -p "$TARGET/run/lock" "$TARGET/run/shm"
    mount -t tmpfs tmpfs "$TARGET/run/lock"
    mount -t tmpfs tmpfs "$TARGET/run/shm"
    mount -t tmpfs tmpfs "$TARGET/tmp"
    
    mount --bind /dev "$TARGET/dev"
    mount --bind /dev/pts "$TARGET/dev/pts"
}

# ---- System Configuration Functions ----
function configure_basic_system {
    echo "======= Configuring basic system settings =========="
    chroot "$TARGET" /bin/bash <<EOF
set -euo pipefail

# Set hostname from variable
echo "$SYSTEM_HOSTNAME" > /etc/hostname

# Configure timezone (Vienna)
echo "Europe/Vienna" > /etc/timezone
ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime

# Generate locales
cat > /etc/locale.gen <<'LOCALES'
en_US.UTF-8 UTF-8
de_AT.UTF-8 UTF-8
fr_FR.UTF-8 UTF-8  
ru_RU.UTF-8 UTF-8
LOCALES

locale-gen

# Set default locale
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Configure keyboard for German and US with Alt+Shift toggle
cat > /etc/default/keyboard <<'KEYBOARD'
# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="de,ru"
XKBVARIANT=","
XKBOPTIONS="grp:ctrl_shift_toggle"

BACKSPACE="guess"
KEYBOARD

# Apply keyboard configuration to console
setupcon --force

# Update /etc/hosts with the hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $SYSTEM_HOSTNAME" >> /etc/hosts
echo "::1 localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1 ip6-allnodes" >> /etc/hosts
echo "ff02::2 ip6-allrouters" >> /etc/hosts

# Set proper permissions for ZFS datasets
chmod 1777 /tmp
chmod 1777 /var/tmp
EOF

    echo "======= Configuration Summary ======="
    chroot "$TARGET" /bin/bash <<'EOF'
echo "Hostname: $(cat /etc/hostname)"
echo "Timezone: $(cat /etc/timezone)"
echo "Current time: $(date)"
echo "Default locale: $(grep LANG /etc/default/locale)"
echo "Available locales:"
locale -a | grep -E "(en_US|de_AT|fr_FR|ru_RU)"
echo "Keyboard layout: $(grep XKBLAYOUT /etc/default/keyboard)"
EOF
}

function install_system_packages {
    echo "======= Installing ZFS and essential packages in chroot =========="
    # Configure apt sources for Debian 13 in the target system (outside chroot so we can use script variables).
    cat > "$TARGET/etc/apt/sources.list" <<EOF
$MIRROR_MAIN
$MIRROR_UPDATES
$MIRROR_SECURITY
$MIRROR_BACKPORTS
EOF

    chroot "$TARGET" /bin/bash <<'EOF'
	set -euo pipefail
	
	# Update package lists
	apt update

# Install kernel
apt install -y --no-install-recommends linux-image-cloud-amd64 linux-headers-cloud-amd64

# Install essential packages
apt install -y curl nano htop net-tools ssh \
    apt-transport-https ca-certificates gnupg dirmngr \
    firmware-linux-free apparmor

	echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

	# Prefer backports (newer ZFS), but fall back to the regular release if backports is unavailable.
	if ! apt install -y -t trixie-backports zfsutils-linux zfs-initramfs zfs-dkms; then
	    echo "Backports ZFS install failed; retrying without -t trixie-backports..."
	    apt install -y zfsutils-linux zfs-initramfs zfs-dkms
	fi

# Get the actual kernel version installed in the chroot
KERNEL_VERSION=$(ls /lib/modules/ | head -n1)
echo "Detected kernel version: $KERNEL_VERSION"

# Verify ZFS module is available in the chroot filesystem
echo "=== Verifying ZFS module in chroot ==="
if find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f | grep -q .; then
    echo "✓ ZFS module files found in /lib/modules/$KERNEL_VERSION/"
    find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f
else
    echo "✗ ZFS module files not found - attempting DKMS rebuild"
    dkms autoinstall -k "$KERNEL_VERSION" || true
    depmod -a "$KERNEL_VERSION"
    
    # Check again after DKMS rebuild
    if find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f | grep -q .; then
        echo "✓ ZFS module files found after DKMS rebuild"
    else
        echo "✗ ZFS module files still not found - this may cause boot issues"
    fi
fi

# Ensure ZFS module is included in initramfs
echo "zfs" >> /etc/initramfs-tools/modules

# Generate initramfs with ZFS support
update-initramfs -u -k all

# Verify kernel installation
echo "Installed kernel packages:"
dpkg -l | grep linux-image
echo "Kernel version:"
ls /lib/modules/
echo "Kernel files in ZFS dataset:"
ls -la /boot/vmlinuz* /boot/initrd.img* 2>/dev/null || echo "No kernel files found"
EOF
}

function verify_initramfs {
    echo "======= Verifying initramfs contents =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail

echo "=== Checking initramfs for ZFS components ==="
for initrd in /boot/initrd.img-*; do
    if [ -f "$initrd" ]; then
        echo "Checking: $initrd"
        lsinitramfs "$initrd" | grep -E "(zfs|pool|dataset|spl)" | head -10 || echo "No ZFS components found (this might be normal for first check)"
        echo "---"
    fi
done

echo "=== Checking ZFS module files on disk ==="
KERNEL_VERSION=$(ls /lib/modules/ | head -n1)
find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f

echo "=== Testing ZFS commands ==="
which zpool && zpool --version || echo "zpool not found"
which zfs && zfs --version || echo "zfs not found"

echo "=== Checking DKMS status ==="
dkms status || echo "DKMS not available"

echo "=== Checking if ZFS tools are properly installed ==="
dpkg -l | grep -E "(zfs|spl)"

EOF
}

function configure_ssh {
    echo "======= Setting up OpenSSH =========="
    mkdir -p "$TARGET/root/.ssh/"
    cp /root/.ssh/authorized_keys "$TARGET/root/.ssh/authorized_keys"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' "$TARGET/etc/ssh/sshd_config"
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' "$TARGET/etc/ssh/sshd_config"

    chroot "$TARGET" /bin/bash <<'EOF'
rm /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server -f noninteractive
EOF
}

function set_root_credentials {
    echo "======= Setting root password =========="
    # Feed chpasswd via stdin to avoid shell escaping issues.
    printf '%s\n' "root:${ROOT_PASSWORD}" | chroot "$TARGET" chpasswd

    echo "============ Setting up root prompt ============"
    cat > "$TARGET/root/.bashrc" <<CONF
export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
umask 022
export LS_OPTIONS='--color=auto -h'
eval "\$(dircolors)"
CONF
}

# ---- Bootloader Functions ----
function setup_efi_boot {
    echo "======= Setting up EFI boot =========="

    local tmp_efi
    tmp_efi="$(mktemp)"
    echo "Downloading ZFSBootMenu EFI binary from: $ZBM_EFI_URL"
    curl -L "$ZBM_EFI_URL" -o "$tmp_efi"

    for boot_part in "${BOOT_PARTS[@]}"; do
        mkdir -p "$MAIN_BOOT"
        mount "$boot_part" "$MAIN_BOOT"
        mkdir -p "$MAIN_BOOT/EFI/Boot"
        cp "$tmp_efi" "$MAIN_BOOT/EFI/Boot/bootx64.efi"
        sync
        umount "$MAIN_BOOT" || true
    done

    rm -f "$tmp_efi"
}

function setup_bios_boot {
    echo "======= Setting up BIOS boot =========="

    # Install extlinux in rescue system if needed
    if ! command -v extlinux &> /dev/null; then
        echo "Installing extlinux in rescue system..."
        apt update
        apt install -y extlinux
    fi

    # Download and unpack ZFSBootMenu for BIOS once.
    local TEMP_ZBM
    TEMP_ZBM="$(mktemp -d)"
    echo "Downloading ZFSBootMenu for BIOS from: $ZBM_BIOS_URL"
    curl -L "$ZBM_BIOS_URL" -o "$TEMP_ZBM/zbm.tar.gz"
    tar -xz -C "$TEMP_ZBM" -f "$TEMP_ZBM/zbm.tar.gz" --strip-components=1

    for idx in "${!BOOT_PARTS[@]}"; do
        local boot_part="${BOOT_PARTS[$idx]}"
        local disk="${INSTALL_DISKS[$idx]}"

        echo "Installing BIOS boot to: $disk ($boot_part)"

        mkdir -p "$MAIN_BOOT"
        mount "$boot_part" "$MAIN_BOOT"

        extlinux --install "$MAIN_BOOT"

        cat > "$MAIN_BOOT/extlinux.conf" << 'EOF'
DEFAULT zfsbootmenu
PROMPT 0
TIMEOUT 0

LABEL zfsbootmenu
    LINUX /zfsbootmenu/vmlinuz-bootmenu
    INITRD /zfsbootmenu/initramfs-bootmenu.img
    APPEND ro quiet
EOF

        mkdir -p "$MAIN_BOOT/zfsbootmenu"
        cp "$TEMP_ZBM"/vmlinuz* "$MAIN_BOOT/zfsbootmenu/"
        cp "$TEMP_ZBM"/initramfs* "$MAIN_BOOT/zfsbootmenu/"
        sync

        echo "ZFSBootMenu files on $boot_part:"
        ls -la "$MAIN_BOOT/zfsbootmenu/" || true

        umount "$MAIN_BOOT" || true

        dd bs=440 conv=notrunc count=1 if="/usr/lib/EXTLINUX/gptmbr.bin" of="$disk"
        parted "$disk" set 1 boot on
    done

    rm -rf "$TEMP_ZBM"

    echo "BIOS boot setup complete (all selected disks)"
}

function configure_bootloader {
    echo "======= Setting up boot based on firmware type =========="
    if [ "$EFI_MODE" = true ]; then
        setup_efi_boot
    else
        setup_bios_boot
    fi

    echo "======= Configuring ZFSBootMenu for auto-detection =========="
    # Ensure ZBM auto-boots without requiring KVM interaction.
    zfs set org.zfsbootmenu:commandline="ro quiet zbm.timeout=5" "$ZFS_POOL/ROOT/debian"

    echo "Boot configuration:"
    zfs get org.zfsbootmenu:commandline "$ZFS_POOL/ROOT/debian"
}

# ---- System Services Functions ----
function configure_system_services {
    echo "======= Configuring ZFS cachefile in chrooted system =========="
    mkdir -p "$TARGET/etc/zfs"
    cp /etc/zfs/zpool.cache "$TARGET/etc/zfs/zpool.cache"

    echo "Cachefile status:"
    zpool get cachefile "$ZFS_POOL"
    ls -la "$TARGET/etc/zfs/zpool.cache" && echo "✓ Cachefile ready" || echo "✗ Cachefile failed"

    echo "======= Enabling essential system services =========="
    chroot "$TARGET" /bin/bash <<'EOF'
	set -euo pipefail

	# Avoid conflicts: Debian base often enables ifupdown's networking.service.
	systemctl disable networking.service || true
	systemctl mask networking.service || true
	systemctl disable ifupdown-wait-online.service || true
	systemctl mask ifupdown-wait-online.service || true
	
	systemctl enable systemd-resolved
	systemctl enable systemd-timesyncd
	systemctl enable systemd-networkd

systemctl enable zfs-import-cache
systemctl enable zfs-mount

systemctl enable ssh
systemctl enable apt-daily.timer

echo "Enabled services:"
systemctl list-unit-files | grep enabled
EOF
}

function configure_networking {
    echo "======= Configuring networking =========="
    
    # Create systemd-networkd configuration. Dedicated servers are typically static; we match by MAC.
    mkdir -p "$TARGET/etc/systemd/network"
    
    if [[ "$NETWORK_MODE" == "static" && -n "$NET_MAC" && -n "$NET_IPV4_CIDR" && -n "$NET_GW4" ]]; then
        local dns_line=""
        if [[ ${#NET_DNS_SERVERS[@]} -gt 0 ]]; then
            dns_line="DNS=$(printf '%s ' "${NET_DNS_SERVERS[@]}" | sed 's/[[:space:]]*$//')"
        fi

        {
            echo "[Match]"
            echo "MACAddress=$NET_MAC"
            echo ""
            echo "[Network]"
            echo "Address=$NET_IPV4_CIDR"
            echo "$dns_line"
            echo "IPv6AcceptRA=yes"
            if [[ -n "$NET_IPV6_CIDR" ]]; then
                echo "Address=$NET_IPV6_CIDR"
            fi
            echo ""
            echo "[Route]"
            echo "Destination=0.0.0.0/0"
            echo "Gateway=$NET_GW4"
            echo "GatewayOnLink=yes"
            if [[ -n "$NET_GW6" ]]; then
                echo ""
                echo "[Route]"
                echo "Destination=::/0"
                echo "Gateway=$NET_GW6"
                echo "GatewayOnLink=yes"
            fi
        } > "$TARGET/etc/systemd/network/10-hetzner.network"
    else
        cat > "$TARGET/etc/systemd/network/10-hetzner.network" <<'EOF'
[Match]
Name=ens* enp* eth*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes
IPv6AcceptRA=yes

[DHCP]
RouteMetric=100
UseDNS=yes
UseDomains=yes

[DHCPv4]
RouteMetric=100
UseDNS=yes
UseDomains=yes

[IPv6AcceptRA]
RouteMetric=100
EOF
    fi
    
    echo "systemd-networkd configuration:"
    cat "$TARGET/etc/systemd/network/10-hetzner.network"
    echo ""
}

# ---- Cleanup and Finalization Functions ----
function unmount_all_datasets_and_partitions {
    echo "======= Unmounting all datasets =========="
    
    # First, unmount virtual filesystems that might be using the datasets
    echo "Unmounting virtual filesystems..."
    for dir in dev/pts dev tmp run/lock run/shm run sys proc; do
        if mountpoint -q "$TARGET/$dir"; then
            echo "Unmounting $TARGET/$dir"
            umount "$TARGET/$dir" 2>/dev/null || true
        fi
    done
    
    # Give it a moment
    sleep 2
    
    # Try to unmount boot partition first
    if mountpoint -q "$MAIN_BOOT"; then
        echo "Unmounting boot partition from $MAIN_BOOT"
        umount "$MAIN_BOOT" 2>/dev/null || true
    fi
    
    # Unmount ZFS datasets
    echo "Unmounting ZFS datasets..."
    zfs umount -a 2>/dev/null || true
    
    # Wait for unmounts to complete
    sleep 2
    
    # If root dataset is still mounted, try lazy unmount
    if mountpoint -q "$TARGET"; then
        echo "Attempting lazy unmount of $TARGET"
        umount -l "$TARGET" 2>/dev/null || true
    fi
    
    # Force unmount any stubborn ZFS datasets
    if zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -q "yes"; then
        echo "Forcing unmount of remaining ZFS datasets..."
        zfs umount -a -f 2>/dev/null || true
    fi
    
    # Final verification and force unmount if still mounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted! Attempting final cleanup..."
        # Use fuser to find what's using the mount
        if command -v fuser &> /dev/null; then
            fuser -mv "$TARGET" 2>/dev/null || true
        fi
        # Force lazy unmount as last resort
        umount -l "$TARGET" 2>/dev/null || true
    fi
    
    # Final ZFS unmount check
    local mounted_count=0
    mounted_count=$(zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -c "yes" || true)
    
    if [ "$mounted_count" -gt 0 ]; then
        echo "WARNING: $mounted_count dataset(s) still mounted:"
        zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep "yes" || true
    else
        echo "✓ All ZFS datasets successfully unmounted"
    fi
    
    # Verify $TARGET is unmounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted but continuing..."
    else
        echo "✓ $TARGET successfully unmounted"
    fi
    
    # Verify $MAIN_BOOT is unmounted
    if mountpoint -q "$MAIN_BOOT"; then
        echo "WARNING: $MAIN_BOOT is still mounted!"
    else
        echo "✓ $MAIN_BOOT successfully unmounted"
    fi
}

function unmount_chroot_environment {
    echo "======= Unmounting virtual filesystems =========="
    # Unmount virtual filesystems first
    for dir in dev/pts dev tmp run sys proc; do
        if mountpoint -q "$TARGET/$dir"; then
            echo "Unmounting $TARGET/$dir"
            umount "$TARGET/$dir" 2>/dev/null || true
        fi
    done
}

function export_zfs_pool {
    echo "======= Exporting ZFS pool =========="
    # Export the pool to ensure clean state
    zpool export "$ZFS_POOL"
    echo "✓ ZFS pool '$ZFS_POOL' exported successfully"
}

function show_final_instructions {
    echo ""
    echo "=========================================="
    echo "  INSTALLATION COMPLETE! "
    echo "=========================================="
    echo ""
    echo "System Information:"
    echo "  Hostname: $SYSTEM_HOSTNAME"
    echo "  ZFS Pool: $ZFS_POOL"
    echo "  Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")"
    echo "  Debian Version: $DEBIAN_CODENAME"
    echo "  Networking: systemd-networkd + systemd-resolved"
    echo ""
    echo "=========================================="
    echo "Rebooting..."
}

# ---- Main Installation Flow ----
function main {
    echo "Starting ZFS Debian 13 installation on Hetzner..."
    
    # Get user input first
    get_user_input
    
    # System detection
    detect_efi
    select_install_disks
    
    # Show summary and get confirmation
    show_summary_and_confirm
    
    # Rescue system preparation
    remove_unused_kernels
    install_zfs_on_rescue_system
    stop_mdraid_and_lvm
    
    # Disk partitioning
    partition_disk
    
    # ZFS setup
    create_zfs_pool
    
    # System installation
    bootstrap_debian_system
    setup_chroot_environment
    configure_basic_system
    install_system_packages
    
    verify_initramfs
    configure_ssh
    set_root_credentials
    
    # System configuration
    configure_system_services
    configure_networking
    
    # Bootloader configuration
    configure_bootloader
    
    # Finalization
    unmount_chroot_environment
   
    unmount_all_datasets_and_partitions
    set_final_mountpoints
    export_zfs_pool
    
    # Completion
    show_final_instructions
    
    reboot
}

# Run main function
main
