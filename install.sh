#!/bin/bash

# Exit on error
set -e

# Temporary log file
LOG_FILE="/tmp/arch_install.log"
touch $LOG_FILE

# Enhanced progress function
show_progress() {
    local message=$1
    echo -e "\n==> $message" | tee -a $LOG_FILE
    dialog --title "Progress" --infobox "$message" 8 60
    sleep 1
}

# Enhanced error handling
handle_error() {
    local message=$1
    echo "ERROR: $message" | tee -a $LOG_FILE
    dialog --title "Error" --msgbox "Error: $message\nCheck $LOG_FILE for details." 8 50
    exit 1
}

# Install required packages
show_progress "Installing required packages..."
pacman -Sy --noconfirm dialog 2>>$LOG_FILE || handle_error "Failed to install dialog"

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
    handle_error "System not booted in EFI mode!"
fi

# Enhanced network check and setup
show_progress "Checking network interfaces..."
interfaces=$(ip link | grep -E '^[0-9]+: (en|wl)' | cut -d: -f2 | tr -d ' ')
if [ -z "$interfaces" ]; then
    handle_error "No network interfaces found!"
fi

show_progress "Checking internet connection..."
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    dialog --title "Network Setup" --yesno "No internet connection detected.\nWould you like to:\n\nYes - Configure WiFi\nNo - Configure Ethernet" 10 50

    if [ $? -eq 0 ]; then
        # WiFi Setup
        show_progress "Setting up WiFi..."
        
        # Check for wifi interface
        wifi_dev=$(ip link | grep -E '^[0-9]+: wl' | cut -d: -f2 | tr -d ' ' | head -n1)
        if [ -z "$wifi_dev" ]; then
            handle_error "No wireless interface found!"
        fi

        # Enable wifi interface
        ip link set $wifi_dev up
        sleep 2

        # Use iwctl for WiFi setup
        show_progress "Scanning for networks..."
        iwctl station $wifi_dev scan
        sleep 2

        # Get available networks
        networks=$(iwctl station $wifi_dev get-networks | tail -n +5 | head -n -1 | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | awk '{print $1}')
        
        if [ -z "$networks" ]; then
            handle_error "No wireless networks found!"
        fi

        # Create network selection menu
        network_options=""
        for net in $networks; do
            network_options="$network_options $net $net"
        done

        # Select network
        ssid=$(dialog --title "Select Network" --menu "Choose your network:" 15 50 5 $network_options 2>&1 >/dev/tty)
        
        if [ -z "$ssid" ]; then
            handle_error "No network selected!"
        fi

        # Get password
        password=$(dialog --title "WiFi Password" --passwordbox "Enter password for $ssid:" 8 50 2>&1 >/dev/tty)
        
        show_progress "Connecting to $ssid..."
        iwctl station $wifi_dev connect "$ssid" --passphrase "$password"
        sleep 5

    else
        # Ethernet Setup
        show_progress "Setting up Ethernet..."
        eth_dev=$(ip link | grep -E '^[0-9]+: en' | cut -d: -f2 | tr -d ' ' | head -n1)
        
        if [ -z "$eth_dev" ]; then
            handle_error "No ethernet interface found!"
        fi

        ip link set $eth_dev up
        show_progress "Starting DHCP..."
        dhcpcd $eth_dev
        sleep 5
    fi

    # Verify connection
    if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
        handle_error "Failed to establish internet connection!"
    fi
fi

show_progress "Internet connection established!"

# Get available disks
show_progress "Scanning available disks..."
disks=$(lsblk -dpno NAME,SIZE,MODEL | grep -E "^/dev/(sd|nvme|vd)")
if [ -z "$disks" ]; then
    handle_error "No suitable disks found!"
fi

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
    handle_error "No disk selected!"
fi

# Confirm disk selection
if ! dialog --title "Confirm" --yesno "Are you sure you want to install on $target_disk?\nThis will modify the partition table!" 8 50; then
    show_progress "Installation cancelled by user"
    exit 0
fi

# Calculate sizes
show_progress "Calculating recommended partition sizes..."
total_size=$(get_disk_size $target_disk)
recommended_root=$((total_size - 32))
recommended_swap=$(free -g | awk '/^Mem:/{print $2 + 2}')

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
        handle_error "Passwords do not match!"
    fi
else
    encrypt_root=0
fi

# Begin partitioning
show_progress "Preparing disk for partitioning..."

# Check for existing EFI partition
if check_efi_partition $target_disk; then
    efi_part=$(fdisk -l $target_disk | grep "EFI" | awk '{print $1}')
    dialog --title "Info" --msgbox "Found existing EFI partition: $efi_part\nWill reuse it." 7 50
else
    show_progress "Creating new EFI partition..."
    parted -s $target_disk mklabel gpt
    parted -s $target_disk mkpart primary fat32 1MiB 513MiB
    parted -s $target_disk set 1 esp on
    efi_part="${target_disk}1"
    show_progress "Formatting EFI partition..."
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
    show_progress "Formatting encrypted partition..."
    mkfs.ext4 /dev/mapper/cryptroot
    mount /dev/mapper/cryptroot /mnt
else
    show_progress "Formatting root partition..."
    mkfs.ext4 $root_part
    mount $root_part /mnt
fi

# Mount EFI partition
show_progress "Mounting partitions..."
mkdir -p /mnt/boot
mount $efi_part /mnt/boot

# Save configuration for next stage
show_progress "Saving configuration..."
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
    show_progress "Preparing for base system installation..."
    # Next stage will go here
    # We'll add package selection, localization, etc.
fi

show_progress "Script completed!"
dialog --title "Installation Log" --textbox $LOG_FILE 20 70