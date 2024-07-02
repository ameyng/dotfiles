#!/bin/bash

# Root check.
if [[ 0 -ne ${UID} ]]; then
    echo "This script needs to be run as root!" >&2
    exit 3
fi

#################
# Configuration #
#################
sInstallDisk=''
sRootMount='/mnt'
sLocale='en_US.UTF-8'
sKeymap='us'
sTimezone='Asia/Kolkata'
iActiveCPUs=$(lscpu --extended | grep 'yes' | wc -l)

# Root partition/filesystem labelling.
sBaseLabelRoot='ROOT'
sPartitionLabelRoot="P-${sBaseLabelRoot}"
sLUKS2FilesystemLabelRoot="F-LUKS2-${sBaseLabelRoot}"
sBTRFSFilesystemLabelRoot="F-BTRFS-${sBaseLabelRoot}"

# EFI partition/filesystem labelling.
sBaseLabelEFI='EFI'
sPartitionLabelEFI="P-${sBaseLabelEFI}"
sFilesystemLabelEFI="F-${sBaseLabelEFI}"

# Mount options
sBTRFSMountOptions='defaults,noatime,nodiratime,space_cache=v2,compress-force=zstd:3,discard=async,autodefrag,ssd,commit=120,x-systemd.device-timeout=0'
sEFIMountOptions="rw,noatime,nodiratime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro"

aBTRFSSubvolumes=(
	'@'
	'@snapshots'
	'@log'
	'@libvirt'
	'@portables'
	'@machines'
	'@docker'
	'@postgres'
	'@spool'
	'@www'
	'@tmp'
	'@opt'
	'@crash'
	'@cache'
	'@srv'
	'@home'
)

aBTRFSSubvolumeMounts=(
	'.snapshots'
	'var/log'
	'var/lib/libvirt/images'
	'var/lib/portables'
	'var/lib/machines'
	'var/lib/docker'
	'var/lib/postgres'
	'var/spool'
	'var/www'
	'var/tmp'
	'opt'
	'var/crash'
	'var/cache'
	'srv'
	'home'
)

aPacstrapPackages=(
	'base'
	'base-devel'
	'linux'
	'linux-firmware'
	'intel-ucode'
	'vim'
	'cryptsetup'
	'util-linux'
	'e2fsprogs'
	'dosfstools'
	'btrfs-progs'
	'sudo'
	'openssh'
	'networkmanager'
	'man-db'
	'iwd'
	'snapper'
	'snap-pac'
)

aPostChrootPackages=(
	'grub'
	'efibootmgr'
	'grub-btrfs'
)

aPostInstallPackages=(
	'whois'
	'neovim'
	'glances'
	'pkgfile'
	'reflector'
	'iwd'
	'htop'
	'bash-completion'
	'git'
	'pacman-contrib'
	'mlocate'
)

if [[ 0 -eq $(mountpoint -q "${sRootMount}"; echo $?) ]]; then
	umount -vR "${sRootMount}"
fi

if [[ -b "/dev/mapper/${sBaseLabelRoot}" ]]; then
	cryptsetup close "/dev/mapper/${sBaseLabelRoot}"
fi

wipefs --all --force "${sInstallDisk}"
sgdisk --zap-all --clear "${sInstallDisk}"

sgdisk -n 0:0:+1024M -t 0:EF00 -c 0:"${sPartitionLabelEFI}" "${sInstallDisk}"
sgdisk -n 0:0:0 -t 0:8304 -c 0:"${sPartitionLabelRoot}" "${sInstallDisk}"

# Reload partition table
sleep 2
partprobe -s "${sInstallDisk}"
sleep 2

#Encrypt the root partition, prompt for a sPassword.
cryptsetup luksFormat --type luks2 --label "${sLUKS2FilesystemLabelRoot}" --pbkdf pbkdf2 --pbkdf-force-iterations 500000 "/dev/disk/by-partlabel/${sPartitionLabelRoot}"
cryptsetup luksOpen "/dev/disk/by-partlabel/${sPartitionLabelRoot}" "${sBaseLabelRoot}"

# Generate a keyfile, this will be used to skip entering the password twice.
dd bs=512 count=8 if=/dev/random of=/crypto_keyfile.bin iflag=fullblock

# Add the generated key to the LUKS2 partition i.e. allow it to unlock the partition.
cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 500000 "/dev/disk/by-partlabel/${sPartitionLabelRoot}" '/crypto_keyfile.bin'

