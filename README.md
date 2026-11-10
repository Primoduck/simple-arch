# Simple Arch Installer

This is a bash script to automate the Arch Linux installation process. It handles the initial partitioning, Btrfs subvolume configuration, the base system installation, and the setup of a desktop environment.

>[!CAUTION]
> Please read this before running the script:
>*   **Data Loss:** This script will completely wipe the drive you select. There is no way to undo this.
>*   **Hardware Specificity:** I wrote this script for my specific hardware. Because of how it detects components and handles certain paths, it might not work correctly on your machine. Use it at your own risk.
>*   **Live Environment:** This script is intended to be run from the Arch Linux Live ISO.

## Features

*   **Automated Partitioning:** Creates a GPT partition table with an EFI System Partition and a Btrfs root partition.
*   **Btrfs Configuration:** Sets up @ and @home subvolumes with zstd compression.
*   **Interactive Setup:** Asks for your timezone, locale, hostname, and user account details during the process.
*   **Package Selection:** Gives you the option to include essential tools, AMD GPU drivers, PipeWire audio, and either KDE Plasma or Hyprland.
*   **Bootloader:** Automates the GRUB installation and configuration for UEFI.
*   **Sanity Checks:** Before finishing, the script checks that the mounts are correct and the fstab is valid to prevent boot issues.

## Requirements

*   An Arch Linux Live ISO.
*   UEFI firmware.

## How to use

Inside the Arch Install ISO:

1.  Download the script:
    ```sh
    curl -O https://github.com/yourusername/yourrepo/raw/main/simple-arch.sh
    ```

2.  Make the script executable:
    ```sh
    chmod +x simple-arch.sh
    ```

3.  Run the script:
    ```sh
    ./simple-arch.sh
    ```

## Technical Flow

1.  **Environment Check:** Confirms you are in the correct environment, have UEFI enabled, and can reach the internet.
2.  **Configuration:** Collects your preferences for the new system.
3.  **Disk Preparation:** Identifies your drive, wipes the old partition table, and sets up the Btrfs structure.
4.  **Base Installation:** Uses pacstrap to install the kernel and your selected packages.
5.  **System Configuration:** Enters the chroot to set the clock, locales, hostname, and user permissions.
6.  **Bootloader:** Installs GRUB to the EFI partition.
7.  **Finalization:** Performs a final check of the filesystem and offers to reboot.
