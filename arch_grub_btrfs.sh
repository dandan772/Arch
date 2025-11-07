#!/bin/bash

# Arch Linux + KDE installation script
# Ryzen 5600H + GTX 1650 with NVIDIA proprietary drivers
# Uses GRUB, BTRFS with subvolumes, minimal setup

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== Arch Linux + KDE Installation ===${NC}"

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
# mkfs.fat -F32 $EFI_PART
mkfs.btrfs -f $ROOT_PART

echo -e "${GREEN}Creating BTRFS subvolumes...${NC}"
mount $ROOT_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@snapshots
umount /mnt

echo -e "${GREEN}Mounting subvolumes with compression...${NC}"
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@ $ROOT_PART /mnt
mkdir -p /mnt/{home,var/log,var/cache,boot/efi,.snapshots}
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@home $ROOT_PART /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@log $ROOT_PART /mnt/var/log
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@cache $ROOT_PART /mnt/var/cache
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@snapshots $ROOT_PART /mnt/.snapshots
mount $EFI_PART /mnt/boot/efi

echo -e "${GREEN}Configuring pacman mirrors and parallel downloads...${NC}"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
reflector --country US --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

echo -e "${GREEN}Installing base system...${NC}"
pacstrap -K /mnt base base-devel linux linux-firmware amd-ucode sudo btrfs-progs grub efibootmgr fish

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

# Create user with sudo access and fish shell
useradd -m -G wheel -s /usr/bin/fish "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo > /dev/null

# Pacman config
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# Install GRUB
echo -e "${GREEN}Installing GRUB...${NC}"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Configure GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Install necessary packages
echo -e "${GREEN}Installing packages...${NC}"
pacman -S --noconfirm \
    reflector \
    plasma-desktop plasma-nm dolphin kwalletmanager konsole sddm firefox \
    network-manager-applet \
    xorg-xwayland \
    git neovim nano

# Configure mirrors with reflector for the system
echo -e "${GREEN}Configuring mirrors with reflector...${NC}"
reflector --country US --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
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

echo -e "${GREEN}Type 'reboot' to restart your system${NC}"