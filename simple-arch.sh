#!/usr/bin/env bash

set -euo pipefail

# Colors
BOLD='\e[1m'
RED='\e[31m'
BLUE='\e[34m'
GREEN='\e[32m'
YELLOW='\e[33m'
WHITE="\e[37m"
RESET='\e[0m'

# Defaults
readonly MOUNT_DIR="/mnt"
readonly NET_TEST_HOST="https://archlinux.org/"
readonly DEFAULT_TIMEZONE="America/Los_Angeles"
readonly DEFAULT_LOCALE="en_US.UTF-8"
readonly DEFAULT_BOOTLOADER_ID="GRUB"
readonly DEFAULT_EFI_SIZE="1G"

# Runtime populated config variables
INSTALL_DISK=""
EFI_PART=""
LINUX_PART=""
TIMEZONE=""
LOCALE_VALUE=""
TARGET_HOSTNAME=""
BOOTLOADER_ID=""
DETECTED_MICROCODE=""
MICROCODE_PKG=""
EFI_SIZE="$DEFAULT_EFI_SIZE"
ROOT_PASSWORD=""
USERNAME_VALUE=""
USER_PASSWORD=""

INSTALL_ESSENTIALS=false
INSTALL_GPU=false
INSTALL_PIPEWIRE=false

# Base packages.
readonly -a BASE_PACKAGES=(
    base linux linux-firmware efibootmgr btrfs-progs
    zram-generator sudo vim less networkmanager
)

# Optional "first boot" package sets from the note.
readonly -a ESSENTIAL_PACKAGES=(man-db man-pages less git curl wget rsync)
readonly -a GPU_PACKAGES=(mesa vulkan-radeon vulkan-tools)
readonly -a PIPEWIRE_PACKAGES=(
    pipewire wireplumber pipewire-audio
    pipewire-alsa pipewire-pulse pipewire-jack
)

# -----------------
# Helper Functions
# -----------------

# Print helpers
p_print() { printf "${BOLD}${GREEN}[*]${WHITE} %s${RESET}\n" "$*"; }
log_print() { printf "${BOLD}${YELLOW}[-]${WHITE} %s${RESET}\n" "$*"; }
in_print() { printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}\n" "$*"; }
err_print() { printf "${BOLD}${RED}[!]${WHITE} %s${RESET}\n" "$*"; }
die() {
    err_print "$*"
    cleanup
    exit 1
}

summary_print() { printf "%s${BOLD}${WHITE} %s${RESET}\n" "$@"; }

# Confirmation helper
confirm_yn() {
    local prompt="$1" prompt2="${3:-}" default="${2:-n}" reply
    printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}%s [$default]: " "$prompt" "$prompt2"
    read -r reply || true
    reply="${reply:-$default}"
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# Mount cleanup helper
cleanup_mounts() {
    echo
    if grep -q " ${MOUNT_DIR}/" /proc/mounts 2>/dev/null; then
        log_print "Unmounting filesystems under ${MOUNT_DIR}..."
        umount -R "$MOUNT_DIR" >/dev/null 2>&1 ||
            umount -Rl "$MOUNT_DIR" >/dev/null 2>&1 ||
            err_print "Could not unmount everything under ${MOUNT_DIR}; check 'findmnt -R ${MOUNT_DIR}'."
    fi

}

# Cleanup mounts on exit
cleanup() {
    echo -e "\n\n\n"
    err_print "Exiting script. Unmounting any drives that were mounted..."

    umount -R "$MOUNT_DIR" >/dev/null 2>&1 ||
        umount -Rl "$MOUNT_DIR" >/dev/null 2>&1
}

# Screen clearing helper
clear_screen() {
    clear
    echo -e "${BLUE}

       d8888                 888
      d88888 ${WHITE}Simple${BLUE}          888
     d88P888                 888
    d88P 888 888d888 .d8888b 88888b.
   d88P  888 888P'  d88P'    888 '88b
  d88P   888 888    888      888  888
 d8888888888 888    Y88b.    888  888
d88P     888 888     '8888P  888  888

                       ${RESET}Install script

    ${RESET}"
    echo
}

trap cleanup SIGINT SIGTERM ERR

# -------------------
# Environment Checks
# -------------------

