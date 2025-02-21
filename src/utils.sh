#!/bin/bash

# Utility functions for Arch Linux installer
LOG_FILE="/tmp/arch_install.log"

# Initialize log file
touch "$LOG_FILE"

# Show progress dialog
show_progress() {
    local message=$1
    echo -e "\n=> $message" | tee -a "$LOG_FILE"
    dialog --title "Progress" --infobox "$message" 3 50
    sleep 1
}

# Handle errors
handle_error() {
    local message=$1
    echo -e "ERROR: $message" | tee -a "$LOG_FILE"
    dialog --title "Error" --msgbox "Error: $message\nCheck $LOG_FILE for details." 8 50
    return 1
}

# Show success message
show_success() {
    local message=$1
    echo -e "✓ $message" | tee -a "$LOG_FILE"
    dialog --title "Success" --msgbox "$message" 6 50
}

# Get disk size in GB
get_disk_size() {
    local disk=$1
    local size
    size=$(lsblk -b -dn -o SIZE "$disk")
    echo $((size/1024/1024/1024))
}

# Check if running in EFI mode
check_efi() {
    if [ ! -d "/sys/firmware/efi/efivars" ]; then
        handle_error "System not booted in EFI mode!"
        return 1
    fi
    return 0
}

# Confirm action
confirm_action() {
    local message=$1
    dialog --title "Confirm" --yesno "$message" 8 50
    return $?
}

# Show help text
show_help() {
    local title=$1
    local text=$2
    dialog --title "$title" --msgbox "$text" 15 60
}

# Get user input
get_input() {
    local title=$1
    local prompt=$2
    local default=$3
    dialog --title "$title" --inputbox "$prompt" 8 50 "$default" 2>/tmp/input
    cat /tmp/input
}

# Get password input
get_password() {
    local title=$1
    local prompt=$2
    dialog --title "$title" --passwordbox "$prompt" 8 50 2>/tmp/input
    cat /tmp/input
}

# Show file content
show_file() {
    local title=$1
    local file=$2
    dialog --title "$title" --textbox "$file" 20 70
}

# Check if package is installed
check_package() {
    local package=$1
    pacman -Qi "$package" >/dev/null 2>&1
}

# Install package if not present
ensure_package() {
    local package=$1
    if ! check_package "$package"; then
        show_progress "Installing $package..."
        pacman -Sy --noconfirm "$package" || handle_error "Failed to install $package"
    fi
}

# Generate fstab
generate_fstab() {
    show_progress "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab || handle_error "Failed to generate fstab"
}

# Execute command in chroot
chroot_exec() {
    arch-chroot /mnt /bin/bash -c "$1"
}

# Save settings
save_settings() {
    local key=$1
    local value=$2
    echo "$key=$value" >> /tmp/install_settings
}

# Load settings
load_settings() {
    local key=$1
    grep "^$key=" /tmp/install_settings | cut -d'=' -f2
}