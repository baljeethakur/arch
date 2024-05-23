#!/bin/bash

# Function to display available disks and partitions
function list_disks {
  lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
}

# Function to select a disk
function select_disk {
  list_disks
  read -p "Enter the disk (e.g., sda): " disk
  echo "/dev/$disk"
}

# Prompt for username and hostname
read -p "Enter your username: " username
read -p "Enter your hostname: " hostname

# List and select the hard drive
echo "Available disks:"
disk=$(select_disk)
echo "You have selected $disk"

# Get partition sizes
read -p "Enter the size for the root partition (e.g., 50G): " root_size
read -p "Enter the size for the swap partition (e.g., 8G): " swap_size

# Partition the disk using parted
parted $disk --script mklabel gpt
parted $disk --script mkpart primary ext4 1MiB ${root_size}
parted $disk --script mkpart primary linux-swap ${root_size} $((${root_size%G} + ${swap_size%G}))GiB
parted $disk --script mkpart primary ext4 $((${root_size%G} + ${swap_size%G}))GiB 100%

# Assign partitions to variables
root_partition="${disk}1"
swap_partition="${disk}2"
home_partition="${disk}3"
efi_partition=$(lsblk -o NAME,MOUNTPOINT | grep -w "/boot/efi" | awk '{print $1}')

# Format the partitions
mkfs.ext4 $root_partition
mkswap $swap_partition
swapon $swap_partition
mkfs.ext4 $home_partition

# Mount the partitions
mount $root_partition /mnt
mkdir /mnt/home
mount $home_partition /mnt/home

# Mount the EFI partition
mkdir -p /mnt/boot/efi
mount /dev/$efi_partition /mnt/boot/efi

# Install base system and required packages
pacstrap /mnt base base-devel linux linux-firmware vim nano git networkmanager

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the installed system
arch-chroot /mnt

# Set the timezone
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc

# Generate locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname
echo $hostname > /etc/hostname

# Configure hosts file
cat <<EOT >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
EOT

# Set root password
echo "Set root password"
passwd

# Create user
useradd -m $username
echo "Set password for $username"
passwd $username
usermod -aG wheel,audio,video,optical,storage $username

# Install and configure sudo
pacman -S sudo
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Install systemd-boot
bootctl --path=/boot install

# Create loader.conf
cat <<EOT >> /boot/loader/loader.conf
default arch
timeout 5
editor 0
EOT

# Create arch.conf for systemd-boot
cat <<EOT >> /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=${root_partition} rw
EOT

# Add Windows entry to systemd-boot
cat <<EOT >> /boot/loader/entries/windows.conf
title   Windows 11
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOT

# Enable NetworkManager
systemctl enable NetworkManager

# Install GNOME and basic applications
pacman -S gnome gnome-extra gdm
systemctl enable gdm

# Install additional applications
pacman -S yay git cut neofetch screenfetch bluez bluez-utils

# Enable Bluetooth
systemctl enable bluetooth

# Install Wine for running Windows applications
pacman -S wine wine-mono wine-gecko winetricks

# Configure Wine (optional, can be customized further)
su - $username -c "winecfg"

# Exit chroot and unmount partitions
exit
umount -R /mnt
swapoff $swap_partition

# Reboot
echo "Installation complete. Rebooting now."
reboot
