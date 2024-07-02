setup-void.sh
=============

Setup Void Linux with LUKS encryption and EFI boot.

### Sample configuration
```sh
LUKS_PASSPHRASE=
BLOCK_DEVICE=/dev/loop0
MOUNTPOINT=./mnt
LVM_VG=lemp10
VOID_HOSTNAME=lemp10
VOID_PACKAGES="
base-system
base-devel
lvm2
cryptsetup
gummiboot
st-terminfo
"
```