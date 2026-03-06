
<center>
 <img src='logo.png' width='50%' />
</center>

---

Insert the USB into any machine, boot from it, and walk away.  

## What It Does

| Step | Description |
|------|-------------|
| 1 | Boots the Ubuntu Server installer from USB |
| 2 | Autoinstall partitions the disk, creates a `dev` user, installs packages |
| 3 | All packages come from a **local APT repository on the USB** — no network needed |
| 4 | A **bootstrap script** configures Docker, SSH, Git, shell aliases, and more |
| 5 | Machine reboots into a ready-to-use system |

One USB drive can install as many machines as you want.

---

## Repository Structure

```
LocalBooth/
├── README.md
├── Dockerfile                   # Ubuntu 24.04 build environment
├── .gitignore
├── build/
│   ├── make-usb.sh              # One command: build ISO + flash USB (uses Docker)
│   ├── flash-usb.sh             # Flash an ISO to USB (macOS & Linux)
│   ├── build-iso-in-docker.sh   # Runs inside the Docker container
│   └── build-usb.sh             # Native Linux build (no Docker)
├── autoinstall/
│   ├── user-data                # cloud-init autoinstall config
│   └── meta-data                # (empty, required by cloud-init)
├── bootstrap/
│   └── bootstrap.sh             # Post-install provisioning
├── packages/
│   └── download-packages.sh     # Download .deb packages + deps
├── repo/
│   └── create-local-repo.sh     # Build local APT repository
├── iso/
│   └── customize-iso.sh         # Extract & inject into ISO
├── config/
│   └── package-list.txt         # Packages to include
└── extras/                      # (optional) kubectl, etc.
```

---

## Prerequisites

- **Docker Desktop** — the only requirement on macOS / Windows / Linux.
- An internet connection (to download the Ubuntu ISO and packages during build).
- A USB drive (8 GB minimum).

No need for a Linux machine — everything runs inside a Docker container.

---

## Quick Start (Docker — recommended)

### 1. Clone the repository

```bash
git clone <repo-url> LocalBooth && cd LocalBooth
```

### 2. Plug in your USB and run one command

```bash
./build/make-usb.sh
```

That's it. The script will:

1. Build a Docker image with all required Ubuntu tools
2. Run the full build pipeline inside the container (download ISO, download packages, build offline APT repo, customize ISO)
3. Show your connected disks and ask which one is the USB
4. Flash the ISO to the USB (with safety checks)

The first run downloads the Ubuntu ISO (~2.6 GB) and all packages. Subsequent runs reuse the cached ISO.

### 3. Build only (don't flash)

```bash
./build/make-usb.sh --no-flash
```

The ISO will be at `output/localbooth-ubuntu-24.04.1.iso`. Flash it later with:

```bash
./build/flash-usb.sh output/localbooth-ubuntu-24.04.1.iso
```

### 4. Boot & install

Plug the USB into the target machine, boot from USB, and wait.  
The system installs itself with zero interaction.

**Default credentials:** `dev` / `changeme`

---

## Quick Start (Native Linux — no Docker)

If you're already on Ubuntu 24.04, you can skip Docker and build directly:

```bash
sudo ./build/build-usb.sh
```

Then flash:

```bash
sudo dd if=localbooth-ubuntu-24.04.1.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## Step-by-Step (Manual)

If you prefer to run each stage individually:

### Download packages

```bash
sudo ./packages/download-packages.sh
```

Downloads every `.deb` in `config/package-list.txt` and its full dependency tree into `packages/debs/`.

### Build the local APT repository

```bash
sudo ./repo/create-local-repo.sh
```

Creates a Packages/Release index in `repo/local-repo/` from the downloaded `.deb` files.

### Customize the ISO

```bash
sudo ./iso/customize-iso.sh iso/ubuntu-server.iso
```

Extracts the ISO, injects autoinstall configs, the local repo, the bootstrap script, and patches GRUB.

### Rebuild the ISO

The master `build/build-usb.sh` handles rebuilding. If you want to rebuild manually after making changes to the extracted tree:

```bash
xorriso -as mkisofs \
    -r -V "LocalBooth" \
    -o localbooth-custom.iso \
    --grub2-mbr iso/mbr.bin \
    -partition_offset 16 \
    --mbr-force-bootable \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b iso/extracted/boot/grub/efi.img \
    -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot.catalog' \
    -b '/boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
    -no-emul-boot \
    iso/extracted
```

---

## Customization

### Change installed packages

Edit `config/package-list.txt` — one package per line, comments start with `#`.

Then rebuild:

```bash
sudo ./packages/download-packages.sh
sudo ./repo/create-local-repo.sh
sudo ./build/build-usb.sh --iso iso/ubuntu-server.iso
```

### Change the default user or password

Edit `autoinstall/user-data`. Generate a new password hash:

```bash
openssl passwd -6 "your-new-password"
```

Replace the `password:` field in the `identity` section.

### Change the hostname

Edit the `hostname:` field in `autoinstall/user-data`.

### Add kubectl or other binaries

Place binaries in an `extras/` directory at the repository root:

```bash
mkdir -p extras
curl -Lo extras/kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x extras/kubectl
```

The bootstrap script will detect and install them automatically.

### Modify post-install setup

Edit `bootstrap/bootstrap.sh` to add or remove provisioning steps.

---

## Offline Architecture

```
USB Drive (ISO)
├── autoinstall/
│   ├── user-data          ← autoinstall config
│   └── meta-data
├── repo/
│   ├── *.deb              ← all packages + dependencies
│   ├── Packages.gz        ← APT index
│   └── Release
├── bootstrap/
│   └── bootstrap.sh       ← runs inside installed system
└── (standard Ubuntu installer files)
```

The autoinstall `user-data` configures APT to use:

```
deb [trusted=yes] file:///cdrom/repo ./
```

This tells the installer to pull all packages from the USB drive instead of the internet.

---

## Installed Software

| Package | Purpose |
|---------|---------|
| `docker.io` | Container runtime |
| `git` | Version control |
| `curl` | HTTP client |
| `build-essential` | GCC, make, libc headers |
| `jq` | JSON processor |
| `unzip` | Archive extraction |
| `htop` | Process monitor |
| `ca-certificates` | TLS root certificates |
| `gnupg` | GPG encryption |
| `openssh-server` | SSH access |

## Bootstrap Provisioning

The bootstrap script (`bootstrap/bootstrap.sh`) runs at the end of installation and:

- Adds `dev` to the `docker` group
- Enables SSH and Docker services
- Creates `~/workspace`
- Configures Git defaults (default branch `main`, rebase on pull, color UI)
- Installs developer shell aliases (`ll`, `gs`, `gd`, `gl`, `dc`, `dps`, `k`, etc.)
- Installs `kubectl` if found in `extras/`

---

## Troubleshooting

### Install hangs at "waiting for network"

The autoinstall config disables network during installation. If you see a timeout, ensure the GRUB line includes `autoinstall ds=nocloud;s=/cdrom/autoinstall/`.

### Packages fail to install

Ensure you built the offline repo on the **same Ubuntu release** as the target. Package dependencies are release-specific.

### GRUB not patched correctly

Inspect `iso/extracted/boot/grub/grub.cfg` after running `customize-iso.sh`. The kernel command line should contain `autoinstall ds=nocloud\;s=/cdrom/autoinstall/`.

### Bootstrap script errors

Check `/var/log/localbooth-bootstrap.log` on the installed system.

---

## License

MIT