mkfs.vfat -F 32 -n "${sFilesystemLabelEFI}" "/dev/disk/by-partlabel/${sPartitionLabelEFI}"

mkfs.btrfs --force -L "${sBTRFSFilesystemLabelRoot}" "/dev/mapper/${sBaseLabelRoot}"

mount -v -t btrfs -o "${sBTRFSMountOptions}" "/dev/mapper/${sBaseLabelRoot}" "${sRootMount}"

for i in "${!aBTRFSSubvolumes[@]}"
do
	btrfs subvolume create "${sRootMount}/${aBTRFSSubvolumes[i]}"
done

umount -vR "${sRootMount}"

mount -v -t btrfs -o "${sBTRFSMountOptions},subvol=@" "/dev/mapper/${sBaseLabelRoot}" "${sRootMount}"

for i in "${!aBTRFSSubvolumeMounts[@]}"
do
	mkdir -vp "${sRootMount}/${aBTRFSSubvolumeMounts[i]}"
	mount -v -t btrfs -o "${sBTRFSMountOptions},subvol=${aBTRFSSubvolumes[i+1]}" "/dev/mapper/${sBaseLabelRoot}" "${sRootMount}/${aBTRFSSubvolumeMounts[i]}"
done

chmod -c 1777 "${sRootMount}/var/tmp"
chmod -c 0700 "${sRootMount}/var/lib/machines"
chmod -c 0700 "${sRootMount}/var/lib/portables"
chattr -VR +C "${sRootMount}/var/lib/libvirt/images"


mkdir -vp "${sRootMount}/efi"

mount -v -t vfat -o "${sEFIMountOptions}" "/dev/disk/by-partlabel/${sPartitionLabelEFI}" "${sRootMount}/efi"

sLUKS2FilesystemUUIDRoot="$(blkid -s UUID -o value /dev/disk/by-partlabel/${sPartitionLabelRoot})"

pacman -Syy

reflector --age 24 --protocol https --country 'India, ' --ipv4 --sort rate --save '/etc/pacman.d/mirrorlist' --threads "${iActiveCPUs}"

sed \
	-e "s|^#Color$|Color|g" \
	-e "s|^#ParallelDownloads.*$|ParallelDownloads = ${iActiveCPUs}|g" \
	-i '/etc/pacman.conf'

pacstrap -K "${sRootMount}" "${aPacstrapPackages[@]}"

cp -brvf /etc/pacman.conf "${sRootMount}/etc/pacman.conf"
cp -brvf /etc/pacman.d/mirrorlist "${sRootMount}/etc/pacman.d/mirrorlist"

sed -i -e "/^#"${sLocale}"/s/^#//" "${sRootMount}/etc/locale.gen"

for file in 'machine-id' 'localtime' 'hostname' 'shadow' 'locale.conf'; do
	if [[ -f "${sRootMount}/etc/${file}" ]]; then
		rm -v "${sRootMount}/etc/${file}"
	fi
done

systemd-firstboot --root "${sRootMount}" \
	--keymap="${sKeymap}" --locale="${sLocale}" \
	--locale-messages="${sLocale}" --timezone="${sTimezone}" \
	--hostname="${sHostname}" --setup-machine-id \
	--welcome=false

# Copy the earlier generated keyfile to the new environment root.
cp -brvf '/crypto_keyfile.bin' "${sRootMount}/crypto_keyfile.bin"

#########################
# Snapper configuration #
#########################
# Check the link below for more information on the below steps.
# https://wiki.archlinux.org/title/Snapper#Creating_a_new_configuration

# Unmount the existing @snapshots subvolume from /.snapshots.
arch-chroot "${sRootMount}" umount -v /.snapshots

# Delete the mountpoint /.snapshots.
arch-chroot "${sRootMount}" rm -vrf /.snapshots

# Create the snapper configuration.
arch-chroot "${sRootMount}" snapper -c root create-config /

# Delete the BTRFS subvolume created by snapper.
arch-chroot "${sRootMount}" btrfs subvolume delete /.snapshots

# Re-create the mountpoint /.snapshots.
arch-chroot "${sRootMount}" mkdir -vp /.snapshots

