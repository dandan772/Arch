#!/bin/bash

# Arch Linux + KDE installation script
# Ryzen 5600H + GTX 1650 with NVIDIA proprietary drivers
# Uses systemd-boot, btrfs with subvolumes, minimal setup

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
mkfs.btrfs -f $ROOT_PART

echo -e "${GREEN}Creating btrfs subvolumes...${NC}"
mount $ROOT_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@images
umount /mnt

echo -e "${GREEN}Mounting partitions...${NC}"
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@ $ROOT_PART /mnt
mkdir -p /mnt/home
mkdir -p /mnt/boot
mkdir -p /mnt/var/cache
mkdir -p /mnt/var/log
mkdir -p /mnt/var/lib/libvirt/images
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@home $ROOT_PART /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@cache $ROOT_PART /mnt/var/cache
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@log $ROOT_PART /mnt/var/log
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@images $ROOT_PART /mnt/var/lib/libvirt/images
mount $EFI_PART /mnt/boot

echo -e "${GREEN}Configuring pacman mirrors and parallel downloads...${NC}"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
reflector --country BR --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

echo -e "${GREEN}Installing base system...${NC}"
pacstrap -K /mnt base base-devel linux linux-lts linux-firmware amd-ucode sudo efibootmgr fish btrfs-progs

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

# Install systemd-boot
echo -e "${GREEN}Installing systemd-boot...${NC}"
bootctl install
efibootmgr --create --disk $ROOT_PART --part 1 --label "Arch Linux" --loader /EFI/systemd/systemd-bootx64.efi --unicode

# Create systemd-boot entry
mkdir -p /boot/loader/entries
cat > /boot/loader/entries/arch.conf << EOF
title Arch Linux
linux /vmlinuz-linux
initrd /amd-ucode.img
initrd /initramfs-linux.img
options root=$ROOT_PART rootflags=subvol=@ rw
EOF

cat > /boot/loader/entries/arch-lts.conf << EOF
title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /amd-ucode.img
initrd /initramfs-linux-lts.img
options root=$ROOT_PART rootflags=subvol=@ rw
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
    plasma-desktop plasma-nm dolphin kwalletmanager konsole sddm firefox \
    network-manager-applet \
    xorg-xwayland \
    git neovim nano \
    ark bluedevil blueman bluez bluez-utils breeze-gtk btop nvtop fastfetch \
    flatpak kalk kate kde-gtk-config kio-admin kscreen linux-headers \
    linux-lts-headers noto-fonts-cjk noto-fonts-extra noto-fonts-emoji \
    nvidia-open-dkms nvidia-settings pacman-contrib partitionmanager pipewire-alsa \
    pipewire-pulse pipewire-audio pipewire-jack plasma-pa power-profiles-daemon \
    qbittorrent sddm-kcm timeshift unrar wireplumber

# Configure mirrors with reflector for the system
echo -e "${GREEN}Configuring mirrors with reflector...${NC}"
reflector --country BR --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

# Enable services
systemctl enable NetworkManager
systemctl enable sddm

echo -e "${GREEN}=== Installation Complete ===${NC}"
echo "System configured. Exit chroot and reboot."

CHROOT_EOF

echo -e "${GREEN}=== Installation complete ===${NC}"
echo "Unmounting and ready to reboot..."
umount -R /mnt

echo -e "${GREEN}Installation log saved to: $LOG_FILE${NC}"
echo -e "${GREEN}You can copy this log file before rebooting if needed.${NC}"
echo -e "${GREEN}Type 'reboot' to restart your system${NC}"
