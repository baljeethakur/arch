#!/bin/bash

# Exit on error
set -e

# Function to prompt for input
prompt_input() {
    local prompt="$1"
    local input_variable
    read -rp "$prompt" input_variable
    echo "$input_variable"
}

# Ask for user input
DISK=$(prompt_input "Enter the target disk (e.g., /dev/sda): ")
ROOT_SIZE=$(prompt_input "Enter the size of the root partition (e.g., 20G): ")
HOME_SIZE=$(prompt_input "Enter the size of the home partition (e.g., 50G or leave empty for remaining space): ")
HOSTNAME=$(prompt_input "Enter the hostname: ")
USERNAME=$(prompt_input "Enter the username: ")
ROOT_PASSWORD=$(prompt_input "Enter the root password: ")
USER_PASSWORD=$(prompt_input "Enter the password for $USERNAME: ")

# Update the system clock
timedatectl set-ntp true

# Partition the disk
parted $DISK --script mklabel gpt
parted $DISK --script mkpart primary fat32 1MiB 261MiB
parted $DISK --script set 1 esp on
parted $DISK --script mkpart primary ext4 261MiB "$((261 + ROOT_SIZE))MiB"

if [ -n "$HOME_SIZE" ]; then
    parted $DISK --script mkpart primary ext4 "$((261 + ROOT_SIZE))MiB" "$((261 + ROOT_SIZE + HOME_SIZE))MiB"
else
    parted $DISK --script mkpart primary ext4 "$((261 + ROOT_SIZE))MiB" 100%
fi

# Format the partitions
mkfs.fat -F32 ${DISK}1
mkfs.ext4 ${DISK}2
if [ -n "$HOME_SIZE" ]; then
    mkfs.ext4 ${DISK}3
fi

# Mount the partitions
mount ${DISK}2 /mnt
mkdir /mnt/boot
mount ${DISK}1 /mnt/boot
if [ -n "$HOME_SIZE" ]; then
    mkdir /mnt/home
    mount ${DISK}3 /mnt/home
fi

# Install the base system
pacstrap /mnt base linux linux-firmware

# Generate the fstab file
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt /bin/bash <<EOF

# Set the time zone
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc

# Localization
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Network configuration
echo $HOSTNAME > /etc/hostname
cat <<EOT >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOT

# Set the root password
echo "root:$ROOT_PASSWORD" | chpasswd

# Install necessary packages
pacman -Sy --noconfirm gnome gnome-extra sddm networkmanager base-devel git wine

# Enable services
systemctl enable sddm
systemctl enable NetworkManager

# Create a user
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Install and configure the bootloader
bootctl install
cat <<EOT > /boot/loader/loader.conf
default arch
timeout 5
console-mode max
editor no
EOT

cat <<EOT > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value ${DISK}2) rw
EOT

# Add Windows boot entry
WINDOWS_PARTUUID=$(blkid -s PARTUUID -o value ${DISK}1)
cat <<EOT > /boot/loader/entries/windows.conf
title   Windows
efi     /EFI/Microsoft/Boot/bootmgfw.efi
options root=PARTUUID=$WINDOWS_PARTUUID rw
EOT

# Install yay
su - $USERNAME -c "git clone https://aur.archlinux.org/yay.git"
su - $USERNAME -c "cd yay && makepkg -si --noconfirm"

# Install Microsoft Edge
su - $USERNAME -c "yay -S --noconfirm microsoft-edge-stable-bin"

EOF

# Unmount and reboot
umount -R /mnt
reboot
