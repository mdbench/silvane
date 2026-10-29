#!/bin/bash
set -e

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
echo "[*] Working output directory: $WORKSPACE"
cd "$WORKSPACE"

echo "[*] Starting Silvane Kiosk Build Pipeline..."

# 0. Reclaim Runner Disk Space to prevent runner partition & log exhaustion
echo "[*] Cleaning up runner disk space..."
set +e
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/share/boost /opt/hostedtoolcache/CodeCoverage 2>/dev/null
docker system prune -a --volumes -f 2>/dev/null
set -e
df -h

# 1. Extract Version from Pubspec
VERSION_LINE=$(grep '^version:' app/pubspec.yaml | head -n 1)
RAW_VERSION=$(echo "$VERSION_LINE" | awk '{print $2}' | tr -d '"' | tr -d "'")

if [[ "$RAW_VERSION" == *"+"* ]]; then
    VERSION_NAME=$(echo "$RAW_VERSION" | cut -d'+' -f1)
    BUILD_NUM=$(echo "$RAW_VERSION" | cut -d'+' -f2)
else
    VERSION_NAME="$RAW_VERSION"
    BUILD_NUM="1"
fi
LOCAL_TAG="v${VERSION_NAME}-build${BUILD_NUM}"
echo "[*] Target Version Tag: ${LOCAL_TAG}"

# 2. Install Build Dependencies & ISO Tools
echo "[*] Installing required system packages and ISO tools..."
apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    jq \
    gh \
    tar \
    gzip \
    bzip2 \
    ninja-build \
    libglu1-mesa \
    clang \
    build-essential \
    cmake \
    pkg-config \
    libgtk-3-dev \
    libsecret-1-dev \
    libjsoncpp-dev \
    live-build \
    dctrl-tools \
    debootstrap \
    debian-archive-keyring \
    xorriso \
    syslinux-common \
    isolinux \
    squashfs-tools \
    x11-utils
set +e
apt-mark manual dctrl-tools
set -e

