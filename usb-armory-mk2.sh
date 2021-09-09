#!/bin/bash -e
# This is the USBArmory MK2 Kali ARM 32 bit build script - http://www.kali.org/get-kali
# A trusted Kali Linux image created by Offensive Security - http://www.offensive-security.com

# shellcheck disable=SC2154
# Load general functions
# shellcheck source=/dev/null
source ./common.d/functions.sh

# Hardware model
hw_model=${hw_model:-"usbarmory-mk2"}
# Architecture
architecture=${architecture:-"armhf"}
# Variant name for image and dir build
variant=${variant:-"${architecture}"}
# Desktop manager (xfce, gnome, i3, kde, lxde, mate, e17 or none)
desktop=${desktop:-"xfce"}

# Load common variables
include variables
# Checks script enviroment
include check
# Packages build list
include packages
# Load automatic proxy configuration
include proxy_apt
# Execute initial debootstrap
debootstrap_exec http://http.kali.org/kali
# Enable eatmydata in compilation
include eatmydata
# debootstrap second stage
systemd-nspawn_exec eatmydata /debootstrap/debootstrap --second-stage
# Define sources.list
include sources.list
# APT options
include apt_options
# So X doesn't complain, we add kali to hosts
include hosts
# Set hostname
set_hostname "${hostname}"
# Network configs
include network
add_interface eth0
# Copy directory bsp into build dir.
cp -rp bsp "${work_dir}"

# Third stage
cat <<EOF >"${work_dir}"/third-stage
#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive
eatmydata apt-get update
eatmydata apt-get -y install ${third_stage_pkgs}

eatmydata apt-get install -y ${packages} || eatmydata apt-get install -y --fix-broken
eatmydata apt-get install -y ${desktop_pkgs} ${extra} || eatmydata apt-get install -y --fix-broken
eatmydata apt-get install -y isc-dhcp-server tightvncserver || eatmydata apt-get install -y --fix-broken
eatmydata apt-get -y --purge autoremove

# Linux console/Keyboard configuration
echo 'console-common console-data/keymap/policy select Select keymap from full list' | debconf-set-selections
echo 'console-common console-data/keymap/full select en-latin1-nodeadkeys' | debconf-set-selections

# Copy all services
cp -p /bsp/services/all/*.service /etc/systemd/system/

# Copy script rpi-resizerootfs
install -m755 /bsp/scripts/rpi-resizerootfs /usr/sbin/

# Enable rpi-resizerootfs first boot
systemctl enable rpi-resizerootfs

# Generate SSH host keys on first run
systemctl enable regenerate_ssh_host_keys

# Allow users to use NM over ssh
install -m644 /bsp/polkit/10-NetworkManager.pkla /var/lib/polkit-1/localauthority/50-local.d

rm /etc/modules
rm /etc/modules-load.d/modules.conf
cat << __EOF__ > /etc/modules-load.d/modules.conf
ledtrig_heartbeat
ci_hdrc_imx
g_ether
#g_mass_storage
#g_multi
__EOF__

cat << __EOF__ > /etc/modprobe.d/usbarmory.conf
options g_ether use_eem=0 dev_addr=1a:55:89:a2:69:41 host_addr=1a:55:89:a2:69:42
# To use either of the following, you should create the file /disk.img via dd
# "dd if=/dev/zero of=/disk.img bs=1M count=2048" would create a 2GB disk.img file.
#options g_mass_storage file=disk.img
#options g_multi use_eem=0 dev_addr=1a:55:89:a2:69:41 host_addr=1a:55:89:a2:69:42 file=disk.img
__EOF__

cat << __EOF__ > /etc/network/interfaces.d/usb0
allow-hotplug usb0
iface usb0 inet static
address 10.0.0.1
netmask 255.255.255.0
gateway 10.0.0.2
__EOF__

# Debian reads the config from inside /etc/dhcp.
cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.old
cat << __EOF__ > /etc/dhcp/dhcpd.conf
# Sample configuration file for ISC dhcpd for Debian
# Original file /etc/dhcp/dhcpd.conf.old

ddns-update-style none;

default-lease-time 600;
max-lease-time 7200;

log-facility local7;

subnet 10.0.0.0 netmask 255.255.255.0 {
  range 10.0.0.2 10.0.0.2;
  default-lease-time 600;
  max-lease-time 7200;
}
__EOF__

# Only listen on usb0
sed -i -e 's/INTERFACES.*/INTERFACES="usb0"/g' /etc/default/isc-dhcp-server

# Enable dhcp server
update-rc.d isc-dhcp-server enable

cd /root
apt download -o APT::Sandbox::User=root ca-certificates 2>/dev/null

# Set a REGDOMAIN.  This needs to be done or wireless doesn't work correctly on the RPi 3B+
sed -i -e 's/REGDOM.*/REGDOMAIN=00/g' /etc/default/crda

# Try and make the console a bit nicer
# Set the terminus font for a bit nicer display.
sed -i -e 's/FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup
sed -i -e 's/FONTSIZE=.*/FONTSIZE="6x12"/' /etc/default/console-setup

# Fix startup time from 5 minutes to 15 secs on raise interface wlan0
sed -i 's/^TimeoutStartSec=5min/TimeoutStartSec=15/g' "/usr/lib/systemd/system/networking.service"

