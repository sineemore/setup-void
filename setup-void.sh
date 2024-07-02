#!/bin/sh
#
# setup-void.sh - setup void linux with luks and efi

set -eu

die() {
    [ $# -eq 0 ] || printf '%s\n' "$1" >&2
    exit 1
}

command_exists() {
    while [ $# -gt 0 ]; do
        if ! command -v "$1" > /dev/null 2>&1; then
            die "command not found: $1"
        fi
        shift
    done
}

ask_luks_passphrase() {
    if [ -z "${LUKS_PASSPHRASE+set}" ] || [ -z "$LUKS_PASSPHRASE" ]; then
        trap 'stty echo' EXIT
        stty -echo

        printf 'Enter LUKS passphrase: ' >&2
        read -r LUKS_PASSPHRASE
        printf '\n' >&2
    fi
}

validate() {
    command_exists \
        xbps-install \
        cryptsetup \
        lsblk \
        parted \
        rsync \
        lvcreate \
        vgcreate \
        vgchange \
        xchroot \
        ;

    if [ -z "${BLOCK_DEVICE+set}" ]; then
        die "BLOCK_DEVICE not set"
    fi

    if ! [ -b "$BLOCK_DEVICE" ]; then
        die "block device not found: $BLOCK_DEVICE"
    fi

    if [ -z "${MOUNTPOINT+set}" ]; then
        die "MOUNTPOINT not set"
    fi

    if ! [ -d "$MOUNTPOINT" ]; then
        die "mountpoint not found: $MOUNTPOINT"
    fi

    if [ -z "${LVM_VG+set}" ]; then
        die "LVM_VG not set"
    fi

    if [ -z "${VOID_PACKAGES+set}" ]; then
        die "VOID_PACKAGES not set"
    fi

    if [ -z "${VOID_HOSTNAME+set}" ]; then
        die "VOID_HOSTNAME not set"
    fi
}

mountall() {
    scan_partitions
    ask_luks_passphrase

    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open -d- "$PART_2" cryptroot
    vgchange -ay "$LVM_VG"
    mount "/dev/${LVM_VG}/root" "$MOUNTPOINT"
    mount "$PART_1" "${MOUNTPOINT}/boot"
}

unmountall_ignore_errors() {
    umount -qR "$MOUNTPOINT" || true
    if [ -b "/dev/lemp10/root" ]; then
        vgchange -q -an "$LVM_VG" > /dev/null
    fi
    if [ -b "/dev/mapper/cryptroot" ]; then
        cryptsetup close cryptroot > /dev/null
    fi
}

scan_partitions() {
    PART_1=$(lsblk -pPo PATH,TYPE,PARTN "$BLOCK_DEVICE" | grep -F 'TYPE="part" PARTN="1"' | cut -d'"' -f2)
    PART_2=$(lsblk -pPo PATH,TYPE,PARTN "$BLOCK_DEVICE" | grep -F 'TYPE="part" PARTN="2"' | cut -d'"' -f2)
    if ! [ -b "$PART_1" ] || ! [ -b "$PART_2" ]; then
        die "partitions not found"
    fi
}

make_partitions() {
    parted -s "$BLOCK_DEVICE" \
        mklabel gpt \
        mkpart primary fat32 2048s 2GiB \
        mkpart primary ext4 2GiB 100% \
        set 1 esp on \
        set 2 lvm on
    scan_partitions
}

setup_root() {
    ask_luks_passphrase
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat -q -d- --type luks2 "$PART_2"
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open -d- "$PART_2" cryptroot
    vgcreate "$LVM_VG" /dev/mapper/cryptroot
    lvcreate --name root -l 100%FREE "$LVM_VG"
    mkfs.ext4 "/dev/${LVM_VG}/root"
    mount "/dev/${LVM_VG}/root" "$MOUNTPOINT"
}

setup_boot() {
    mkfs.vfat -F32 "$PART_1"
    mkdir -p "${MOUNTPOINT}/boot"
    mount "$PART_1" "${MOUNTPOINT}/boot"
}

install_system() {
    mkdir -p "${MOUNTPOINT}/var/db/xbps/keys"
    rsync -av /var/db/xbps/keys/ "${MOUNTPOINT}/var/db/xbps/keys/"

    # shellcheck disable=SC2086
    xbps-install \
        --yes \
        -S \
        -c /var/cache/xbps \
        -R 'https://repo-default.voidlinux.org/current' \
        -r "$MOUNTPOINT" \
        $VOID_PACKAGES

    cp /etc/wpa_supplicant/wpa_supplicant.conf "${MOUNTPOINT}/etc/wpa_supplicant/wpa_supplicant.conf"

    PART_1_UUID=$(lsblk -dnro UUID "$PART_1")
    PART_2_UUID=$(lsblk -dnro UUID "$PART_2")
    PART_1_PARTUUID=$(lsblk -dnro PARTUUID "$PART_1")
    PART_2_PARTUUID=$(lsblk -dnro PARTUUID "$PART_2")
    if [ -z "$PART_1_UUID" ] || [ -z "$PART_2_UUID" ] || [ -z "$PART_1_PARTUUID" ] || [ -z "$PART_2_PARTUUID" ]; then
        die "could not find partition uuids or partuuids"
    fi

    cp "$SCRIPT_LOCATION" "${MOUNTPOINT}/bootstrap.sh"
    cat << EOF > "${MOUNTPOINT}/bootstrap.conf"
VOID_HOSTNAME="$VOID_HOSTNAME"
LVM_VG="$LVM_VG"
PART_1_UUID="$PART_1_UUID"
PART_2_UUID="$PART_2_UUID"
PART_1_PARTUUID="$PART_1_PARTUUID"
PART_2_PARTUUID="$PART_2_PARTUUID"
EOF
}

start_bootstrap() {
    xchroot "$MOUNTPOINT" /bootstrap.sh
}

# bootstrap runs inside chroot
bootstrap() {
    # shellcheck disable=SC1091
    . bootstrap.conf

    printf \
        'rd.luks.uuid=%s rd.lvm.vg=%s root=/dev/%s/root\n' \
        "$PART_2_UUID" "$LVM_VG" "$LVM_VG" > /boot/loader/void-options.conf

    printf 'add_dracutmodules+=" crypt lvm "\n' > /etc/dracut.conf

    cat << EOF > /etc/fstab
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
PARTUUID=${PART_1_PARTUUID} /boot vfat defaults 0 2
/dev/${LVM_VG}/root / ext4 defaults 0 1
EOF

    printf '%s\n' "$VOID_HOSTNAME" > /etc/hostname

    cat << 'EOF' > /etc/default/libc-locales
en_US.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
EOF

    ln -sf /usr/share/zoneinfo/GMT /etc/localtime

    gummiboot install --no-variables

    chsh -s /bin/bash root
    printf 'root:root\n' | chpasswd -c SHA256

    xbps-reconfigure -fa

    rm "$0" bootstrap.conf
}

main() {
    SCRIPT_LOCATION="$0"

    # If script is called as bootstrap.sh, do bootstrap
    if [ "$(basename "$0")" = "bootstrap.sh" ]; then
        bootstrap "$@"
        exit 0
    fi

    ACTION="$1"
    CONFIG="$2"

    # shellcheck disable=SC1090
    . "$CONFIG"

    case "$ACTION" in
    umountall)
        validate
        unmountall_ignore_errors
        ;;
    mountall)
        validate
        mountall
        ;;
    setup)
        validate
        unmountall_ignore_errors
        make_partitions
        setup_root
        setup_boot
        install_system
        start_bootstrap
        ;;
    *)
        die "invalid action: $ACTION"
        ;;
    esac
}

main "$@"