# Check if booted in arch iso
check_iso() {
    # /etc/arch-release included in Arch ISO. If missing, not in live ISO
    # Arch mounts runtime at /run/archiso. If missing, not in live ISO
    [[ -f /etc/arch-release ]] || die "Not an Arch based system! /etc/arch-release missing"
    [[ -d /run/archiso ]] || die "Not an Arch ISO live environment! /run/archiso missing"
    p_print "Arch ISO live environment confirmed"
}

# Check if booted in UEFI system
check_uefi() {
    [[ -d /sys/firmware/efi ]] || die "Not in UEFI mode!"
    p_print "UEFI system confirmed"
}

# Check for a network connection
check_network() {
    log_print "Checking network connectivity.."

    if curl -fsS --connect-timeout 5 --max-time 10 $NET_TEST_HOST >/dev/null; then
        p_print "Internet connection confirmed"
    else
        err_print "No network connectivity!"
        echo
        log_print "For Wi-Fi, use iwctl:"
        die "iwctl  ->  device list  ->  station wlan0 connect <SSID>"
    fi
}

# Make sure needed tooling is installed
check_tools() {
    local -a required=(
        lsblk sgdisk mkfs.fat mkfs.btrfs btrfs
        mount umount findmnt mountpoint
        pacstrap genfstab arch-chroot
        grep sed awk sort udevadm
        reflector partprobe

    )

    local -a missing_tools=()

    for tool in "${required[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
    done

    if ((${#missing_tools[@]} > 0)); then
        err_print "The following required tools are missing:"

        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done

        die "Please install them and try again."
    fi

    p_print "All required tools available"
}

# Check that "/mnt" is free
check_mountpoint() {
    if grep -q " ${MOUNT_DIR}/" /proc/mounts 2>/dev/null; then
        err_print "Mount point $MOUNT_DIR not free!"
        grep " ${MOUNT_DIR}/" /proc/mounts | awk '{print $2}' >&2 || true
        die "Unmount (umount -R $MOUNT_DIR) and re-run"
    fi
    p_print "Mount point $MOUNT_DIR is free"
}

# Trigger for all checks
env_check() {
    log_print "...Pre-install checks..."
    check_iso
    check_uefi
    check_network
    check_tools
    check_mountpoint
    p_print "All pre-install checks passed!"
    sleep 3
    clear_screen
}

# -------------------
# Mirror list update
# -------------------

# Option to refresh pacman's mirror list with reflector
refresh_mirrors() {
    log_print "...Update mirrors..."

    if confirm_yn "Refresh mirrors with reflector?" "n"; then
        log_print "Refreshing mirrors.."

        if reflector --latest 15 --protocol https --age 12 --sort rate --save /etc/pacman.d/mirrorlist; then
            p_print "List preview:"
            echo
            sed -n '2,13p' /etc/pacman.d/mirrorlist || true
            confirm_yn "Accpet updated mirrors?" "y" || refresh_mirrors
        else
            err_print "Refresh failed! Using old mirrors"
        fi
    else
        log_print "Skipping mirror refresh"
    fi
    clear_screen
}

# --------------------------
# Interactive configuration
# --------------------------

# Prompt for timezone (or use default)
prompt_timezone() {
    local reply
    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s ${RESET}" "Timezone (TZ database name):"
        read -r -p "[$DEFAULT_TIMEZONE] " reply || die "No input received (stdin closed); aborting."

        TIMEZONE="${reply:-$DEFAULT_TIMEZONE}"

        if [[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
            break
        fi

        log_print "$TIMEZONE not found under /usr/share/zoneinfo. Example values: America/Los_Angeles, Europe/Berlin."
    done

    p_print "Timezone: ${TIMEZONE}"
    echo
}

# Prompt for locale
prompt_locale() {
    local reply
    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s ${RESET}" "System locale:"
        read -r -p "[$DEFAULT_LOCALE] " reply || die "No input received (stdin closed); aborting."

        LOCALE_VALUE="${reply:-$DEFAULT_LOCALE}"

        if [[ "$LOCALE_VALUE" =~ ^[a-z]{2}_[A-Z]{2}\.[A-Za-z0-9-]+$ ]]; then
            break
        fi

        log_print "Invalid locale format. Expected something like en_US.UTF-8."
    done

    p_print "Locale: ${LOCALE_VALUE}"
    echo
}

# Prompt for hostname
prompt_hostname() {
    local reply
    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s ${RESET}" "Hostname:"
        read -r reply || die "No input received (stdin closed); aborting."

        if [[ "$reply" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
            TARGET_HOSTNAME="$reply"
            break
        fi

        log_print "Invalid hostname. Use letters, digits and hyphens (no leading/trailing hyphen), e.g. Arch-Desktop."
    done

    p_print "Hostname: ${TARGET_HOSTNAME}"
    echo
}

# Prompt for bootloader ID
prompt_bootloader_id() {
    local reply
    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s ${RESET}" "GRUB bootloader ID:"
        read -r -p "[${DEFAULT_BOOTLOADER_ID}] " reply || die "No input received (stdin closed); aborting."

        BOOTLOADER_ID="${reply:-$DEFAULT_BOOTLOADER_ID}"

        if [[ "$BOOTLOADER_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
            break
        fi

        log_print "Invalid ID. Use only letters, digits, '.', '_' and '-'"
    done

    p_print "GRUB bootloader ID: ${BOOTLOADER_ID}"
    echo
}

# Prompt for CPU
prompt_microcode() {
    local vendor="" reply
    vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"

    case "$vendor" in
    GenuineIntel)
        log_print "Intel CPU detected"
        DETECTED_MICROCODE="intel"
        ;;
    AuthenticAMD)
        log_print "AMD CPU detected"
        DETECTED_MICROCODE="amd"
        ;;
    esac

    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s ${RESET}" "CPU Microcode package:"
        read -r -p "amd / intel / none [${DETECTED_MICROCODE}] " reply || die "No input received (stdin closed); aborting."
        reply="${reply:-$DETECTED_MICROCODE}"

        case "$reply" in
        amd)
            MICROCODE_PKG="amd-ucode"
            break
            ;;
        intel)
            MICROCODE_PKG="intel-ucode"
            break
            ;;
        none)
            MICROCODE_PKG=""
            break
            ;;
        *) log_print "Please answer 'amd', 'intel' or 'none'." ;;
        esac
    done

    p_print "CPU microcode: ${MICROCODE_PKG:-<none>}"
    echo
}

# Prompt for optional packages
prompt_extras() {
    if confirm_yn "Install essential packages?" "y" " (man-db, man-pages, less, git, curl, wget, rsync)"; then
        INSTALL_ESSENTIALS=true
    fi
    echo

    if confirm_yn "Install AMD GPU packages?" "n" " (mesa, vulkan-radeon, vulkan-tools)"; then
        INSTALL_GPU=true
    fi
    echo

    if confirm_yn "Install PipeWire audio stack?" "y" " (pipewire, wireplumber, pipewire-audio/alsa/pulse/jack)"; then
        INSTALL_PIPEWIRE=true
    fi
    echo
}

# Prompt for EFI size
prompt_efi_size() {
    local reply
    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s ${RESET}" "EFI system partition size (1 GB minimum):"
        read -r -p "[${DEFAULT_EFI_SIZE}]: " reply || die "No input received (stdin closed); aborting."
        EFI_SIZE="${reply:-$DEFAULT_EFI_SIZE}"

        if [[ "$EFI_SIZE" =~ ^[1-9][0-9]*[KkMmGgTt]$ ]]; then
            break
        fi

        log_print "Invalid size (must be at least 1G)"
    done

    p_print "EFI partition size: ${EFI_SIZE}"
    echo
}

# Prompt for the root password
prompt_root_password() {
    local p1 p2

    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}" "Root password: "
        read -r -s p1 || die "No input received (stdin closed); aborting."
        echo

        printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}" "Confirm root password: "
        read -r -s p2 || die "No input received (stdin closed); aborting."
        echo

        if [[ -z "$p1" ]]; then
            log_print "Password must not be empty."
        elif [[ "$p1" != "$p2" ]]; then
            log_print "Passwords do not match, try again."
        elif [[ "$p1" == *:* ]]; then
            log_print "Password must not contain ':' (used as a separator by chpasswd)."
        else
            ROOT_PASSWORD="$p1"
            break
        fi

    done

    p_print "Root password set"
    echo
}

# Prompt for user
prompt_user() {
    local reply p1 p2
    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}" "Username (sudo user): "
        read -r reply || die "No input received (stdin closed); aborting."

        if [[ "$reply" == "root" ]]; then
            log_print "'root' already exists; pick another username."
        elif [[ "$reply" =~ ^[a-z_][a-z0-9_-]*$ ]] && ((${#reply} <= 32)); then
            USERNAME_VALUE="$reply"
            break
        else
            log_print "Invalid username. Use lowercase letters, digits, '_' and '-', starting with a letter or '_' (max 32 chars)."
        fi

    done

    while true; do
        printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}" "Password for '${USERNAME_VALUE}': "
        read -r -s p1 || die "No input received (stdin closed); aborting."
        echo

        printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}" "Confirm password: "
        read -r -s p2 || die "No input received (stdin closed); aborting."
        echo

        if [[ -z "$p1" ]]; then
            log_print "Password must not be empty."
        elif [[ "$p1" != "$p2" ]]; then
            log_print "Passwords do not match, try again."
        elif [[ "$p1" == *:* ]]; then
            log_print "Password must not contain ':' (used as a separator by chpasswd)."
        else
            USER_PASSWORD="$p1"
            break
        fi

    done
    p_print "User '${USERNAME_VALUE}' will be created (sudo)."
    echo
}

prompt_summary() {
    clear_screen
    p_print "...Summary..."
    echo
    summary_print "Timezone = " "$TIMEZONE"
    summary_print "Locale = " "$LOCALE_VALUE"
    summary_print "Hostname = " "$TARGET_HOSTNAME"
    echo
    summary_print "Bootloader ID = " "$BOOTLOADER_ID"
    summary_print "EFI partition size = " "$EFI_SIZE"
    summary_print "Selected Microcode = " "$MICROCODE_PKG"
    echo
    summary_print "Username = " "$USERNAME_VALUE"
    echo

    if ! $INSTALL_ESSENTIALS; then
        echo -e "Essential packages selected: ${RED}${BOLD}NO${RESET}"
    else
        echo -e "Essential packages selected: ${GREEN}${BOLD}YES${RESET}"
    fi

    if ! $INSTALL_GPU; then
        echo -e "Additional AMD GPU packages selected: ${RED}${BOLD}NO${RESET}"
    else
        echo -e "Additional AMD GPU packages selected: ${GREEN}${BOLD}YES${RESET}"
    fi

    if ! $INSTALL_PIPEWIRE; then
        echo -e "Pipewire audio packages selected: ${RED}${BOLD}NO${RESET}"
    else
        echo -e "Pipewire audio packages selected: ${GREEN}${BOLD}YES${RESET}"
    fi
    echo
}

# Main function to trigger the rest
gather_config() {
    log_print "...System Configuration..."
    prompt_timezone
    prompt_locale
    prompt_hostname
    prompt_bootloader_id
    prompt_efi_size
    prompt_microcode
    prompt_root_password
    prompt_user

    sleep 1
    clear_screen

    prompt_extras
    prompt_summary
}

# ---------------
# Disk Selection
# ---------------

# Display the list of available disks, storing selected path in INSTALL_DISK
# Using bash built in 'select'.
select_disk() {
    local disk
    local disks
    in_print "Available disks for the installation:"
    mapfile -t disks < <(lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|nvme|vd)")

    PS3="Please select the number of the corresponding disk (e.g. 1): "
    select disk in "${disks[@]}"; do

        # Extract just the the path from the string
        INSTALL_DISK=$(echo "$disk" | awk '{print $1}')

        if [[ ! -b $INSTALL_DISK ]]; then
            die "Bad selection. Re-run script"

        fi
        clear_screen
        p_print "Arch Linux will be installed on the following disk: $INSTALL_DISK"
        echo

        break
    done
}

# Destructive confirmation
confirm_destruction() {
    log_print "Confirm destructive operation!"
    printf "${BOLD}${YELLOW}[-]${WHITE} %s ${RESET}%s\n" "Selected Disk:" "$INSTALL_DISK"
    echo

    printf "${BOLD}${RED}[!!!]${WHITE} %s${RESET}\n" "THE NEXT STEP WILL ERASE ALL DATA ON '${INSTALL_DISK}'."
    printf "${BOLD}${RED}[!!!]${WHITE} %s${RESET}\n" "The current partition table and every partition on '${INSTALL_DISK}' will be destroyed."
    printf "${BOLD}${RED}[!!!]${WHITE} %s${RESET}\n" "There is no undo. Make sure '${INSTALL_DISK}' is the right disk."
    echo

    local ack
    printf "${BOLD}${BLUE}[?]${WHITE} %s${RESET}" "To confirm, type the exact device path '${INSTALL_DISK}' (anything else aborts): "
    read -r ack || die "No input received (stdin closed); aborting. No changes were made."

    [[ "$ack" == "$INSTALL_DISK" ]] || die "Aborted: confirmation did not match '${INSTALL_DISK}'. No changes were made."

    p_print "Disk selection confirmed. ${INSTALL_DISK} will be formatted"
    echo
}

# ------------------
# Disk partitioning
# ------------------

# DESTRUCTIVE: wipes the partition table of ${INSTALL_DISK} and creates a fresh GPT
# with: 1) EFI System Partition (ef00), ${EFI_SIZE}; 2) Linux FS (8300), rest.
partition_disk() {
    log_print "...Partitioning ${INSTALL_DISK}..."
    echo

    sgdisk --zap-all "$INSTALL_DISK" >/dev/null
    sgdisk -n "1:0:+${EFI_SIZE}" -t 1:ef00 -c 1:EFI "$INSTALL_DISK" >/dev/null
    sgdisk -n 2:0:0 -t 2:8300 -c 2:Linux "$INSTALL_DISK" >/dev/null
    sgdisk -p "$INSTALL_DISK" | tail -n 3 >/dev/null

    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$INSTALL_DISK" || err_print "partprobe failed; relying on udev to find the new partitions."
    fi

    udevadm settle
    sleep 1

    resolve_partitions

    p_print "Partitioning complete: ${INSTALL_DISK} now has a ${EFI_SIZE} EFI partition and a Linux partition."
    echo "    - EFI = ${EFI_PART}"
    echo "    - Linux = ${LINUX_PART}"
    echo
}

# Check partitions created as planned
resolve_partitions() {
    local -a parts=()
    mapfile -t parts < <(lsblk -nrpo NAME,TYPE "$INSTALL_DISK" | awk '$2 == "part" {print $1}' | sort -V)

    if ((${#parts[@]} != 2)); then
        die "Expected 2 partitions on ${INSTALL_DISK}, found ${#parts[@]}. Inspect with: lsblk"
    fi

    EFI_PART="${parts[0]}"
    LINUX_PART="${parts[1]}"

    [[ -b "$EFI_PART" ]] || die "EFI partition ${EFI_PART} did not appear after partitioning."
    [[ -b "$LINUX_PART" ]] || die "Linux partition ${LINUX_PART} did not appear after partitioning."
}

# Format partitions and mount them
# DESTRUCTIVE: creates new filesystems, erasing anything previously on these partitions.
format_and_mount() {
    log_print "...Formatting and mounting..."
    echo

    log_print "Formatting EFI partition ${EFI_PART} as FAT32.."
    mkfs.fat -F32 "$EFI_PART" >/dev/null

    log_print "Formatting ${LINUX_PART} as Btrfs.."
    mkfs.btrfs -f "$LINUX_PART" >/dev/null

    log_print "Creating @ and @home subvolumes.."
    mount "$LINUX_PART" "$MOUNT_DIR"
    btrfs subvolume create "$MOUNT_DIR/@" >/dev/null
    btrfs subvolume create "$MOUNT_DIR/@home" >/dev/null
    # btrfs subvolume list "$MOUNT_DIR"
    echo

    # Unmount the temporary mount before mounting the subvolumes.
    umount "$MOUNT_DIR"

    log_print "Mounting subvolumes.."
    mount -o noatime,compress=zstd,subvol=@ "$LINUX_PART" "$MOUNT_DIR"
    mkdir -p "$MOUNT_DIR/home" "$MOUNT_DIR/efi"
    mount -o noatime,compress=zstd,subvol=@home "$LINUX_PART" "$MOUNT_DIR/home"

    log_print "Mounting EFI partition.."
    mount "$EFI_PART" "$MOUNT_DIR/efi"

    # p_print "Mount points:"
    # findmnt -R "$MOUNT_DIR"
    echo
}

# ----------------------------
# Base installation and fstab
# ----------------------------

install_base() {
    log_print "...Base installation..."
    log_print "This may take some time.."
    echo
    local -a packages=("${BASE_PACKAGES[@]}")

    [[ -n "$MICROCODE_PKG" ]] && packages+=("$MICROCODE_PKG")

    if $INSTALL_ESSENTIALS; then
        packages+=("${ESSENTIAL_PACKAGES[@]}")
    fi

    if $INSTALL_GPU; then
        packages+=("${GPU_PACKAGES[@]}")
    fi

    if $INSTALL_PIPEWIRE; then
        packages+=("${PIPEWIRE_PACKAGES[@]}")
    fi

    local pkg_list_str=""
    printf -v pkg_list_str '%s ' "${packages[@]}"
    printf "${BOLD}${YELLOW}[-]${WHITE} %s ${RESET}%s\n" "Installing Packages:" "$pkg_list_str"

    # Install the base system
    pacstrap -K "$MOUNT_DIR" "${packages[@]}" >/dev/null 2>&1 || die "pacstrap failed."
    p_print "Base installation complete."
    echo
}

generate_fstab() {
    log_print "...Generating fstab..."

    [[ -d "$MOUNT_DIR/etc" ]] || die "Installation failed. $MOUNT_DIR/etc missing..."

    genfstab -U "$MOUNT_DIR" >"$MOUNT_DIR/etc/fstab" || die "genfstab failed. No fstab was written to the target."

    [[ -s "$MOUNT_DIR/etc/fstab" ]] || die "genfstab produced an empty file; Installation failed."

    grep -qE '[[:space:]]/[[:space:]]' "$MOUNT_DIR/etc/fstab" || die "No root ('/') entry in fstab. Installation failed"

    grep -q '/efi' "$MOUNT_DIR/etc/fstab" || die "No /efi entry in fstab. Installation failed"

    p_print "fstab successfully generated and written to ${MOUNT_DIR}/etc/fstab:"
    echo
}

# -----------------------------
# chroot system config / setup
# -----------------------------

# chroot helper
chroot_run() {
    arch-chroot "$MOUNT_DIR" "$@"
}

# Main system configuration function
configure_system() {
    log_print "...System configuration..."

    # Set timezone and HW clock
    log_print "Setting timezone and hardware clock to ${TIMEZONE}.."
    chroot_run ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    chroot_run hwclock --systohc

    # Set Locales
    log_print "Generating locale ${LOCALE_VALUE}.."
    local locale_re
    # Sets a '\' escape before '.'
    locale_re="$(printf '%s' "$LOCALE_VALUE" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"

    if ! grep -qE "^#?${locale_re}[[:space:]]+UTF-8" "$MOUNT_DIR/etc/locale.gen"; then
        die "Locale '${LOCALE_VALUE}' is missing in /etc/locale.gen. Please pick a valid locale."
    fi
    # Remove '#' in locale.gen
    sed -i -E "s/^#?(${locale_re}[[:space:]]+UTF-8)/\1/" "$MOUNT_DIR/etc/locale.gen"
    chroot_run locale-gen >/dev/null
    printf 'LANG=%s\n' "$LOCALE_VALUE" >"$MOUNT_DIR/etc/locale.conf"

    # Set hostname
    log_print "Setting hostname.."
    printf '%s\n' "$TARGET_HOSTNAME" >"$MOUNT_DIR/etc/hostname"

    cat >"$MOUNT_DIR/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${TARGET_HOSTNAME}
EOF

    # Set root password
    printf 'root:%s\n' "$ROOT_PASSWORD" | chroot_run chpasswd
    ROOT_PASSWORD=""

    # User creation
    chroot_run useradd -m -G wheel -s /bin/bash "$USERNAME_VALUE"
    printf '%s:%s\n' "$USERNAME_VALUE" "$USER_PASSWORD" | chroot_run chpasswd
    USER_PASSWORD=""

    # Sudo setup
    log_print "Enable sudo.."
    cp "$MOUNT_DIR/etc/sudoers" "$MOUNT_DIR/etc/sudoers.bak"
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL$/%wheel ALL=(ALL:ALL) ALL/' "$MOUNT_DIR/etc/sudoers"
    # Check if sudo file written correctly
    if ! chroot_run visudo -c >/dev/null; then
        cp "$MOUNT_DIR/etc/sudoers.bak" "$MOUNT_DIR/etc/sudoers"
        die "Sudoers syntax error; restored backup."
    fi

    # Services and final configs
    log_print "Configuring services"
    printf '[zram0]\n' >"$MOUNT_DIR/etc/systemd/zram-generator.conf"
    chroot_run systemctl enable NetworkManager.service
    chroot_run systemctl enable fstrim.timer
    p_print "System configuration complete"
    echo
}

# ------------------------
# Bootloader setup (GRUB)
# ------------------------

install_bootloader() {
    local grub_defaults="${MOUNT_DIR}/etc/default/grub"

    log_print "...Installing bootloader (GRUB)..."
    chroot_run pacman -S --needed --noconfirm grub >/dev/null 2>&1 || die "GRUB download failed."

    log_print "Installing GRUB to the ESP (/efi) with bootloader-id '${BOOTLOADER_ID}'.."
    chroot_run grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="$BOOTLOADER_ID" >/dev/null 2>&1 ||
        die "grub-install failed. Check that /efi is mounted and EFI variables are accessible (efibootmgr -v in the chroot)."

    # Disable BOOTNEXT entries
    if grep -qE '^[[:space:]#]*GRUB_DISABLE_BOOTNEXT=' "$grub_defaults"; then
        sed -i -E 's/^[[:space:]#]*GRUB_DISABLE_BOOTNEXT=.*/GRUB_DISABLE_BOOTNEXT=true/' "$grub_defaults"
    else
        printf '\nGRUB_DISABLE_BOOTNEXT=true\n' >>"$grub_defaults"
    fi

    log_print "Generating GRUB configuration.."
    chroot_run grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 ||
        die "grub-mkconfig failed. Verify kernel images exist in /boot of the target (ls ${MOUNT_DIR}/boot)."

    log_print "GRUB installed and configured"
    echo
}

# --------------
# Sanity Checks
# --------------

sanity_checks() {
    log_print "...Pre-boot sanity checks..."
    local failed=0
    echo

    log_print "Mounts under ${MOUNT_DIR}:"
    findmnt -R "$MOUNT_DIR" || failed=1
    echo

    # log_print "Filesystems:"
    # lsblk -f || failed=1
    # echo

    # log_print "fstab:"
    # cat "$MOUNT_DIR/etc/fstab" || failed=1
    # echo

    log_print "Testing fstab with 'mount -a' in the chroot.."
    chroot_run mount -a || {
        err_print "mount -a failed - fstab is not usable."
        failed=1
    }
    p_print "fstab success"
    echo

    findmnt "$MOUNT_DIR/efi" >/dev/null || {
        err_print "The EFI partition is not mounted at /efi."
        failed=1
    }

    # log_print "Boot files:"
    # ls -lah "$MOUNT_DIR/boot" || failed=1
    # ls -lah "$MOUNT_DIR/efi" || failed=1
    # ls -lah "$MOUNT_DIR/boot/grub" || failed=1
    # echo

    [[ -f "$MOUNT_DIR/boot/grub/grub.cfg" ]] || {
        err_print "Missing /boot/grub/grub.cfg"
        failed=1
    }

    [[ -f "$MOUNT_DIR/efi/EFI/${BOOTLOADER_ID}/grubx64.efi" ]] ||
        {
            err_print "Missing /efi/EFI/${BOOTLOADER_ID}/grubx64.efi - GRUB may not have installed to the ESP."
            failed=1
        }

    ((failed == 0)) || die "One or more sanity checks FAILED. Review the output above before rebooting."

    p_print "All sanity checks passed!"
    sleep 3
}

# ----------------------
# Finalize installation
# ----------------------

finalize() {
    clear_screen
    log_print "...Finalizing installation..."
    log_print "Unmounting filesystems under ${MOUNT_DIR}..."

    umount -R "$MOUNT_DIR" ||
        {
            err_print "umount -R failed; retrying with lazy unmount."
            umount -Rl "$MOUNT_DIR" || true
        }

    cat <<'EOF'

========================================
Installation COMPLETE.
========================================
Remove the installation media and reboot
========================================

EOF

    if confirm_yn "Reboot now?" "n"; then
        echo
        log_print "Rebooting.."
        sleep 3
        reboot
    else
        echo
        log_print "Not rebooting. Reboot with 'reboot'"
    fi
}

main() {
    clear_screen
    env_check
    refresh_mirrors
    gather_config

    if ! confirm_yn "All inputs collected. All further operations will be DESTRUCTIVE! Proceed to disk selection?" "n"; then
        die "Aborted. No changes made."
    fi

    clear_screen

    select_disk
    confirm_destruction
    partition_disk
    format_and_mount
    install_base
    generate_fstab
    configure_system
    install_bootloader
    sanity_checks
    finalize
}

main "$@"
