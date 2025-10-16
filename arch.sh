#!/bin/bash

# Arch Linux + GNOME installation script
# Ryzen 5600H + GTX 1650 with NVIDIA proprietary drivers
# Uses systemd-boot, ext4, minimal setup

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== Arch Linux + GNOME Installation ===${NC}"

# Partition configuration
read -p "Enter EFI partition (e.g., /dev/sda1): " EFI_PART
read -p "Enter root partition (e.g., /dev/sda2): " ROOT_PART
read -p "Enter hostname: " HOSTNAME
read -p "Enter username: " USERNAME
read -s -p "Enter password for $USERNAME: " PASSWORD
echo
read -s -p "Confirm password: " PASSWORD_CONFIRM
echo

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    echo -e "${RED}Passwords do not match!${NC}"
    exit 1
fi

echo -e "${GREEN}Formatting partitions...${NC}"
mkfs.fat -F32 $EFI_PART
mkfs.ext4 -F $ROOT_PART

echo -e "${GREEN}Mounting partitions...${NC}"
mount $ROOT_PART /mnt
mkdir -p /mnt/boot
mount $EFI_PART /mnt/boot

echo -e "${GREEN}Configuring pacman mirrors and parallel downloads...${NC}"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
reflector --country US --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

echo -e "${GREEN}Installing base system...${NC}"
pacstrap /mnt base base-devel linux linux-firmware amd-ucode sudo efibootmgr

echo -e "${GREEN}Generating fstab...${NC}"
genfstab -U /mnt >> /mnt/etc/fstab

echo -e "${GREEN}Configuring system...${NC}"
arch-chroot /mnt bash << CHROOT_EOF
set -e

# Timezone and locale
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Keyboard layout
echo "KEYMAP=br-abnt2" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Create user with sudo access
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo > /dev/null

# Pacman config
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# Install systemd-boot
echo -e "${GREEN}Installing systemd-boot...${NC}"
bootctl install --no-variables
efibootmgr --create --disk $ROOT_PART --part 1 --label "Arch Linux" --loader /EFI/systemd/systemd-bootx64.efi --unicode

# Create systemd-boot entry
mkdir -p /boot/loader/entries
cat > /boot/loader/entries/arch.conf << EOF
title Arch Linux
linux /vmlinuz-linux
initrd /amd-ucode.img
initrd /initramfs-linux.img
options root=$ROOT_PART rw
EOF

# Bootloader config
cat > /boot/loader/loader.conf << 'EOF'
default arch.conf
timeout 3
editor no
EOF

# Install necessary packages
echo -e "${GREEN}Installing packages...${NC}"
pacman -S --noconfirm \
    reflector \
    gnome \
    networkmanager \
    nvidia nvidia-utils nvidia-settings \
    xorg-xwayland \
    git neovim nano

# Configure mirrors with reflector for the system
echo -e "${GREEN}Configuring mirrors with reflector...${NC}"
reflector --country US --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

# Remove kms from HOOKS (not needed with NVIDIA)
sed -i 's/\bkms\b //' /etc/mkinitcpio.conf

# Rebuild initramfs
mkinitcpio -P

# Enable services
systemctl enable NetworkManager
systemctl enable gdm

echo -e "${GREEN}=== Installation Complete ===${NC}"
echo "System configured. Exit chroot and reboot."

CHROOT_EOF

echo -e "${GREEN}=== Installation complete ===${NC}"
echo "Unmounting and ready to reboot..."
umount -R /mnt

echo -e "${GREEN}Type 'reboot' to restart your system${NC}"