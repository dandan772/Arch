#!/bin/bash

# Arch Linux + KDE installation script with LUKS encryption
# Ryzen 5600H with integrated graphics
# Uses systemd-boot, ext4 on LUKS, minimal setup

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Setup logging
LOG_FILE="/var/log/arch_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${GREEN}=== Arch Linux + KDE Installation with LUKS ===${NC}"
echo "Installation log will be saved to: $LOG_FILE"

# Partition configuration
read -p "Enter disk device (e.g., /dev/sda): " DISK
read -p "Enter EFI partition (e.g., /dev/sda1): " EFI_PART
read -p "Enter EFI partition number (e.g., 1): " EFI_NUM
read -p "Enter root partition to encrypt (e.g., /dev/sda2): " ROOT_PART
read -p "Enter hostname: " HOSTNAME
read -p "Enter username: " USERNAME

echo -e "${YELLOW}Setting up LUKS encryption password...${NC}"
read -s -p "Enter LUKS encryption password: " LUKS_PASSWORD
echo
read -s -p "Confirm LUKS encryption password: " LUKS_PASSWORD_CONFIRM
echo

if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
    echo -e "${RED}LUKS passwords do not match!${NC}"
    exit 1
fi

echo -e "${YELLOW}Setting up user password...${NC}"
read -s -p "Enter password for $USERNAME: " PASSWORD
echo
read -s -p "Confirm password: " PASSWORD_CONFIRM
echo

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    echo -e "${RED}Passwords do not match!${NC}"
    exit 1
fi

echo -e "${GREEN}Formatting EFI partition (if needed)...${NC}"
#mkfs.fat -F32 $EFI_PART

echo -e "${GREEN}Setting up LUKS encryption...${NC}"
echo -e "${YELLOW}This will DESTROY all data on $ROOT_PART${NC}"
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
fi

# Setup LUKS
echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 $ROOT_PART -
echo -n "$LUKS_PASSWORD" | cryptsetup open $ROOT_PART cryptroot -

echo -e "${GREEN}Formatting encrypted partition...${NC}"
mkfs.ext4 -F /dev/mapper/cryptroot

echo -e "${GREEN}Mounting partitions...${NC}"
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount $EFI_PART /mnt/boot

echo -e "${GREEN}Configuring pacman mirrors and parallel downloads...${NC}"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

echo -e "${GREEN}Installing base system...${NC}"
pacstrap -K /mnt base base-devel linux linux-lts linux-firmware amd-ucode sudo fish efibootmgr reflector

echo -e "${GREEN}Generating fstab...${NC}"
genfstab -U /mnt >> /mnt/etc/fstab

# Get UUID of encrypted partition
ROOT_UUID=$(blkid -s UUID -o value $ROOT_PART)

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

# Configure mkinitcpio for LUKS
echo -e "${GREEN}Configuring initramfs for LUKS...${NC}"
sed -i 's/\(^HOOKS=([^)]*block\)/\1 encrypt/' /etc/mkinitcpio.conf

# Regenerate initramfs
mkinitcpio -P

# Install systemd-boot
echo -e "${GREEN}Installing systemd-boot...${NC}"
bootctl install

# Create EFI entry with efibootmgr
echo -e "${GREEN}Creating EFI boot entry...${NC}"
efibootmgr --create --disk $DISK --part $EFI_NUM --loader '\EFI\systemd\systemd-bootx64.efi' --label "Linux Boot Manager" --unicode

# Create systemd-boot entry for Arch Linux
mkdir -p /boot/loader/entries
cat > /boot/loader/entries/arch.conf << EOF
title Arch Linux
linux /vmlinuz-linux
initrd /amd-ucode.img
initrd /initramfs-linux.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw
EOF

cat > /boot/loader/entries/arch-lts.conf << EOF
title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /amd-ucode.img
initrd /initramfs-linux-lts.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rw
EOF

# Bootloader config
cat > /boot/loader/loader.conf << 'EOF'
default arch.conf
timeout 3
editor no
EOF

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
    ark bluedevil bluez bluez-utils breeze-gtk btop fastfetch \
    flatpak kalk kate kde-gtk-config kio-admin kscreen linux-headers \
    linux-lts-headers noto-fonts-cjk noto-fonts-extra noto-fonts-emoji \
    pacman-contrib partitionmanager pipewire-alsa \
    pipewire-pulse pipewire-audio pipewire-jack plasma-pa power-profiles-daemon \
    qbittorrent sddm-kcm unrar wireplumber

# Enable services
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable bluetooth

echo -e "${GREEN}=== Installation Complete ===${NC}"
echo "System configured with LUKS encryption."
echo "You will need to enter your encryption password at boot."

CHROOT_EOF

echo -e "${GREEN}=== Installation complete ===${NC}"
echo "Unmounting and ready to reboot..."
umount -R /mnt
cryptsetup close cryptroot

echo -e "${GREEN}Installation log saved to: $LOG_FILE${NC}"
echo -e "${GREEN}You can copy this log file before rebooting if needed.${NC}"
echo -e "${YELLOW}IMPORTANT: You will need to enter your LUKS password at boot!${NC}"
echo -e "${GREEN}Type 'reboot' to restart your system${NC}"
