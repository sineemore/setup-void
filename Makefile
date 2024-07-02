all: format lint

format:
	shfmt -w -i 4 -sr setup-void.sh

lint:
	shellcheck -x setup-void.sh
	checkbashisms -f setup-void.sh

losetup:
	test -f drive.img || fallocate -l 4G drive.img
	losetup /dev/loop0 drive.img

qemu:
	qemu-system-x86_64 \
		-enable-kvm \
		-bios /usr/share/edk2/x64/OVMF.fd \
		-m 4G \
		-device VGA,vgamem_mb=64,xres=1920,yres=1080 \
		-net nic \
		-net user,hostfwd=tcp::2222-:22 \
		-drive file=drive.img
