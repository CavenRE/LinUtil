#!/bin/bash
{
# Color definitions
rc='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'

# Base URL for raw files
BASE_URL="https://raw.githubusercontent.com/CavenRE/LinUtil/main/src"

# Required components
COMPONENTS=("utils.sh" "disk.sh" "network.sh" "desktop.sh" "system.sh")

# Temporary directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Error handling
check() {
    if [ "$1" -ne 0 ]; then
        printf "${red}ERROR: %s${rc}\n" "$2"
        exit 1
    fi
    printf "${green}✓ %s${rc}\n" "$2"
}

# Print header
print_header() {
    clear
    printf "${blue}╔═══════════════════════════════════════╗${rc}\n"
    printf "${blue}║      Arch Linux Installation Tool     ║${rc}\n"
    printf "${blue}╚═══════════════════════════════════════╝${rc}\n\n"
}

# Initial setup - Must run before anything else
initial_setup() {
    printf "${yellow}=> Performing initial setup...${rc}\n"
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        printf "${red}ERROR: This script must be run as root${rc}\n"
        exit 1
    fi

    # Check if we're on an Arch system
    if [ ! -f "/etc/arch-release" ]; then
        printf "${red}ERROR: This script must be run on Arch Linux${rc}\n"
        exit 1
    fi

    # Update package database first
    printf "Updating package database...\n"
    pacman -Sy --noconfirm || check 1 "Failed to update package database"

    # Install dialog if not present
    if ! command -v dialog >/dev/null 2>&1; then
        printf "Installing dialog...\n"
        pacman -S --noconfirm dialog || check 1 "Failed to install dialog"
    fi

    # Install curl if not present
    if ! command -v curl >/dev/null 2>&1; then
        printf "Installing curl...\n"
        pacman -S --noconfirm curl || check 1 "Failed to install curl"
    fi

    check 0 "Initial setup complete"
}

# Download required components
download_components() {
    printf "${yellow}=> Downloading required components...${rc}\n"
    for component in "${COMPONENTS[@]}"; do
        printf "   Fetching %s..." "$component"
        curl -fsSL "$BASE_URL/$component" -o "$TEMP_DIR/$component"
        check $? "Downloaded $component"
        chmod +x "$TEMP_DIR/$component"
    done
}

# Source components
source_components() {
    for component in "${COMPONENTS[@]}"; do
        # shellcheck source=/dev/null
        source "$TEMP_DIR/$component"
        check $? "Loaded $component"
    done
}

# Quick install function
quick_install() {
    dialog --title "Quick Install" \
           --yesno "This will install Arch Linux with default settings. Continue?" 8 50
    
    if [ $? -eq 0 ]; then
        setup_network
        partition_disk
        install_base
        configure_system
        install_desktop
    fi
}

# Custom install function
custom_install() {
    while true; do
        choice=$(dialog --title "Custom Installation" \
                       --menu "Select installation step:" 15 55 6 \
                       1 "Partition Disks" \
                       2 "Mount Partitions" \
                       3 "Install Base System" \
                       4 "Configure System" \
                       5 "Install Desktop" \
                       6 "Return to Main Menu" \
                       2>&1 >/dev/tty)
        
        case $choice in
            1) partition_disk ;;
            2) mount_partitions ;;
            3) install_base ;;
            4) configure_system ;;
            5) install_desktop ;;
            6) break ;;
        esac
    done
}

# System settings function
system_settings() {
    while true; do
        choice=$(dialog --title "System Settings" \
                       --menu "Select setting to configure:" 15 55 5 \
                       1 "Timezone" \
                       2 "Locale" \
                       3 "Hostname" \
                       4 "User Accounts" \
                       5 "Return to Main Menu" \
                       2>&1 >/dev/tty)
        
        case $choice in
            1) set_timezone ;;
            2) set_locale ;;
            3) set_hostname ;;
            4) manage_users ;;
            5) break ;;
        esac
    done
}

# Main menu
main_menu() {
    while true; do
        choice=$(dialog --title "Arch Linux Installer" \
                       --menu "Choose an installation option:" 15 55 5 \
                       1 "Quick Install (Recommended)" \
                       2 "Custom Install" \
                       3 "Configure Network" \
                       4 "System Settings" \
                       5 "Exit" \
                       2>&1 >/dev/tty)
        
        case $choice in
            1) quick_install ;;
            2) custom_install ;;
            3) setup_network ;;
            4) system_settings ;;
            5) exit 0 ;;
        esac
    done
}

# Main execution
print_header
initial_setup
download_components
source_components
main_menu

}