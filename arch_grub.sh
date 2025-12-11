#!/bin/bash

# Arch Linux + KDE installation script with LUKS encryption
# Ryzen 5600H + GTX 1650 with NVIDIA proprietary drivers
# Uses GRUB, btrfs with subvolumes and LUKS encryption

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Setup logging
LOG_FILE="/var/log/arch_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${GREEN}=== Arch Linux + KDE Installation with LUKS ===${NC}"
echo "Installation log will be saved to: $LOG_FILE"

# Partition configuration
read -p "Enter EFI partition (e.g., /dev/sda1): " EFI_PART
read -p "Enter boot partition (e.g., /dev/sda2): " BOOT_PART
read -p "Enter root partition to encrypt (e.g., /dev/sda3): " ROOT_PART
read -p "Enter hostname: " HOSTNAME
read -p "Enter username: " USERNAME

echo -e "${GREEN}Setting up LUKS encryption...${NC}"
read -s -p "Enter LUKS encryption password: " LUKS_PASSWORD
echo
read -s -p "Confirm LUKS encryption password: " LUKS_PASSWORD_CONFIRM
echo

if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
    echo -e "${RED}LUKS passwords do not match!${NC}"
    exit 1
fi

echo -e "${GREEN}Creating LUKS partition with password...${NC}"
echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 $ROOT_PART -

echo -e "${GREEN}Creating LUKS keyfile for automatic unlock...${NC}"
dd bs=512 count=4 if=/dev/random of=/tmp/crypto_keyfile.bin iflag=fullblock
chmod 600 /tmp/crypto_keyfile.bin

echo -e "${GREEN}Adding keyfile to LUKS (as second unlock method)...${NC}"
echo -n "$LUKS_PASSWORD" | cryptsetup luksAddKey $ROOT_PART /tmp/crypto_keyfile.bin -

echo "Unlocking encrypted partition with keyfile..."
cryptsetup open $ROOT_PART cryptroot --key-file=/tmp/crypto_keyfile.bin

echo -e "${GREEN}Formatting partitions...${NC}"
mkfs.fat -F32 $EFI_PART
mkfs.ext4 $BOOT_PART
mkfs.btrfs -f /dev/mapper/cryptroot

echo -e "${GREEN}Creating btrfs subvolumes...${NC}"
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
umount /mnt

echo -e "${GREEN}Mounting partitions...${NC}"
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mkdir -p /mnt/boot
mkdir -p /mnt/boot/efi
mkdir -p /mnt/var/cache
mkdir -p /mnt/var/log
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@cache /dev/mapper/cryptroot /mnt/var/cache
mount -o noatime,compress=zstd:1,space_cache=v2,discard=async,subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount $BOOT_PART /mnt/boot
mount $EFI_PART /mnt/boot/efi

echo -e "${GREEN}Copying keyfile to /boot (TEMPORARY - move to USB drive later!)...${NC}"
cp /tmp/crypto_keyfile.bin /mnt/boot/crypto_keyfile.bin
chmod 000 /mnt/boot/crypto_keyfile.bin

echo -e "${GREEN}Configuring pacman mirrors and parallel downloads...${NC}"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
reflector --country BR --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

echo -e "${GREEN}Installing base system...${NC}"
pacstrap -K /mnt base base-devel linux linux-lts linux-firmware amd-ucode sudo efibootmgr fish btrfs-progs grub grub-btrfs inotify-tools

echo -e "${GREEN}Generating fstab...${NC}"
genfstab -U /mnt >> /mnt/etc/fstab

# Get UUID of encrypted partition for crypttab
CRYPT_UUID=$(blkid -s UUID -o value $ROOT_PART)

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
passwd "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Pacman config
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# Configure crypttab
echo "cryptroot UUID=$CRYPT_UUID /boot/crypto_keyfile.bin luks" > /etc/crypttab

# Configure mkinitcpio for encryption
sed -i '/^HOOKS=/s/block/block encrypt/' /etc/mkinitcpio.conf
sed -i 's|^FILES=.*|FILES=(/boot/crypto_keyfile.bin)|' /etc/mkinitcpio.conf
mkinitcpio -P

# Install GRUB
echo -e "${GREEN}Installing GRUB...${NC}"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

# Configure GRUB for encryption
CRYPT_UUID_GRUB=\$(blkid -s UUID -o value $ROOT_PART)
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$CRYPT_UUID_GRUB:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@\"|" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

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
systemctl enable bluetooth

echo -e "${GREEN}=== Installation Complete ===${NC}"
echo "System configured. Exit chroot and reboot."

CHROOT_EOF

echo -e "${GREEN}=== Installation complete ===${NC}"
echo ""
echo -e "${RED}IMPORTANT SECURITY NOTICE:${NC}"
echo -e "${RED}Your LUKS keyfile is currently stored in /boot/crypto_keyfile.bin${NC}"
echo -e "${RED}This means your encryption can be bypassed by anyone with physical access!${NC}"
echo -e "${RED}You should move this keyfile to a USB drive as soon as possible.${NC}"
echo ""
echo -e "${GREEN}LUKS is configured with BOTH password and keyfile:${NC}"
echo "- Boots automatically using keyfile (no password prompt)"
echo "- If keyfile is missing, you can manually enter your password"
echo ""
echo "Unmounting and ready to reboot..."
umount -R /mnt
cryptsetup close cryptroot
rm -f /tmp/crypto_keyfile.bin

echo -e "${GREEN}Installation log saved to: $LOG_FILE${NC}"
echo -e "${GREEN}You can copy this log file before rebooting if needed.${NC}"
echo -e "${GREEN}Type 'reboot' to restart your system${NC}"