# Edit the snapper configuration.
arch-chroot "${sRootMount}" sed \
	-e "s|^TIMELINE_MIN_AGE=.*$|TIMELINE_MIN_AGE=\"1800\"|g" \
	-e "s|^TIMELINE_LIMIT_HOURLY=.*$|TIMELINE_LIMIT_HOURLY=\"5\"|g" \
	-e "s|^TIMELINE_LIMIT_DAILY=.*$|TIMELINE_LIMIT_DAILY=\"7\"|g" \
	-e "s|^TIMELINE_LIMIT_WEEKLY=.*$|TIMELINE_LIMIT_WEEKLY=\"0\"|g" \
	-e "s|^TIMELINE_LIMIT_MONTHLY=.*$|TIMELINE_LIMIT_MONTHLY=\"0\"|g" \
	-e "s|^TIMELINE_LIMIT_YEARLY=.*$|TIMELINE_LIMIT_YEARLY=\"0\"|g" \
	"/etc/snapper/configs/root"

# Set ownership and permissions on the keyfile.
arch-chroot "${sRootMount}" chown root:root '/crypto_keyfile.bin'
arch-chroot "${sRootMount}" chmod 600 '/crypto_keyfile.bin'

arch-chroot "${sRootMount}" locale-gen

genfstab -U -p "${sRootMount}" >> "${sRootMount}/etc/fstab"

arch-chroot "${sRootMount}" useradd -G wheel -m -p "${sPassword}" "${sUsername}"

sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' "${sRootMount}/etc/sudoers"

arch-chroot "${sRootMount}" mv "/etc/mkinitcpio.conf" "/etc/mkinitcpio.conf.backup"

echo 'MODULES=(btrfs)' > "${sRootMount}/etc/mkinitcpio.conf"
echo 'FILES=(/crypto_keyfile.bin)' >> "${sRootMount}/etc/mkinitcpio.conf"
echo 'HOOKS=(base udev keyboard autodetect keymap consolefont modconf block encrypt filesystems fsck grub-btrfs-overlayfs)' >> "${sRootMount}/etc/mkinitcpio.conf"
echo 'COMPRESSION="cat"' >> "${sRootMount}/etc/mkinitcpio.conf"
echo 'MODULES_DECOMPRESS="yes"' >> "${sRootMount}/etc/mkinitcpio.conf"

arch-chroot "${sRootMount}" pacman -S --noconfirm "${aPostChrootPackages[@]}"
	
# echo "Setting mkinitcpio to generate UKIs instead of initramfs + kernel.."
# sed -i \
#     -e '/^#ALL_config/s/^#//' \
#     -e '/^#default_uki/s/^#//' \
#     -e '/^#default_options/s/^#//' \
#     -e 's/default_image=/#default_image=/g' \
#     -e "s/PRESETS=('default' 'fallback')/PRESETS=('default')/g" \
#     "${sRootMount}/etc/mkinitcpio.d/linux.preset"

# echo "Creating a directory structure for generation of UKIs.."
# declare $(grep default_uki "${sRootMount}/etc/mkinitcpio.d/linux.preset")
# arch-chroot "${sRootMount}" mkdir -v -p "$(dirname "${default_uki//\"}")"

arch-chroot "${sRootMount}" mkinitcpio -p linux

arch-chroot "${sRootMount}" sed -e "s|^#GRUB_ENABLE_CRYPTODISK.*$|GRUB_ENABLE_CRYPTODISK=y|g" -i '/etc/default/grub'

arch-chroot "${sRootMount}" sed -e "s|^GRUB_TIMEOUT.*$|GRUB_TIMEOUT=30|g" -i '/etc/default/grub'

arch-chroot "${sRootMount}" sed -e "s|^GRUB_PRELOAD_MODULES.*$|GRUB_PRELOAD_MODULES=\"part_gpt part_msdos bli\"|g" -i '/etc/default/grub'

sBootloaderKernelCmdline="cryptdevice=UUID=${sLUKS2FilesystemUUIDRoot}:${sBaseLabelRoot}:allow-discards rw loglevel=4 splash nmi_watchdog=0 quiet"

arch-chroot "${sRootMount}" sed -e "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*$|GRUB_CMDLINE_LINUX_DEFAULT=\"${sBootloaderKernelCmdline}\"|g" -i '/etc/default/grub'

arch-chroot "${sRootMount}" grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB

arch-chroot "${sRootMount}" grub-mkconfig -o /efi/grub/grub.cfg

systemctl --root "${sRootMount}" enable systemd-resolved systemd-timesyncd NetworkManager sshd grub-btrfsd snapper-timeline.timer snapper-cleanup.timer

systemctl --root "${sRootMount}" mask systemd-networkd
