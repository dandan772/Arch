#!/bin/bash

# Arch Linux + KDE installation script
# Ryzen 5600H + GTX 1650 with NVIDIA proprietary drivers
# Uses GRUB, ext4, minimal setup

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Setup logging
LOG_FILE="/var/log/arch_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${GREEN}=== Arch Linux + KDE Installation ===${NC}"
echo "Installation log will be saved to: $LOG_FILE"

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
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi

echo -e "${GREEN}Configuring pacman mirrors and parallel downloads...${NC}"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

echo -e "${GREEN}Installing base system...${NC}"
pacstrap -K /mnt base base-devel linux linux-lts linux-firmware amd-ucode sudo fish reflector

echo -e "${GREEN}Generating fstab...${NC}"
genfstab -U /mnt >> /mnt/etc/fstab

echo -e "${GREEN}Configuring system...${NC}"
arch-chroot /mnt bash << CHROOT_EOF
set -e

# Timezone and locale
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Keyboard layout
echo "KEYMAP=br-abnt2" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Create user with sudo access
useradd -m -G wheel -s /usr/bin/fish "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Pacman config
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# Configure mirrors with reflector
echo -e "${GREEN}Configuring mirrors with reflector...${NC}"
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

# Install necessary packages
echo -e "${GREEN}Installing packages...${NC}"
pacman -S --noconfirm \
    plasma-desktop plasma-nm dolphin kwalletmanager konsole sddm firefox \
    network-manager-applet \
    xorg-xwayland \
    git neovim nano \
    ark bluedevil bluez bluez-utils breeze-gtk btop nvtop fastfetch \
    flatpak kalk kate kde-gtk-config kio-admin kscreen linux-headers \
    linux-lts-headers noto-fonts-cjk noto-fonts-extra noto-fonts-emoji \
    nvidia-open-dkms nvidia-settings pacman-contrib partitionmanager pipewire-alsa \
    pipewire-pulse pipewire-audio pipewire-jack plasma-pa power-profiles-daemon \
    qbittorrent sddm-kcm unrar wireplumber \
    grub efibootmgr os-prober

# Install GRUB
echo -e "${GREEN}Installing GRUB...${NC}"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Enable os-prober for dual boot detection
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub

# Generate GRUB config
grub-mkconfig -o /boot/grub/grub.cfg

# Enable services
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable bluetooth

echo -e "${GREEN}=== Installation Complete ===${NC}"
echo "System configured. Exit chroot and reboot."

CHROOT_EOF

echo -e "${GREEN}=== Installation complete ===${NC}"
echo "Unmounting and ready to reboot..."
umount -R /mnt

echo -e "${GREEN}Installation log saved to: $LOG_FILE${NC}"
echo -e "${GREEN}You can copy this log file before rebooting if needed.${NC}"
echo -e "${GREEN}Type 'reboot' to restart your system${NC}"
