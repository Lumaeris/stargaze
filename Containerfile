# Getting clean base from Arch bootstrap
FROM cgr.dev/chainguard/wolfi-base:latest AS rootfs

ENV VERSION="2026.06.01"
ENV SHASUM="e68ba918c9f7deede8eccd2cd8ce259df104d84b0791cff3a2bc7579ced34849"

RUN apk add gnutar zstd curl && \
    curl -fLOJ --retry 3 https://fastly.mirror.pkgbuild.com/iso/$VERSION/archlinux-bootstrap-x86_64.tar.zst && \
    echo "$SHASUM archlinux-bootstrap-x86_64.tar.zst" > sha256sum.txt && \
    sha256sum -c sha256sum.txt || exit 1 && \
    tar -xf /archlinux-bootstrap-x86_64.tar.zst --numeric-owner && \
    rm -f /archlinux-bootstrap-x86_64.tar.zst && \
    apk del gnutar zstd curl && \
    apk cache clean

FROM scratch AS arch
COPY --from=rootfs /root.x86_64/ /

# Enabling all servers. Not ideal but it's a start
RUN sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist

# Populate Arch Linux keyring first
RUN pacman-key --init && \
    pacman-key --populate

# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN touch /var/log/pacman.log && \
    grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# Updating everything since bootstrap only updates monthly as their ISOs
RUN --mount=type=tmpfs,dst=/run \
    pacman -Syu --noconfirm && \
    pacman -S --clean --noconfirm
    
# Build necessary packages
FROM arch AS builder

RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm --needed git go && \
    pacman -S --clean --noconfirm

# Temporarily force uupd to pass "-y" flag to "brew upgrade" until it gets a new release
COPY uupd-brew-noask.patch /
RUN --mount=type=tmpfs,dst=/tmp \
    git clone https://github.com/ublue-os/uupd.git --depth=1 --branch=v1.4.0 /tmp/uupd && \
    pushd /tmp/uupd && \
    git apply /uupd-brew-noask.patch && \
    go build -v -o uupd && \
    install -Dpm 0755 uupd /uupd/usr/bin/uupd && \
    install -Dpm 644 uupd.service /uupd/usr/lib/systemd/system/uupd.service && \
    install -Dpm 644 uupd.timer /uupd/usr/lib/systemd/system/uupd.timer && \
    install -Dpm 644 uupd.rules /uupd/etc/polkit-1/rules.d/uupd.rules && \
    popd

# Resulting system
FROM arch AS system

# Add uupd mainly for autoupdate purposes
COPY --from=builder /uupd/ /

# Add bootc repo by Hec (https://github.com/hecknt/arch-bootc-pkgs)
RUN --mount=type=tmpfs,dst=/run \
    pacman-key --recv-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB && \
    echo -e '[bootc]\nSigLevel = Required\nServer = https://github.com/hecknt/arch-bootc-pkgs/releases/download/$repo' >> /etc/pacman.conf

# Install base packages
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm --needed base \
        dracut \
        cpio \
        linux \
        linux-firmware \
        ostree \
        btrfs-progs \
        e2fsprogs \
        xfsprogs \
        dosfstools \
        skopeo \
        dbus \
        dbus-glib \
        glib2 \
        shadow \
        bootc/bootc && \
    pacman -S --clean --noconfirm

# Audio
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm pipewire \
        pipewire-pulse \
        pipewire-jack \
        wireplumber && \
    pacman -S --clean --noconfirm

# Install GPU drivers
# TODO: split nvidia to its own image
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm --needed mesa \
        mesa-utils \
        xorg-xwayland \
        vulkan-icd-loader \
        vulkan-intel \
        vulkan-radeon \
        vulkan-nouveau \
        vulkan-tools \
        nvidia-utils \
        nvidia-open \
        nvidia-settings \
        nvidia-container-toolkit \
        nvidia-prime && \
    pacman -S --clean --noconfirm

# Install DankMaterialShell and Niri
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm dms-shell-niri \
        xdg-desktop-portal-gtk \
        xdg-desktop-portal-gnome && \
    pacman -S --clean --noconfirm

# DMS optional dependencies
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm matugen \
        cava \
        cups-pk-helper \
        i2c-tools \
        power-profiles-daemon \
        qt6-multimedia \
        qt6ct \
        wtype \
        kimageformats \
        greetd && \
    pacman -S --clean --noconfirm

# Network and bluetooth
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm networkmanager \
        bluez \
        bluez-utils && \
    pacman -S --clean --noconfirm

# Terminal
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm foot \
        foot-terminfo \
        libnotify && \
    pacman -S --clean --noconfirm

# Polkit, sudo and keyring
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm sudo \
        lxqt-policykit \
        gnome-keyring && \
    pacman -S --clean --noconfirm

# Container things
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm podman \
        distrobox && \
    pacman -S --clean --noconfirm

# Flatpak
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm flatpak && \
    pacman -S --clean --noconfirm

