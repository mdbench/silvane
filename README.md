# SilvaneOS

<div align=\"center\">

[![Build LDLx Kiosk ISO](https://github.com/mdbench/ldlx/actions/workflows/build_kiosk.yml/badge.svg)](https://github.com/mdbench/ldlx/actions/workflows/build_kiosk.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/mdbench/ldlx?color=blue&style=flat-square)](https://github.com/mdbench/ldlx/releases)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-yellow.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Debian%20Bookworm%20%7C%20Flutter-orange?style=flat-square)](https://github.com/mdbench/ldlx)

</div>

<div align="center">
  <img src="https://raw.githubusercontent.com/mdbench/silvane/refs/heads/main/demo1.png" alt="Silvane Demo Image of Initial Entry" width="100%" height="auto" />
</div>

SilvaneOS is an enterprise-grade workspace management platform, secure server ecosystem, and local runtime daemon built with Flutter, Dart, and Sembast. It provides localized secure HTTPS server deployments, automated workspace provisioning, real-time telemetry tracing, and firewall integration designed for robust developer and administrative workflows.

### *NOTICE*: Right now, the binary does not work on start up via live boot and installation. However, if you click CTRL+ALT+Shift+C you can get into a debug menu and click option #3 to fix it with a complete rebuild. I am currently working to fix this error that occurs on GitHub Actions.
- **Default Debug Menu PW:** password: `admin`

## The Need It Fills

Developers and small teams frequently manage multiple local web servers and microservice environments, but transitioning those workspaces into secure, production-grade environments usually requires complex server setups, cloud hosting contracts, and intricate networking configurations. 

SilvaneOS solves this problem by functioning as a security-focused, dedicated operating system environment. Instead of running services as fragmented background applications inside a heavy general-purpose desktop OS, SilvaneOS turns hardware into a streamlined, purpose-built secure server node.

## Key Features

* **Secure HTTPS Servers**: Automatically scans and spins up local workspace repositories as secure HTTPS servers on application launch using built-in SSL assets and dynamic port allocation.
* **Cydog Encrypted Asset Viewer**: Wraps sensitive repository files in a deterrence HTML page using the [Cydog Deterrent Encryptor](https://github.com/Cydog-Browser/deterrent-encryptor) architecture, featuring a hidden iframe and a client-side Web Crypto API decryption prompt wrapper.
* **Workspace and Git Management**: Manages directory hierarchies, recursive file trees, and direct repository cloning with inline execution of Git status telemetry.
* **Real-Time Telemetry and WHOIS Attribution**: Tracks visitor access logs, latencies, and endpoint hit frequencies across customized historical horizons, coupled with live WHOIS network attribution.
* **Firewall and DNS Control**: Interacts with host utilities to manage inbound and outbound ports while safeguarding critical infrastructure ports.
* **Role-Based Access Control and 2FA**: Enforces strict administrative boundaries with secure authentication, multi-factor TOTP verification, permission matrices, and audit logging stored locally via Sembast.

## Adding a Server with a Repository

SilvaneOS makes it straightforward to add and deploy a server directly from a local or remote code repository:

1. **Clone or Provision via Workspace Manager**: Use the built-in clone utility in the workspace tab to point to a Git repository target URL, provide a personal access token if private, and designate a local folder alias.
2. **Configure Optional Settings**: Place a configuration file inside your repository directory to specify runtime options such as python version, php version, or a custom server alias.
3. **Automatic Scanning and Booting**: Upon application startup or a manual re-scan, SilvaneOS automatically reads the workspace directory structure, provisions virtual environments or dependencies as needed, and binds the repository to a dedicated secure HTTPS endpoint.

## OS Installation

SilvaneOS can be installed onto bare-metal hardware or run as a live image using automated ISO builds.

### Current Release
You can download the latest installable ISO image, automated release artifacts, and checksums directly from the GitHub Releases page.

### Installation Instructions
1. **Download the ISO:** Visit the repository releases page and download the latest release asset.
2. **Flash to USB:** Flash the ISO image to a blank USB flash drive using Rufus, Ventoy, or dd.
3. **Boot Target Hardware:** Insert the USB into your target machine, boot into UEFI/BIOS settings, configure priority boot from USB, and launch the installer.
4. **Kiosk Auto-Login & Execution:** Upon completion and reboot, the system automatically launches into the secure SilvaneOS environment on tty1 via openbox.
5. **Default Username/PW:** username: `admin`, password: `admin`

---

### Running via Docker (CLI)
You can load and run the container bundle directly from the command line using Docker:

```bash
# 1. Load the container bundle tarball directly into Docker as an image
docker load -i dockers/latest.tar.gz

# 2. Run the container with GUI/X11 forwarding for local testing
docker run --rm -it \\
    -e DISPLAY=\$DISPLAY \\
    -v /tmp/.X11-unix:/tmp/.X11-unix \\
    --device /dev/dri \\
    --device /dev/snd \\
    silvaneos
```

### Running via Portainer (Docker Compose)
To deploy the kiosk container stack using Portainer or standard Docker Compose from the public repository, use the following configuration:

```yaml
version: '3.8'

services:
  silvane-kiosk:
    image: mdbench/silvane:latest
    container_name: silvane-security-kiosk
    restart: unless-stopped
    environment:
      - DISPLAY=\${DISPLAY:-:0}
      - GDK_SCALE=0.85
      - GDK_DPI_SCALE=0.85
    volumes:
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - silvane_data:/opt/silvane/data
    devices:
      - /dev/dri:/dev/dri
      - /dev/snd:/dev/snd
    security_opt:
      - seccomp:unconfined
    build:
      context: https://github.com/mdbench/silvane.git#main:dockers

volumes:
  silvane_data:
```

## Roadmap

* Enforce better memory management, code reusability, enhance core features, and finish flutter-pi OS integration.
* Make VPN server so administrators can manage from the graphic user interface as a replacement for ssh, also allowing LDLx to connect to it.
* Add pro version subscription upgrade to free version for more advanced features.

## License

This project is open-source and released under the [GPL-3.0 license](LICENSE).