# Enable runonce
install -m755 /bsp/scripts/runonce /usr/sbin/
cp -rf /bsp/runonce.d /etc
systemctl enable runonce

# Clean up dpkg.eatmydata
rm -f /usr/bin/dpkg
dpkg-divert --remove --rename /usr/bin/dpkg
EOF

# Run third stage
chmod 755 "${work_dir}"/third-stage
systemd-nspawn_exec /third-stage

# Choose a locale
set_locale "$locale"
# Clean system
include clean_system
# Define DNS server after last running systemd-nspawn.
echo "nameserver 8.8.8.8" >"${work_dir}"/etc/resolv.conf
# Disable the use of http proxy in case it is enabled.
disable_proxy
# Mirror & suite replacement
restore_mirror
# Reload sources.list
#include sources.list

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.
git clone -b linux-5.4.y --depth 1 git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git ${work_dir}/usr/src/kernel
cd ${work_dir}/usr/src/kernel
git rev-parse HEAD > ${work_dir}/usr/src/kernel-at-commit
touch .scmversion
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/kali-wifi-injection-5.4.patch
patch -p1 --no-backup-if-mismatch < ${current_dir}/patches/0001-wireless-carl9170-Enable-sniffer-mode-promisc-flag-t.patch
wget $githubraw/inversepath/usbarmory/master/software/kernel_conf/mark-two/usbarmory_linux-5.4.config -O .config
wget $githubraw/inversepath/usbarmory/master/software/kernel_conf/mark-two/imx6ul-usbarmory.dts -O arch/arm/boot/dts/imx6ul-usbarmory.dts
wget $githubraw/inversepath/usbarmory/master/software/kernel_conf/mark-two/imx6ull-usbarmory.dts -O arch/arm/boot/dts/imx6ull-usbarmory.dts
wget $githubraw/inversepath/usbarmory/master/software/kernel_conf/mark-two/imx6ulz-usbarmory.dts -O arch/arm/boot/dts/imx6ulz-usbarmory.dts
cp .config ${work_dir}/usr/src/usbarmory_linux-5.4.config
make LOADADDR=0x80000000 -j $(grep -c processor /proc/cpuinfo) uImage modules imx6ul-usbarmory.dtb imx6ull-usbarmory.dtb imx6ulz-usbarmory.dtb
make modules_install INSTALL_MOD_PATH=${work_dir}
cp arch/arm/boot/zImage ${work_dir}/boot/
cp arch/arm/boot/dts/imx6*-usbarmory*.dtb ${work_dir}/boot/
make mrproper
# Since these aren't integrated into the kernel yet, mrproper removes them.
cp ../usbarmory_linux-5.4.config ${work_dir}/usr/src/kernel/.config
wget $githubraw/inversepath/usbarmory/master/software/kernel_conf/mark-two/imx6ul-usbarmory.dts -O arch/arm/boot/dts/imx6ul-usbarmory.dts
wget $githubraw/inversepath/usbarmory/master/software/kernel_conf/mark-two/imx6ull-usbarmory.dts -O arch/arm/boot/dts/imx6ull-usbarmory.dts
wget $githubraw/inversepath/usbarmory/master/software/kernel_conf/mark-two/imx6ulz-usbarmory.dts -O arch/arm/boot/dts/imx6ulz-usbarmory.dts


# Fix up the symlink for building external modules
# kernver is used so we don't need to keep track of what the current compiled
# version is
kernver=$(ls ${work_dir}/lib/modules/)
cd ${work_dir}/lib/modules/${kernver}
rm build
rm source
ln -s /usr/src/kernel build
ln -s /usr/src/kernel source

cd ${current_dir}

# Calculate the space to create the image and create.
make_image

# Create the disk and partition it
parted -s ${current_dir}/${imagename}.img mklabel msdos
parted -s -a minimal ${current_dir}/${imagename}.img mkpart primary ext2 5MiB 100%

# Set the partition variables
loopdevice=$(losetup --show -fP "${current_dir}/${imagename}.img")
rootp="${loopdevice}p1"

# Create file systems
log "Formating partitions" green
mkfs.ext2 ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}"/root
mount ${rootp} "${basedir}"/root

# Create an fstab so that we don't mount / read-only.
UUID=$(blkid -s UUID -o value ${rootp})
echo "UUID=$UUID /               $fstype    errors=remount-ro 0       1" >> ${work_dir}/etc/fstab

log "Rsyncing rootfs into image file" green
rsync -HPavz -q "${work_dir}"/ "${basedir}"/root/
sync

# Unmount partitions
sync

cd "${work_dir}"
wget ftp://ftp.denx.de/pub/u-boot/u-boot-2020.10.tar.bz2
tar xvf u-boot-2020.10.tar.bz2 && cd u-boot-2020.10
make distclean
make usbarmory_config
make ARCH=arm
dd if=u-boot.imx of=${loopdevice} bs=512 seek=2 conv=fsync

cd "${current_dir}"
# Umount filesystem
umount -l "${rootp}"

# Check filesystem
e2fsck -y -f "$rootp"

# Remove loop devices
losetup -d "${loopdevice}"

# Compress image compilation
include compress_img

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone wrong.
clean_build