#!/bin/bash

# Exit on error
set -e

# Install dialog if not present in live environment
if ! command -v dialog &> /dev/null; then
    pacman -Sy --noconfirm dialog
fi

# Function to show progress
show_progress() {
    echo -e "\n==> $1"
}

# Function to get disk size in GB
get_disk_size() {
    local disk=$1
    size=$(lsblk -b -dn -o SIZE $disk)
    echo $((size/1024/1024/1024))
}

# Function to check if EFI partition exists
check_efi_partition() {
    local disk=$1
    if fdisk -l $disk | grep -i "EFI" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# Verify boot mode
show_progress "Verifying EFI boot mode..."
if [ ! -d "/sys/firmware/efi/efivars" ]; then
    dialog --title "Error" --msgbox "System not booted in EFI mode!" 7 40
    exit 1
fi

# Check internet connection
show_progress "Checking internet connection..."
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    if dialog --title "Network" --yesno "No internet connection detected. Configure WiFi?" 7 40; then
        # Get list of wireless devices
        devices=$(iwctl device list | grep -oE "wlan[0-9]")
        if [ -z "$devices" ]; then
            dialog --title "Error" --msgbox "No wireless devices found!" 7 40
            exit 1
        fi
        
        # Create device selection menu
        device_options=""
        for dev in $devices; do
            device_options="$device_options $dev $dev"
        done
        
        # Select wireless device
        device=$(dialog --title "Select WiFi Device" --menu "Choose your wireless device:" 15 40 5 $device_options 2>&1 >/dev/tty)
        
        # Scan for networks
        iwctl station $device scan
        sleep 2
        
        # Get network list
        networks=$(iwctl station $device get-networks | tail -n +5 | head -n -1 | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | awk '{print $1}')
        network_options=""
        for net in $networks; do
            network_options="$network_options $net $net"
        done
        
        # Select network
        ssid=$(dialog --title "Select Network" --menu "Choose your network:" 15 40 5 $network_options 2>&1 >/dev/tty)
        
        # Get password
        password=$(dialog --title "WiFi Password" --passwordbox "Enter password for $ssid:" 8 40 2>&1 >/dev/tty)
        
        # Connect
        show_progress "Connecting to $ssid..."
        iwctl station $device connect "$ssid" --passphrase "$password"
        sleep 5
        
        if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
            dialog --title "Error" --msgbox "Failed to connect to network!" 7 40
            exit 1
        fi
    else
        dialog --title "Error" --msgbox "Please setup internet connection manually and restart script" 7 40
        exit 1
    fi
fi

# Get available disks
disks=$(lsblk -dpno NAME,SIZE,MODEL | grep -E "^/dev/(sd|nvme|vd)")
disk_options=""
while IFS= read -r disk; do
    name=$(echo $disk | awk '{print $1}')
    size=$(echo $disk | awk '{print $2}')
    model=$(echo $disk | awk '{$1=$2=""; print $0}' | sed 's/^  //')
    disk_options="$disk_options $name \"$size - $model\""
done <<< "$disks"

# Select installation disk
target_disk=$(dialog --title "Select Disk" --menu \
    "Select disk for Arch Linux installation:\nWARNING: Selected disk will be modified!" \
    15 60 5 $disk_options 2>&1 >/dev/tty)

if [ -z "$target_disk" ]; then
    dialog --title "Error" --msgbox "No disk selected!" 7 40
    exit 1
fi

# Confirm disk selection
if ! dialog --title "Confirm" --yesno "Are you sure you want to install on $target_disk?\nThis will modify the partition table!" 8 50; then
    exit 1
fi

# Get disk size and calculate recommended sizes
total_size=$(get_disk_size $target_disk)
recommended_root=$((total_size - 32)) # Reserve some space for EFI if needed
recommended_swap=$(free -g | awk '/^Mem:/{print $2 + 2}') # RAM size + 2GB

# Ask for partition sizes
root_size=$(dialog --title "Root Partition" --inputbox \
    "Enter root partition size in GB\nRecommended: ${recommended_root}GB\nAvailable: ${total_size}GB" \
    10 50 $recommended_root 2>&1 >/dev/tty)

swap_size=$(dialog --title "Swap Partition" --inputbox \
    "Enter swap partition size in GB\nRecommended: ${recommended_swap}GB" \
    9 50 $recommended_swap 2>&1 >/dev/tty)

# Ask about encryption
if dialog --title "Encryption" --yesno "Do you want to encrypt the root partition?" 7 50; then
    encrypt_root=1
    password=$(dialog --title "Encryption Password" --passwordbox \
        "Enter encryption password:" 8 50 2>&1 >/dev/tty)
    password2=$(dialog --title "Confirm Password" --passwordbox \
        "Confirm encryption password:" 8 50 2>&1 >/dev/tty)
    
    if [ "$password" != "$password2" ]; then
        dialog --title "Error" --msgbox "Passwords do not match!" 7 40
        exit 1
    fi
else
    encrypt_root=0
fi

# Begin partitioning
show_progress "Preparing disk..."

# Check for existing EFI partition
if check_efi_partition $target_disk; then
    efi_part=$(fdisk -l $target_disk | grep "EFI" | awk '{print $1}')
    dialog --title "Info" --msgbox "Found existing EFI partition: $efi_part\nWill reuse it." 7 50
else
    show_progress "Creating new EFI partition..."
    # Create new EFI partition (512MB)
    parted -s $target_disk mklabel gpt
    parted -s $target_disk mkpart primary fat32 1MiB 513MiB
    parted -s $target_disk set 1 esp on
    efi_part="${target_disk}1"
    mkfs.fat -F32 $efi_part
fi

# Create swap partition
show_progress "Creating swap partition..."
parted -s $target_disk mkpart primary linux-swap 513MiB "$((513 + $swap_size))MiB"
swap_part="${target_disk}2"
mkswap $swap_part
swapon $swap_part

# Create root partition
show_progress "Creating root partition..."
parted -s $target_disk mkpart primary ext4 "$((513 + $swap_size))MiB" 100%
root_part="${target_disk}3"

# Handle encryption if selected
if [ $encrypt_root -eq 1 ]; then
    show_progress "Setting up encryption..."
    echo -n "$password" | cryptsetup luksFormat $root_part -
    echo -n "$password" | cryptsetup open $root_part cryptroot -
    mkfs.ext4 /dev/mapper/cryptroot
    mount /dev/mapper/cryptroot /mnt
else
    mkfs.ext4 $root_part
    mount $root_part /mnt
fi

# Mount EFI partition
mkdir -p /mnt/boot
mount $efi_part /mnt/boot

# Save configuration for next stage
cat > /tmp/install_config << EOF
TARGET_DISK=$target_disk
EFI_PART=$efi_part
SWAP_PART=$swap_part
ROOT_PART=$root_part
ENCRYPT_ROOT=$encrypt_root
EOF

show_progress "Basic partitioning complete!"
dialog --title "Success" --msgbox "Partitioning completed successfully!\nConfiguration saved for next stage." 8 50

# Continue with base system installation?
if dialog --title "Continue" --yesno "Continue with base system installation?" 7 40; then
    show_progress "Installing base system..."
    # This is where we'll continue with the next part of the script
    # We'll add package selection, localization, etc. in the next iteration
fi