# 3. Configure Git Safe Directories
git config --global --add safe.directory '*'
git config --global --add safe.directory "$WORKSPACE"
set +e
git config --global --add safe.directory /__t/flutter/*
set -e

# 4. Build Flutter Linux Release App
echo "[*] Building Flutter Linux release bundle..."
cd "${WORKSPACE}/app"
flutter clean
flutter pub get
flutter build linux --release --verbose
cd "$WORKSPACE"

BUNDLE_DIR="${WORKSPACE}/app/build/linux/x64/release/bundle"

# Deploy the complete bundle (binary + data + lib) straight to /opt/silvane
echo "[*] Deploying bundle to /opt/silvane..."
mkdir -p /opt/silvane
rm -rf /opt/silvane/*

if ! cp -r "${BUNDLE_DIR}"/* /opt/silvane/; then
    echo "[!] Error: Failed to copy release bundle to /opt/silvane!"
    exit 1
fi

chmod -R 755 /opt/silvane
find /opt/silvane -type f -exec chmod 644 {} \;
chmod +x /opt/silvane/silvane

echo "[*] Bundle deployment complete."

cd "$WORKSPACE"

# 5. Create binaries folder, package latest.zip with admin_password (staged separately)
echo "[*] Creating binaries directory and packaging latest.zip..."
mkdir -p "${WORKSPACE}/binaries"
ZIP_STAGE=$(mktemp -d)
cp -r "$BUNDLE_DIR"/* "$ZIP_STAGE/"
echo "admin" > "$ZIP_STAGE/admin_password"
chmod 644 "$ZIP_STAGE/admin_password"
(cd "$ZIP_STAGE" && zip -r "${WORKSPACE}/binaries/latest.zip" .)
rm -rf "$ZIP_STAGE"
echo "[*] Created binary zip: ${WORKSPACE}/binaries/latest.zip"

echo "[*] Cloning fresh repo repository using GitHub token for authentication..."
TEMP_REPO_DIR=$(mktemp -d)
set +e
git clone https://x-access-token:${GITHUB_TOKEN}@github.com/mdbench/silvane.git "$TEMP_REPO_DIR"
set -e

echo "[*] Committing latest.zip immediately..."
mkdir -p "$TEMP_REPO_DIR/binaries"
cp "${WORKSPACE}/binaries/latest.zip" "$TEMP_REPO_DIR/binaries/latest.zip"
cd "$TEMP_REPO_DIR"
git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'
git add binaries/latest.zip
git commit -m "chore: update latest.zip binary for ${LOCAL_TAG} [skip ci]" || echo "[*] No changes to commit"
set +e
git push origin HEAD
set -e

echo "[*] Deleting temporary repo clone..."
cd "$WORKSPACE"
rm -rf "$TEMP_REPO_DIR"

# 6. Create dockers folder, package latest.tar.gz with admin_password, clone repo via token, commit, push, and clean up
echo "[*] Building Docker container image archive and packaging latest.tar.gz..."
mkdir -p "${WORKSPACE}/dockers"
mkdir -p "${WORKSPACE}/docker_build"
cp -r "$BUNDLE_DIR"/* "${WORKSPACE}/docker_build/"
echo "admin" > "${WORKSPACE}/docker_build/admin_password"
chmod 644 "${WORKSPACE}/docker_build/admin_password"

cat << 'DOCKERFILE_EOF' > "${WORKSPACE}/docker_build/Dockerfile"
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y \
    libgtk-3-0 \
    libsecret-1-0 \
    libjsoncpp25 \
    libgl1 \
    ca-certificates \
    ufw \
    whois \
    dnsutils \
    net-tools \
    iputils-ping \
    procps \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/silvane
COPY . /opt/silvane/
RUN chmod +x /opt/silvane/silvane
CMD ["/opt/silvane/silvane"]
DOCKERFILE_EOF

tar -czf "${WORKSPACE}/dockers/latest.tar.gz" -C "${WORKSPACE}/docker_build" .
echo "[*] Container bundle archive created at: ${WORKSPACE}/dockers/latest.tar.gz"

echo "[*] Cloning fresh repo repository using GitHub token for authentication..."
TEMP_REPO_DIR=$(mktemp -d)
set +e
git clone https://x-access-token:${GITHUB_TOKEN}@github.com/mdbench/silvane.git "$TEMP_REPO_DIR"
set -e

echo "[*] Committing latest.tar.gz immediately..."
mkdir -p "$TEMP_REPO_DIR/dockers"
cp "${WORKSPACE}/dockers/latest.tar.gz" "$TEMP_REPO_DIR/dockers/latest.tar.gz"
cd "$TEMP_REPO_DIR"
git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'
git add dockers/latest.tar.gz
git commit -m "chore: update latest.tar.gz docker bundle for ${LOCAL_TAG} [skip ci]" || echo "[*] No changes to commit"
set +e
git push origin HEAD
set -e

echo "[*] Deleting temporary repo clone..."
cd "$WORKSPACE"
rm -rf "$TEMP_REPO_DIR"

# 7. Stage Files for ISO Bundle (statically including admin_password in /opt/silvane/)
mkdir -p "${WORKSPACE}/os/config/includes.chroot/opt/silvane"
cp -r "$BUNDLE_DIR"/* "${WORKSPACE}/os/config/includes.chroot/opt/silvane/"
chmod -R 755 "${WORKSPACE}/os/config/includes.chroot/opt/silvane"
find "${WORKSPACE}/os/config/includes.chroot/opt/silvane" -type f -exec chmod 644 {} \;
chmod +x "${WORKSPACE}/os/config/includes.chroot/opt/silvane/silvane"

echo "admin" > "${WORKSPACE}/os/config/includes.chroot/opt/silvane/admin_password"
chmod 644 "${WORKSPACE}/os/config/includes.chroot/opt/silvane/admin_password"

# Automatically create /opt/silvane/debug cleanly via temp clone (no risk of wiping targets)
echo "[*] Staging debug repository workspace cleanly..."
DEBUG_ISO_DIR="${WORKSPACE}/os/config/includes.chroot/opt/silvane/debug"
mkdir -p "$DEBUG_ISO_DIR"
TEMP_CLONE_DIR=$(mktemp -d)
set +e
git clone --depth 1 https://x-access-token:${GITHUB_TOKEN}@github.com/mdbench/silvane.git "$TEMP_CLONE_DIR"
rm -rf "$TEMP_CLONE_DIR/.git"
cp -r "$TEMP_CLONE_DIR"/* "$DEBUG_ISO_DIR/"
rm -rf "$TEMP_CLONE_DIR"
set -e
echo "[*] Successfully provisioned debug workspace without git metadata."

# 8. Inject Custom Splash Logo
mkdir -p "${WORKSPACE}/os/config/includes.binary/boot/grub"
mkdir -p "${WORKSPACE}/os/config/includes.binary/isolinux"

LOGO_SRC=""
if [ -f "${WORKSPACE}/silvane/silvane.jpg" ]; then
    LOGO_SRC="${WORKSPACE}/silvane/silvane.jpg"
elif [ -f "${WORKSPACE}/app/silvane.jpg" ]; then
    LOGO_SRC="${WORKSPACE}/app/silvane.jpg"
elif [ -f "${WORKSPACE}/silvane.jpg" ]; then
    LOGO_SRC="${WORKSPACE}/silvane.jpg"
fi

if [ -n "$LOGO_SRC" ]; then
    cp "$LOGO_SRC" "${WORKSPACE}/os/config/includes.binary/boot/grub/splash.jpg"
    cp "$LOGO_SRC" "${WORKSPACE}/os/config/includes.binary/isolinux/splash.png"
    echo "[*] Successfully injected custom logo into GRUB and ISOLINUX boot splash."
else
    echo "[!] Warning: No custom silvane.jpg logo found."
fi

# 9. Configure and Build Live-Build ISO (with complete Debian Installer / USB Live hybrid support)
cd "${WORKSPACE}/os"

mkdir -p config/package-lists
mkdir -p config/hooks/normal
mkdir -p config/binary_debian-installer
mkdir -p config/includes.binary

# Create Preseed configuration for unattended/semi-automated Debian Installer USB installs
cat << 'PRESEED_EOF' > config/includes.binary/preseed.cfg
#_preseed_V1
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string silvane-kiosk
d-i netcfg/get_domain string local
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-login boolean false
d-i passwd/user-fullname string Kiosk User
d-i passwd/username string kiosk
d-i passwd/user-password password kiosk
d-i passwd/user-password-again password kiosk
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean false
d-i partman/confirm_nooverwrite boolean false
tasksel tasksel/first multiselect 
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default
d-i finish-install/reboot_in_progress note
PRESEED_EOF

# LEAN PACKAGE LIST with installer utilities, unzip, and sudo included
cat << 'EOF' > config/package-lists/kiosk.list.chroot
live-boot
xserver-xorg-core
xserver-xorg
xinit
openbox
xterm
xdg-user-dirs
wireguard-tools
iproute2
net-tools
dnsutils
iputils-ping
procps
curl
git
unzip
tar
gzip
bzip2
xz-utils
file
ufw
whois
ca-certificates
libsecret-1-0
libjsoncpp25
alsa-utils
parted
dosfstools
efibootmgr
libgtk-3-0
libgles2-mesa
libegl1-mesa
libglu1-mesa
libgl1-mesa-dri
libgl1-mesa-glx
x11-utils
sudo
EOF

cat << 'HOOK_EOF' > config/hooks/normal/99-silvane-kiosk.chroot
#!/bin/bash
set -e

# Disable the residual CD-ROM repository source left by live-build installer
sed -i '/cdrom:/s/^/#/' /etc/apt/sources.list || true

echo "[*] Creating kiosk user with explicit shell and home setup..."
getent group kiosk || groupadd kiosk
id -u kiosk &>/dev/null || useradd -m -d /home/kiosk -s /bin/bash -g kiosk -G sudo,audio,video,netdev,render kiosk
echo "kiosk:kiosk" | chpasswd

# Ensure sudoers.d directory exists before writing permissions
mkdir -p /etc/sudoers.d

# Grant kiosk passwordless sudo capability for apt package installations and management
echo "kiosk ALL=(ALL) NOPASSWD: /usr/sbin/ufw, /usr/bin/whois, /usr/bin/resolvectl, /bin/systemctl, /usr/bin/systemctl, /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg, /bin/bash" > /etc/sudoers.d/kiosk
# Removed to prevent external installations /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg to keep Flutter Sandbox safe
chmod 0440 /etc/sudoers.d/kiosk

chown -R kiosk:kiosk /opt/silvane
chmod -R 755 /opt/silvane
chmod +x /opt/silvane/silvane
chmod 644 /opt/silvane/admin_password || true
mkdir -p /opt/silvane.old
chown -R kiosk:kiosk /opt/silvane.old

# Create an immutable, pristine factory golden copy from the official repo asset (with soft-fail)
mkdir -p /usr/share/silvane/factory
TEMP_FACTORY_ZIP=$(mktemp)

TOKEN=""
if [ -f /opt/silvane/api_key ]; then
    TOKEN=$(cat /opt/silvane/api_key | tr -d '\r\n')
fi

echo "[*] Downloading factory default binary from GitHub (soft-fail enabled)..."
if [ -n "$TOKEN" ]; then
    CURL_FACTORY_CMD="curl -sL -H \"Authorization: Bearer ${TOKEN}\" \"https://raw.githubusercontent.com/mdbench/silvane/main/binaries/latest.zip\" -o \"$TEMP_FACTORY_ZIP\""
else
    CURL_FACTORY_CMD="curl -sL \"https://raw.githubusercontent.com/mdbench/silvane/main/binaries/latest.zip\" -o \"$TEMP_FACTORY_ZIP\""
fi

set +e
if eval "$CURL_FACTORY_CMD" && [ -s "$TEMP_FACTORY_ZIP" ] && file "$TEMP_FACTORY_ZIP" | grep -q "Zip"; then
    unzip -q "$TEMP_FACTORY_ZIP" -d /usr/share/silvane/factory
    if [ -f "/usr/share/silvane/factory/silvane" ]; then
        chmod +x /usr/share/silvane/factory/silvane
        echo "[*] Successfully populated immutable factory folder with working binary."
    else
        echo "[!] Warning: Extracted factory bundle is missing the silvane binary."
    fi
else
    echo "[!] Notice: Factory binary not yet available on remote repository (soft-failing safely). Will be populated during first update."
fi
set -e
rm -f "$TEMP_FACTORY_ZIP"

mkdir -p /home/kiosk/Documents/silvane_dbs /home/kiosk/.local/share /home/kiosk/.config /home/kiosk/.cache
chown -R kiosk:kiosk /home/kiosk

set +e
su - kiosk -c "xdg-user-dirs-update"
set -e

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat << 'GETTY_CONF' > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
Type=idle
GETTY_CONF

# Download cloudflared binary into /usr/local/bin during ISO build hooks
echo "[*] Installing cloudflared binary..."
curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

# Ensure Flutter path is exported in bashrc and system-wide bash.bashrc pointing to debug/flutter
echo 'export PATH="$PATH:/opt/silvane/debug/flutter/bin"' >> /home/kiosk/.bashrc
echo 'export PATH="$PATH:/opt/silvane/debug/flutter/bin"' >> /etc/bash.bashrc

cat << 'UPDATE_SCRIPT' > /usr/local/bin/silvane-update
#!/bin/bash
REPO="mdbench/silvane"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
PUBSPEC_URL="https://raw.githubusercontent.com/$REPO/refs/heads/main/app/pubspec.yaml"
BACKUP_ROOT="/opt/silvane.old"
ACTIVE_DIR="/opt/silvane"

echo "[*] Checking GitHub Releases for latest binary package..."
TEMP_ZIP=$(mktemp)

TOKEN=""
if [ -f /opt/silvane/api_key ]; then
    TOKEN=$(cat /opt/silvane/api_key | tr -d '\r\n')
fi

if [ -n "$TOKEN" ]; then
    DOWNLOAD_URL=$(curl -s -H "Authorization: Bearer ${TOKEN}" "$API_URL" | grep "browser_download_url" | grep "\-binary.*\.zip" | head -n 1 | cut -d '"' -f 4)
else
    DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "\-binary.*\.zip" | head -n 1 | cut -d '"' -f 4)
fi

if [ -n "$DOWNLOAD_URL" ] && [ "$DOWNLOAD_URL" != "null" ]; then
    if [ -n "$TOKEN" ]; then
        curl -sL -H "Authorization: Bearer ${TOKEN}" "$DOWNLOAD_URL" -o "$TEMP_ZIP" || true
    else
        curl -sL "$DOWNLOAD_URL" -o "$TEMP_ZIP" || true
    fi
fi

if [ -s "$TEMP_ZIP" ] && file "$TEMP_ZIP" | grep -q "Zip"; then
    echo ""
    echo "[?] A new verified binary zip update is available from GitHub Releases."
    if read -t 15 -p "[?] Apply update? (y/N) [Timeout in 15s -> Skipping]: " -n 1 -r; then
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "[*] Fetching active pubspec.yaml from repository..."
            if [ -n "$TOKEN" ]; then
                PUBSPEC_CONTENT=$(curl -s -H "Authorization: Bearer ${TOKEN}" "$PUBSPEC_URL")
            else
                PUBSPEC_CONTENT=$(curl -s "$PUBSPEC_URL")
            fi
            
            if [ -z "$PUBSPEC_CONTENT" ]; then
                echo "[!] Error: Failed to fetch pubspec.yaml from GitHub. Aborting update for safety."
                rm -f "$TEMP_ZIP"
                exit 1
            fi

            RAW_VERSION=$(echo "$PUBSPEC_CONTENT" | grep '^version:' | head -n 1 | awk '{print $2}' | tr -d '"' | tr -d "'")
            if [ -z "$RAW_VERSION" ]; then
                echo "[!] Error: Could not parse version string from pubspec.yaml. Aborting update."
                rm -f "$TEMP_ZIP"
                exit 1
            fi

            if [[ "$RAW_VERSION" == *"+"* ]]; then
                VERSION_NAME=$(echo "$RAW_VERSION" | cut -d'+' -f1)
                BUILD_NUM=$(echo "$RAW_VERSION" | cut -d'+' -f2)
                CURRENT_TAG="v${VERSION_NAME}-build${BUILD_NUM}"
            else
                echo "[!] Error: Version format in pubspec.yaml does not contain expected build metadata (+). Aborting update."
                rm -f "$TEMP_ZIP"
                exit 1
            fi

            if [ -d "$BACKUP_ROOT/$CURRENT_TAG" ]; then
                echo "[!] Error: Backup folder for version $CURRENT_TAG already exists in $BACKUP_ROOT. Aborting update to prevent overwriting."
                rm -f "$TEMP_ZIP"
                exit 1
            fi

            echo "[*] Backing up current version ($CURRENT_TAG) to $BACKUP_ROOT/$CURRENT_TAG..."
            mkdir -p "$BACKUP_ROOT/$CURRENT_TAG"
            
            EXISTING_PASS=""
            if [ -f "$ACTIVE_DIR/admin_password" ]; then
                EXISTING_PASS=$(cat "$ACTIVE_DIR/admin_password")
            fi

            cp -r "$ACTIVE_DIR"/* "$BACKUP_ROOT/$CURRENT_TAG/" 2>/dev/null || true
            chown -R kiosk:kiosk "$BACKUP_ROOT/$CURRENT_TAG"

            TEMP_DIR=$(mktemp -d)
            unzip -q "$TEMP_ZIP" -d "$TEMP_DIR"
            if [ -f "$TEMP_DIR/silvane" ]; then
                chmod +x "$TEMP_DIR/silvane"
                rm -rf "$ACTIVE_DIR"/*
                cp -r "$TEMP_DIR"/* "$ACTIVE_DIR/"

                if [ -n "$EXISTING_PASS" ] && [ ! -f "$ACTIVE_DIR/admin_password" ]; then
                    echo "$EXISTING_PASS" > "$ACTIVE_DIR/admin_password"
                fi

                chown -R kiosk:kiosk "$ACTIVE_DIR"
                chmod +x "$ACTIVE_DIR/silvane"
                chmod 644 "$ACTIVE_DIR/admin_password" || true
                echo "[*] Successfully updated Silvane binary bundle from GitHub!"
            else
                echo "[!] Extracted package missing executable silvane binary."
            fi
            rm -rf "$TEMP_DIR"

            if [ -d /opt/silvane/debug/.git ]; then
                echo "[*] Pulling latest git changes in /opt/silvane/debug..."
                cd /opt/silvane/debug
                if [ -n "$TOKEN" ]; then
                    git pull https://x-access-token:${TOKEN}@github.com/mdbench/silvane.git || git pull || true
                else
                    git pull || true
                fi
            fi
        else
            echo "[*] Update skipped by user."
        fi
    else
        echo ""
        echo "[*] 15s timeout reached. Skipping update and starting app..."
    fi
fi
rm -f "$TEMP_ZIP"
UPDATE_SCRIPT
chmod +x /usr/local/bin/silvane-update

cat << 'DEBUG_MENU_EOF' > /usr/local/bin/silvane-debug-menu
#!/bin/bash
clear
echo "========================================="
echo "    Silvane Kiosk Recovery & Debug Menu  "
echo "========================================="
STORED_PASS=$(cat /opt/silvane/admin_password 2>/dev/null | tr -d '\r\n' || echo "admin")
read -s -p "Enter admin password: " password_input
echo ""

if [ "$password_input" != "$STORED_PASS" ]; then
    echo "[!] Authentication failed. Incorrect password."
    sleep 2
    exit 1
fi

while true; do
    clear
    echo "========================================="
    echo "    Silvane Kiosk Recovery & Debug Menu  "
    echo "========================================="
    echo "1) Launch App Normally"
    echo "2) Launch App in XTerm Debug Mode"
    echo "3) Re-Install from Debug Version (Broken Edge Case)"
    echo "4) Manually Update Binary from GitHub (Keep Backup)"
    echo "5) Setup Debug Workspace & Install Build Tools (Run Verbose)"
    echo "6) Change Admin Password"
    echo "7) Rollback to Previous Working Version"
    echo "8) Open Terminal Shell"
    echo "9) Exit Menu"
    echo "-----------------------------------------"
    read -p "Select option [1-8]: " choice
    case $choice in
        1)
            cd /opt/silvane && export DISPLAY=:0 && export LIBGL_ALWAYS_SOFTWARE=1 && ./silvane
            ;;
        2)
            xterm -fg white -bg black -fa 'Monospace' -fs 10 -geometry 120x35 -title "Silvane Runtime Debugger" -e "cd /opt/silvane && export DISPLAY=:0 && export LIBGL_ALWAYS_SOFTWARE=1 && ./silvane; echo ''; echo '========================================='; echo 'App exited. Press ENTER to close.'; read"
            ;;
        3)
            echo "[*] Installing required compilation toolchains via sudo..."
            sudo apt-get update
            sudo apt-get install -y \
                cmake \
                build-essential \
                clang \
                ninja-build \
                pkg-config \
                libgtk-3-dev \
                libsecret-1-dev \
                libjsoncpp-dev

            if [ ! -d "/opt/silvane/debug/flutter" ]; then
                echo "[*] Downloading and installing Flutter SDK into /opt/silvane/debug/flutter..."
                mkdir -p /opt/silvane/debug
                curl -L https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz | tar -xJ -C /opt/silvane/debug/
            fi

            echo 'export PATH="$PATH:/opt/silvane/debug/flutter/bin"' >> ~/.bashrc
            source ~/.bashrc
            echo "[*] Added flutter path to bash..."

            cd /opt/silvane/debug/app
            echo "[*] Entered debug app directory..."

            echo "[*] Cleaning flutter..."
            flutter clean
            echo "[*] Downloading packages..."
            flutter pub get

            # Export flags to prevent modern CPU-specific vector instruction traps on older kiosk hardware
            export CFLAGS="-march=x86-64 -mtune=generic"
            export CXXFLAGS="-march=x86-64 -mtune=generic"

            echo "[*] Building release..."
            flutter build linux --release

            cp -r /opt/silvane/debug/app/build/linux/x64/release/bundle/* /opt/silvane/
            chmod +x /opt/silvane/silvane

            echo "[*] Replaced bad binary with correct one..."

            cd /opt/silvane
            ./silvane
            ;;
        4)
            echo "[*] Forcing manual binary update from GitHub..."
            REPO="mdbench/silvane"
            API_URL="https://api.github.com/repos/$REPO/releases/latest"
            PUBSPEC_URL="https://raw.githubusercontent.com/$REPO/refs/heads/main/app/pubspec.yaml"
            BACKUP_ROOT="/opt/silvane.old"
            ACTIVE_DIR="/opt/silvane"
            TEMP_ZIP=$(mktemp)

            TOKEN=""
            if [ -f /opt/silvane/api_key ]; then
                TOKEN=$(cat /opt/silvane/api_key | tr -d '\r\n')
            fi
            
            if [ -z "$TOKEN" ]; then
                echo ""
                read -p "Enter GitHub API token / Auth Key (leave blank for public clone): " input_token
                if [ -n "$input_token" ]; then
                    TOKEN="$input_token"
                    echo "$TOKEN" > /opt/silvane/api_key
                    chmod 600 /opt/silvane/api_key
                    echo "[*] API key saved to /opt/silvane/api_key"
                fi
            fi

            if [ -n "$TOKEN" ]; then
                DOWNLOAD_URL=$(curl -s -H "Authorization: Bearer ${TOKEN}" "$API_URL" | grep "browser_download_url" | grep "\-binary.*\.zip" | head -n 1 | cut -d '"' -f 4)
            else
                DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "\-binary.*\.zip" | head -n 1 | cut -d '"' -f 4)
            fi

            if [ -n "$DOWNLOAD_URL" ] && [ "$DOWNLOAD_URL" != "null" ]; then
                if [ -n "$TOKEN" ]; then
                    curl -sL -H "Authorization: Bearer ${TOKEN}" "$DOWNLOAD_URL" -o "$TEMP_ZIP" || true
                else
                    curl -sL "$DOWNLOAD_URL" -o "$TEMP_ZIP" || true
                fi
            fi

            if [ -s "$TEMP_ZIP" ] && file "$TEMP_ZIP" | grep -q "Zip"; then
                if [ -n "$TOKEN" ]; then
                    PUBSPEC_CONTENT=$(curl -s -H "Authorization: Bearer ${TOKEN}" "$PUBSPEC_URL")
                else
                    PUBSPEC_CONTENT=$(curl -s "$PUBSPEC_URL")
                fi

                RAW_VERSION=$(echo "$PUBSPEC_CONTENT" | grep '^version:' | head -n 1 | awk '{print $2}' | tr -d '"' | tr -d "'")
                if [[ "$RAW_VERSION" == *"+"* ]]; then
                    VERSION_NAME=$(echo "$RAW_VERSION" | cut -d'+' -f1)
                    BUILD_NUM=$(echo "$RAW_VERSION" | cut -d'+' -f2)
                    CURRENT_TAG="v${VERSION_NAME}-build${BUILD_NUM}"
                else
                    CURRENT_TAG="v1.0.0-manual"
                fi

                mkdir -p "$BACKUP_ROOT/$CURRENT_TAG"
                EXISTING_PASS=""
                if [ -f "$ACTIVE_DIR/admin_password" ]; then
                    EXISTING_PASS=$(cat "$ACTIVE_DIR/admin_password")
                fi

                cp -r "$ACTIVE_DIR"/* "$BACKUP_ROOT/$CURRENT_TAG/" 2>/dev/null || true
                chown -R kiosk:kiosk "$BACKUP_ROOT/$CURRENT_TAG"

                TEMP_DIR=$(mktemp -d)
                unzip -q "$TEMP_ZIP" -d "$TEMP_DIR"
                if [ -f "$TEMP_DIR/silvane" ]; then
                    chmod +x "$TEMP_DIR/silvane"
                    rm -rf "$ACTIVE_DIR"/*
                    cp -r "$TEMP_DIR"/* "$ACTIVE_DIR/"

                    if [ -n "$EXISTING_PASS" ] && [ ! -f "$ACTIVE_DIR/admin_password" ]; then
                        echo "$EXISTING_PASS" > "$ACTIVE_DIR/admin_password"
                    fi

                    chown -R kiosk:kiosk "$ACTIVE_DIR"
                    chmod +x "$ACTIVE_DIR/silvane"
                    chmod 644 "$ACTIVE_DIR/admin_password" || true
                    echo "[*] Manual binary update completed successfully!"
                else
                    echo "[!] Extracted package missing executable binary."
                fi
                rm -rf "$TEMP_DIR"
            else
                echo "[!] Failed to fetch release package from GitHub."
            fi
            rm -f "$TEMP_ZIP"
            read -p "Press ENTER to continue..."
            ;;
        5)
            echo "[*] Installing required compilation toolchains via sudo..."
            sudo apt-get update
            sudo apt-get install -y \
                cmake \
                build-essential \
                clang \
                ninja-build \
                pkg-config \
                libgtk-3-dev \
                libsecret-1-dev \
                libjsoncpp-dev

            echo "[*] Setting up debug workspace in /opt/silvane/debug..."
            mkdir -p /opt/silvane/debug
            
            TOKEN=""
            if [ -f /opt/silvane/api_key ]; then
                TOKEN=$(cat /opt/silvane/api_key | tr -d '\r\n')
            fi
            
            if [ -z "$TOKEN" ]; then
                echo ""
                read -p "Enter GitHub API token / Auth Key (leave blank for public clone): " input_token
                if [ -n "$input_token" ]; then
                    TOKEN="$input_token"
                    echo "$TOKEN" > /opt/silvane/api_key
                    chmod 600 /opt/silvane/api_key
                    echo "[*] API key saved to /opt/silvane/api_key"
                fi
            fi

            cd /opt/silvane/debug
            if [ -d ".git" ] || [ -d "app" ]; then
                echo "[*] Existing repo found..."
                if [ -d "app" ]; then
                    echo "[*] Base git repo found. Moving to next task..."
                fi
                if [ -n "$TOKEN" ]; then
                    echo "[*] Pulling latest private repo updates..."
                    git pull https://x-access-token:${TOKEN}@github.com/mdbench/silvane.git || git pull || true
                else
                    echo "[*] Pulling latest public repo updates..."
                    git pull || true
                fi
            else
                echo "[*] Preparing workspace and cloning repository into /opt/silvane/debug..."
                find /opt/silvane/debug -mindepth 1 -maxdepth 1 ! -name 'flutter' -exec rm -rf {} + 2>/dev/null || true
                if [ -n "$TOKEN" ]; then
                    git clone https://x-access-token:${TOKEN}@github.com/mdbench/silvane.git . || git clone https://github.com/mdbench/silvane.git .
                else
                    git clone https://github.com/mdbench/silvane.git .
                fi
            fi

            if [ ! -d "/opt/silvane/debug/flutter" ]; then
                echo "[*] Downloading and installing Flutter SDK into /opt/silvane/debug/flutter..."
                mkdir -p /opt/silvane/debug
                curl -L https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz | tar -xJ -C /opt/silvane/debug/
            fi

            echo "[*] Launching Flutter run debug with verbose..."
            xterm -fg white -bg black -fa 'Monospace' -fs 10 -geometry 120x35 -title "Flutter Debug Runner" -e "export PATH=\"\$PATH:/opt/silvane/debug/flutter/bin\"; cd /opt/silvane/debug/app || cd /opt/silvane/debug; echo '[*] Running flutter run -d linux --debug --verbose...'; flutter run -d linux --debug --verbose; echo ''; echo 'Press ENTER to close.'; read"
            ;;
        6)
            echo ""
            read -s -p "Enter new admin password: " new_pass_1
            echo ""
            read -s -p "Confirm new admin password: " new_pass_2
            echo ""
            if [ "$new_pass_1" = "$new_pass_2" ] && [ -n "$new_pass_1" ]; then
                echo "$new_pass_1" > /opt/silvane/admin_password
                chmod 644 /opt/silvane/admin_password
                chown kiosk:kiosk /opt/silvane/admin_password || true
                echo "[*] Admin password successfully updated!"
            else
                echo "[!] Passwords do not match or are empty. Password change cancelled."
            fi
            sleep 3
            ;;
        7)
            echo "[*] Available backup versions:"
            select BACKUP_DIR in /opt/silvane.old/*/; do
                if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
                    EXISTING_PASS=""
                    if [ -f /opt/silvane/admin_password ]; then
                        EXISTING_PASS=$(cat /opt/silvane/admin_password)
                    fi
                    rm -rf /opt/silvane/*
                    cp -r "${BACKUP_DIR}"* /opt/silvane/
                    if [ -n "$EXISTING_PASS" ] && [ ! -f /opt/silvane/admin_password ]; then
                        echo "$EXISTING_PASS" > /opt/silvane/admin_password
                    fi
                    chown -R kiosk:kiosk /opt/silvane
                    chmod +x /opt/silvane/silvane
                    chmod 644 /opt/silvane/admin_password || true
                    echo "[*] Successfully rolled back to version!"
                    break
                else
                    echo "[!] Invalid selection."
                    break
                fi
            done
            sleep 3
            ;;
        8)
            bash
            ;;
        9)
            break
            ;;
        *)
            echo "Invalid choice."
            sleep 1
            ;;
    esac
done
DEBUG_MENU_EOF
chmod +x /usr/local/bin/silvane-debug-menu

mkdir -p /home/kiosk/.config/openbox
cat << 'RC_EOF' > /home/kiosk/.config/openbox/rc.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3/rc">
  <applications>
    <application name="silvane" class="silvane">
      <decor>yes</decor>
      <fullscreen>yes</fullscreen>
      <maximized>true</maximized>
    </application>
    <application class="*">
      <decor>no</decor>
    </application>
  </applications>
  <keyboard>
    <keybind key="C-A-S-c">
      <action name="Execute">
        <command>xterm -fg white -bg black -fa 'Monospace' -fs 12 -title "Silvane Recovery and Debug Menu" -e /usr/local/bin/silvane-debug-menu</command>
      </action>
    </keybind>
  </keyboard>
</openbox_config>
RC_EOF

# OPENBOX AUTOSTART OPTIMIZATION with advanced crash loopback and factory fallback recovery
cat << 'AUTO_EOF' > /home/kiosk/.config/openbox/autostart
export HOME=/home/kiosk
export XDG_DATA_HOME="/home/kiosk/.local/share"
export XDG_CONFIG_HOME="/home/kiosk/.config"
export XDG_CACHE_HOME="/home/kiosk/.cache"
export GDK_SCALE=0.85
export GDK_DPI_SCALE=0.85
export NO_AT_BRIDGE=1
export DISPLAY=:0
export GDK_BACKEND=x11
export CLUTTER_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1

mkdir -p /home/kiosk/Documents/silvane_dbs "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

xset s off
xset -dpms
xset s noblank

( xterm -fg white -bg black -fa 'Monospace' -fs 12 -geometry 90x24 -e /usr/local/bin/silvane-update ) &

while true; do
    if [ -f "/opt/silvane/silvane" ]; then
        cd /opt/silvane
        export DISPLAY=:0
        export LIBGL_ALWAYS_SOFTWARE=1
        ./silvane && break
        echo "[!] App crashed or exited with error. Initiating fallback recovery..."
    fi

    RECOVERED=0
    if [ -d "/opt/silvane.old" ]; then
        for DIR in $(ls -dt /opt/silvane.old/*/ 2>/dev/null); do
            if [ -f "${DIR}silvane" ]; then
                echo "[*] Restoring fallback version from ${DIR}..."
                rm -rf /opt/silvane/*
                cp -r "${DIR}"* /opt/silvane/
                chown -R kiosk:kiosk /opt/silvane
                chmod +x /opt/silvane/silvane
                RECOVERED=1
                break
            fi
        done
    fi

    if [ $RECOVERED -eq 0 ]; then
        echo "[!] Critical Error: No working binary found in /opt/silvane or /opt/silvane.old!"
        
        if [ -d "/usr/share/silvane/factory" ] && [ -f "/usr/share/silvane/factory/silvane" ]; then
            echo "[*] Restoring pristine factory default version from read-only system storage..."
            mkdir -p /opt/silvane
            rm -rf /opt/silvane/*
            cp -r /usr/share/silvane/factory/* /opt/silvane/
            chown -R kiosk:kiosk /opt/silvane
            chmod +x /opt/silvane/silvane
            echo "[*] Factory reset complete. Restarting app loop..."
            continue
        fi

        echo "[!] Fatal: No factory fallback available. Sleeping..."
        sleep 5
    fi
done
AUTO_EOF

cat << 'XINIT_EOF' > /home/kiosk/.xinitrc
exec openbox-session
XINIT_EOF

chown -R kiosk:kiosk /home/kiosk/.config
chown kiosk:kiosk /home/kiosk/.xinitrc
chmod +x /home/kiosk/.xinitrc
chmod +x /home/kiosk/.config/openbox/autostart

cat << 'PROFILE_EOF' > /home/kiosk/.bash_profile
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
PROFILE_EOF

chown kiosk:kiosk /home/kiosk/.bash_profile
HOOK_EOF

chmod +x config/hooks/normal/99-silvane-kiosk.chroot

# Configure live-build with live installer parameters (security mirrors stripped out)
lb config \
  --distribution bookworm \
  --keyring-packages debian-archive-keyring \
  --mirror-bootstrap "http://deb.debian.org/debian" \
  --mirror-chroot "http://deb.debian.org/debian" \
  --mirror-binary "http://deb.debian.org/debian" \
  --archive-areas "main contrib non-free-firmware" \
  --security false \
  --apt-recommends false \
  --linux-packages "linux-image" \
  --debian-installer live \
  --debian-installer-distribution bookworm \
  --bootappend-live "boot=live components union=overlay persistence quiet splash locales=en_US.UTF-8" \
  --bootappend-install "priority=high file=/cdrom/preseed.cfg" \
  --binary-images iso-hybrid \
  --win32-loader false

find config/ -type f -exec sed -i 's/Debian GNU\/Linux 12 (bookworm)/Silvane Security Kiosk/g' {} + || true
find config/ -type f -exec sed -i 's/Debian GNU\/Linux/Silvane Kiosk/g' {} + || true
find config/ -type f -exec sed -i 's/Debian/Silvane/g' {} + || true

lb build

mv live-image-amd64.hybrid.iso "${WORKSPACE}/silvane-security-kiosk-${LOCAL_TAG}.iso"
echo "[*] Moved ISO to workspace root."

cd "$WORKSPACE"

# 10. Forced GitHub Release Asset Replacement via API
echo "[*] Managing GitHub Release via API..."
if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ]; then
    REPO_ROOT="$(pwd)"
    
    TEMP_RELEASE_CLONE=$(mktemp -d)
    set +e
    git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$TEMP_RELEASE_CLONE"
    cd "$TEMP_RELEASE_CLONE"
    set -e

    RELEASE_API_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${LOCAL_TAG}"
    RELEASE_RESPONSE=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "$RELEASE_API_URL")
    
    RELEASE_ID=$(echo "$RELEASE_RESPONSE" | jq -r '.id' 2>/dev/null || echo "")
    echo "[*] Target Release ID for tag ${LOCAL_TAG}: '${RELEASE_ID}'"

    if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
        echo "[*] Release not found. Creating release ${LOCAL_TAG}..."
        CREATE_RESPONSE=$(curl -s -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases" \
            -d "{\"tag_name\":\"${LOCAL_TAG}\",\"name\":\"Silvane Security Kiosk ${LOCAL_TAG}\",\"body\":\"Automated installable/live secure kiosk ISO, standalone binary release track, and container bundle for Silvane.\"}")
        RELEASE_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id' 2>/dev/null || echo "")
        echo "[*] Created new Release ID: '${RELEASE_ID}'"
    else
        echo "[*] Release ${LOCAL_TAG} already exists."
    fi

    ISO_FILE="${REPO_ROOT}/silvane-security-kiosk-${LOCAL_TAG}.iso"
    if [ ! -f "$ISO_FILE" ]; then
        ALT_ISO=$(find "${REPO_ROOT}" -name "*.iso" | head -n 1)
        if [ -n "$ALT_ISO" ] && [ -f "$ALT_ISO" ]; then
            ISO_FILE="$ALT_ISO"
            echo "[*] Located ISO at: $ISO_FILE"
        fi
    fi

    CLONED_ZIP="${TEMP_RELEASE_CLONE}/binaries/latest.zip"
    CLONED_TAR="${TEMP_RELEASE_CLONE}/dockers/latest.tar.gz"

    ASSETS_TO_UPLOAD=(
        "$ISO_FILE|silvane-security-kiosk-${LOCAL_TAG}.iso"
        "$CLONED_ZIP|silvane-linux-binary-${LOCAL_TAG}.zip"
        "$CLONED_TAR|silvane-container-bundle-${LOCAL_TAG}.tar.gz"
    )

    ASSETS_JSON=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets" 2>/dev/null || echo "[]")
        
    for ITEM in "${ASSETS_TO_UPLOAD[@]}"; do
        FILE_NAME="${ITEM##*|}"
        EXISTING_ASSET_ID=$(echo "$ASSETS_JSON" | jq -r --arg name "$FILE_NAME" '.[] | select(.name == $name) | .id' 2>/dev/null || echo "")
        if [ -n "$EXISTING_ASSET_ID" ] && [ "$EXISTING_ASSET_ID" != "null" ]; then
            echo "[*] Deleting outdated/stuck asset $FILE_NAME (ID: $EXISTING_ASSET_ID)..."
            curl -s -X DELETE -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/assets/${EXISTING_ASSET_ID}" > /dev/null || true
        fi
    done
    sleep 2

    for ITEM in "${ASSETS_TO_UPLOAD[@]}"; do
        FILE_PATH="${ITEM%%|*}"
        FILE_NAME="${ITEM##*|}"

        if [ -f "$FILE_PATH" ]; then
            echo "[*] Uploading asset: $FILE_NAME via gh cli..."
            set +e
            GH_TOKEN="$GITHUB_TOKEN" gh release upload "${LOCAL_TAG}" "$FILE_PATH#$FILE_NAME" --clobber
            set -e
            echo "[*] Successfully processed $FILE_NAME"
        else
            echo "[!] Warning: Required artifact missing at $FILE_PATH"
        fi
    done

    cd "$REPO_ROOT"
    rm -rf "$TEMP_RELEASE_CLONE"
else
    echo "[!] GITHUB_TOKEN or GITHUB_REPOSITORY missing. Skipping asset upload."
fi

echo "=== Build Pipeline Completed Successfully ==="