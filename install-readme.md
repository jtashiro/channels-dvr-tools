# How-To: Install and Prepare an Ubuntu Media Server

This guide walks you through installing Ubuntu Server, creating a dedicated media user, enabling .local network discovery, and preparing your system for automated media server setup scripts (e.g., Docker containers for Transmission, Sonarr, Radarr, Jackett, and post-install scripts).

---

## Prerequisites
- Computer or VM with at least 2GB RAM, 20GB storage, and internet access
- USB drive (≥4GB) for installation media
- Basic command-line familiarity

---

### Step 1: Install Ubuntu Server

### a. Download Ubuntu ISO
- Go to: [ubuntu.com/download/server](https://ubuntu.com/download/server)
- Download the latest LTS version (e.g., Ubuntu 24.04 LTS Server)

### b. Create Bootable USB
- Insert your USB drive
- On **Windows**: Use [Rufus](https://rufus.ie/)
- On **Linux/macOS**:
  ```bash
  sudo dd if=/path/to/ubuntu.iso of=/dev/sdX bs=4M status=progress && sync
  # Replace /path/to/ubuntu.iso and /dev/sdX (use lsblk to find your USB device)
  ```

### c. Boot and Install
- Boot from the USB (set in BIOS/UEFI)
- Follow installer prompts:
  - Choose language, keyboard
  - "Install Ubuntu Server"
  - Configure network (DHCP is fine for most)
  - Use entire disk (guided install)
  - Create an **admin** user (not your media user)
  - Enable OpenSSH server (recommended)
  - Skip snaps unless needed
- Complete install, reboot, and remove USB

### d. Update System
```bash
sudo apt update && sudo apt upgrade -y
sudo reboot
```

---

### Step 2: Create a Dedicated Media User

For security, run media services as a non-root user.

```bash
sudo adduser media
# Set a strong password when prompted
```
- (Optional) Add to sudo group:
  ```bash
  sudo usermod -aG sudo media
  ```
- Add to docker group (if using Docker):
  ```bash
  sudo usermod -aG docker media
  ```
- Test login:
  ```bash
  su - media
  exit
  ```

---


### Step 3: Prepare for Automated Setup

Your install script will automatically:
- Install avahi-daemon, cifs-utils, mergerfs
- Set your system timezone
- Enable avahi-daemon for .local hostnames

No manual package installation is required.



---





---


After install, test .local hostname resolution from another machine:
```bash
ping $(hostname).local
```

---

### Step 4 (Optional): Install Docker
If your install script sets up Docker, you may need to install it first:
```bash
sudo apt install docker.io docker-compose -y
sudo systemctl enable --now docker
sudo usermod -aG docker media
```

---


### Step 5: Run Your Install and Post-Install Scripts

- Copy your install script and post_install script (e.g., for Docker containers) to the server
- Run as the media user:
  ```bash
  ./install_dvr_stack.sh
  ```
- Once containers are running (Jackett, Sonarr, Radarr, Transmission), configure the Indexer in Jackett
- After configuring one indexer, run the post-install script:
  ```bash
  bash ~/post_install_links.sh
  ```
  This will link indexers, configure Transmission, and set up remote path mappings automatically.

---

## Troubleshooting
- If `avahi-daemon` fails: `sudo ufw allow mdns`
- For SSH: ensure port 22 is open
- For Docker: check volumes and permissions for media directories
- Always back up important data before making changes
- Check logs: `journalctl -u avahi-daemon`
- For more help: Ubuntu forums and documentation

---

This setup provides a secure, discoverable base for your media server. After these steps, your system is ready for automated media management!