# General tools
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm --needed gnome-disk-utility \
        udiskie \
        nautilus-python \
        gvfs \
        7zip \
        unrar \
        unzip \
        fastfetch \
        just \
        less \
        vim \
        git \
        plymouth \
        zram-generator \
        man-db \
        man-pages && \
    pacman -S --clean --noconfirm

# Fonts
RUN --mount=type=tmpfs,dst=/run \
    --mount=type=tmpfs,dst=/tmp \
    pacman -Sy --noconfirm ttf-dejavu \
        ttf-liberation \
        noto-fonts \
        noto-fonts-cjk \
        noto-fonts-emoji \
        noto-fonts-extra && \
    pacman -S --clean --noconfirm && \
    mkdir -p /tmp/maplemono && \
    curl --retry 3 -Lo /tmp/maplemono/arch.zip https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-NF-unhinted.zip && \
    mkdir -p /usr/share/fonts/maple-mono-nf && \
    pushd /tmp/maplemono && \
    unzip arch.zip && \
    cp MapleMono-* LICENSE.txt /usr/share/fonts/maple-mono-nf && \
    popd && \
    setfattr -n user.component -v "maple-mono-nf" /usr/share/fonts/maple-mono-nf && \
    fc-cache --force --really-force --system-only --verbose

# Add Chaotic AUR
# They do human reviews on each packaging change way before recent AUR malware attacks
RUN --mount=type=tmpfs,dst=/run \
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key 3056513887B78AEB && \
    pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' && \
    echo -e '[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf && \
    pacman -S --clean --noconfirm

# Install some stuff from Chaotic AUR
RUN --mount=type=tmpfs,dst=/run \
    pacman -Sy --noconfirm chaotic-aur/input-remapper-git \
        chaotic-aur/xdg-terminal-exec-git && \
    pacman -S --clean --noconfirm

# Add "Open in Terminal" option which references xdg-terminal-exec
RUN mkdir -p /usr/share/nautilus-python/extensions && \
    curl --retry 3 -Lo /usr/share/nautilus-python/extensions/xdg-terminal-exec-nautilus.py https://raw.githubusercontent.com/zirconium-dev/xdg-terminal-exec-nautilus/refs/heads/main/xdg-terminal-exec-nautilus.py

# Add Homebrew and brew-proxy
RUN --mount=type=tmpfs,dst=/run \
    pacman-key --recv-key F88AD54AC93B084021C2BB69FC179FA0288C0734 --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key F88AD54AC93B084021C2BB69FC179FA0288C0734 && \
    echo -e '[homebrew]\nSigLevel = Required\nServer = https://github.com/Lumaeris/homebrew-arch/releases/download/$repo' >> /etc/pacman.conf && \
    pacman -Sy --noconfirm homebrew/homebrew homebrew/brew-proxy && \
    pacman -S --clean --noconfirm

# Add system files
COPY files /
COPY cosign.pub /usr/lib/pki/containers/lumaeris.pub

# Setup systemd services
RUN systemctl preset-all && \
    systemctl preset-all --global

# Fix PAM bs (pam_shells breaks systemd-homed user auth)
RUN sed -i 's/.*pam_shells.*//g' /etc/pam.d/system-login

# Add gnome keyring PAM support for both greetd and tty login
RUN echo -e 'auth\toptional\tpam_gnome_keyring.so\nsession\toptional\tpam_gnome_keyring.so auto_start' | tee -a /etc/pam.d/system-login

# Fix rootless podman
RUN setcap -r /usr/bin/newuidmap && \
    setcap -r /usr/bin/newgidmap && \
    chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap

# Remove machine-id
RUN rm /etc/machine-id

# Set new os-release
RUN cat > /usr/lib/os-release <<EOF
NAME="Stargaze"
ID="stargaze"
ID_LIKE="arch"
BUILD_ID="rolling"
PRETTY_NAME="Stargaze"
HOME_URL="https://github.com/Lumaeris/stargaze"
SUPPORT_URL="https://github.com/Lumaeris/stargaze/issues"
LOGO="archlinux-logo"
DEFAULT_HOSTNAME="stargaze"
IMAGE_VERSION="$(date -u "+%Y%m%d")"
EOF

# Link /etc/os-release to its equivalent in /usr/lib/os-release
RUN ln -sf ../usr/lib/os-release /etc/os-release

# Regenerate initramfs
RUN --mount=type=tmpfs,dst=/tmp \
    --mount=type=tmpfs,dst=/root \
    --mount=type=tmpfs,dst=/run \
    mkdir -p /usr/lib/dracut/dracut.conf.d/ && \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc plymouth "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)/initramfs.img"

# Give the greeter a dummy home folder to avoid some errors
RUN usermod greeter --home /run/greetd

# Adjusting rootfs to be bootc-compatible
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /boot \
        /home \
        /root \
        /usr/local \
        /srv \
        /opt \
        /mnt \
        /var \
        /usr/lib/sysimage/log \
        /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && ln -sT var/srv /srv && ln -sT var/opt /opt && ln -sT var/mnt /mnt && ln -sT var/home /home && ln -sT ../var/usrlocal /usr/local && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

LABEL containers.bootc 1

RUN bootc container lint
