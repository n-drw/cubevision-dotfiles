#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  mmWave Radar Driver Setup — RS-2944A on Jetson Orin Nano           ║
# ║                                                                      ║
# ║  Installs CP2105 USB-to-UART driver, udev rules, permissions,       ║
# ║  Python radar dependencies, and optionally ROS Melodic.             ║
# ║                                                                      ║
# ║  Usage:                                                              ║
# ║    bash mmwave/setup-mmwave.sh                                       ║
# ║    bash mmwave/setup-mmwave.sh --check                              ║
# ║    bash mmwave/setup-mmwave.sh --ros                                ║
# ║    bash mmwave/setup-mmwave.sh --venv /path/to/venv                 ║
# ║    bash mmwave/setup-mmwave.sh --skip-reboot                        ║
# ╚══════════════════════════════════════════════════════════════════════╝
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
MMWAVE_DIR="$DOTFILES/mmwave"

# ─── Defaults ────────────────────────────────────────────────────────
RADAR_VENV="${HOME}/.venvs/radar"
INSTALL_ROS=false
CHECK_ONLY=false
SKIP_REBOOT=false
ROS_WS="${HOME}/catkin_ws"
ROS_DOCKER_IMAGE="cubeship/ros-melodic-mmwave"

# ─── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }
detail()  { echo -e "    ${CYAN}→${NC} $*"; }

# ─── Parse arguments ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_ONLY=true ;;
        --ros)         INSTALL_ROS=true ;;
        --venv)        shift; RADAR_VENV="$1" ;;
        --skip-reboot) SKIP_REBOOT=true ;;
        --help|-h)
            echo "Usage: $0 [--check] [--ros] [--venv /path] [--skip-reboot]"
            echo ""
            echo "  --check        Check current driver state only (no changes)"
            echo "  --ros          Install ROS Melodic desktop-full + ti_mmwave_rospkg (Docker)"
            echo "  --venv PATH    Python venv path (default: ~/.venvs/radar)"
            echo "  --skip-reboot  Skip reboot prompt at end"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ─── Check mode ─────────────────────────────────────────────────────
check_status() {
    section "mmWave Radar — Current State"

    # Kernel module
    if lsmod | grep -q cp210x 2>/dev/null; then
        info "cp210x kernel module: LOADED"
    else
        # Check if available but not loaded
        if modinfo cp210x &>/dev/null; then
            warn "cp210x kernel module: AVAILABLE but not loaded"
        else
            error "cp210x kernel module: NOT FOUND in kernel"
        fi
    fi

    # udev rules
    if [ -f /etc/udev/rules.d/99-mmwave-radar.rules ]; then
        info "udev rules: INSTALLED"
    else
        warn "udev rules: NOT INSTALLED"
    fi

    # dialout group
    if id -nG "$USER" | grep -qw dialout; then
        info "dialout group: $USER is a member"
    else
        warn "dialout group: $USER is NOT a member"
    fi

    # USB devices
    echo ""
    if lsusb 2>/dev/null | grep -qi "10c4.*ea70\|silicon.*cp2105"; then
        info "CP2105 USB device: DETECTED"
        lsusb | grep -i "10c4\|silicon" | while read -r line; do
            detail "$line"
        done
    else
        warn "CP2105 USB device: not currently connected"
    fi

    # Device nodes
    echo ""
    local found_dev=false
    for dev in /dev/radar_cfg /dev/radar_data /dev/mmWave_*; do
        if [ -e "$dev" ]; then
            found_dev=true
            local target
            target=$(readlink -f "$dev" 2>/dev/null || echo "?")
            info "Device: $dev → $target"
        fi
    done
    if [ "$found_dev" = false ]; then
        warn "No radar device symlinks found (is the sensor connected?)"
    fi

    # ttyUSB devices
    for dev in /dev/ttyUSB*; do
        if [ -e "$dev" ]; then
            detail "Serial port: $dev"
        fi
    done

    # Python venv
    echo ""
    if [ -d "$RADAR_VENV" ] && [ -f "$RADAR_VENV/bin/python" ]; then
        info "Python venv: $RADAR_VENV"
        if "$RADAR_VENV/bin/python" -c "import serial; print(f'  pyserial {serial.VERSION}')" 2>/dev/null; then
            true
        else
            warn "pyserial not installed in venv"
        fi
    else
        warn "Python venv: not found at $RADAR_VENV"
    fi

    # ROS Melodic (Docker)
    if docker image inspect "$ROS_DOCKER_IMAGE" &>/dev/null 2>&1; then
        info "ROS Melodic Docker image: $ROS_DOCKER_IMAGE (built)"
    elif command -v docker &>/dev/null; then
        detail "ROS Melodic Docker image: not built (use --ros to build)"
    else
        detail "Docker: not installed (required for ROS Melodic on Ubuntu 22.04)"
    fi
}

if [ "$CHECK_ONLY" = true ]; then
    check_status
    exit 0
fi

# ─── Main install ───────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  mmWave Radar Setup — RS-2944A on Jetson Orin Nano          ║"
echo "║  CP2105 USB-UART · udev rules · dialout · Python · ROS 2   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── 1. System packages ─────────────────────────────────────────────
section "1/6 — System Packages"

sudo apt-get update -qq
sudo apt-get install -y -qq \
    python3-serial \
    python3-pip \
    python3-venv \
    linux-tools-common \
    usbutils \
    minicom \
    screen \
    || warn "Some packages may not be available"

info "System packages installed."

# ─── 2. CP2105 kernel module ────────────────────────────────────────
section "2/6 — CP2105 Kernel Module (cp210x)"

if modinfo cp210x &>/dev/null; then
    info "cp210x module found in kernel."
else
    warn "cp210x module not found. Attempting to load..."
    # On JetPack 6 the module should be built-in or available.
    # If not, the user needs to rebuild the kernel with CONFIG_USB_SERIAL_CP210X=m
    error "cp210x not available. You may need to enable CONFIG_USB_SERIAL_CP210X"
    error "in your kernel config and rebuild. See:"
    error "  https://forums.developer.nvidia.com/t/enable-config-usb-serial-pl2303-on-kernel/285574"
    error ""
    error "For JetPack 6.x this should already be included. Check with:"
    error "  zcat /proc/config.gz | grep CP210X"
fi

# Load the module now
if ! lsmod | grep -q cp210x; then
    info "Loading cp210x module..."
    sudo modprobe cp210x || warn "Could not load cp210x (may already be built-in)"
fi

# Ensure it loads on boot
if [ ! -f /etc/modules-load.d/mmwave-cp210x.conf ]; then
    info "Adding cp210x to boot modules..."
    echo "cp210x" | sudo tee /etc/modules-load.d/mmwave-cp210x.conf > /dev/null
fi

info "cp210x kernel module configured."

# ─── 3. udev rules ──────────────────────────────────────────────────
section "3/6 — udev Rules (stable /dev/radar_* symlinks)"

sudo cp "$MMWAVE_DIR/99-mmwave-radar.rules" /etc/udev/rules.d/99-mmwave-radar.rules
sudo udevadm control --reload-rules
sudo udevadm trigger

info "udev rules installed:"
detail "/dev/mmWave_<serial>_00  →  config port (115200 baud)"
detail "/dev/mmWave_<serial>_01  →  data port (921600 baud)"
detail "/dev/radar_cfg           →  config port alias"
detail "/dev/radar_data          →  data port alias"

# ─── 4. User permissions ────────────────────────────────────────────
section "4/6 — User Permissions (dialout group)"

if id -nG "$USER" | grep -qw dialout; then
    info "$USER is already in the dialout group."
else
    info "Adding $USER to the dialout group..."
    sudo usermod -aG dialout "$USER"
    warn "You must log out and back in for group changes to take effect."
fi

# ─── 5. Python virtual environment + radar dependencies ─────────────
section "5/6 — Python Radar Dependencies"

info "Setting up Python venv at: $RADAR_VENV"
mkdir -p "$(dirname "$RADAR_VENV")"

if [ ! -d "$RADAR_VENV" ]; then
    python3 -m venv "$RADAR_VENV"
    info "Created new venv."
else
    info "Venv already exists."
fi

"$RADAR_VENV/bin/pip" install --upgrade pip -q

# Install radar requirements if the cubeship-mmwave-firmware repo exists
RADAR_REQS="$HOME/work/cubeship-mmwave-firmware/radar/requirements.txt"
if [ -f "$RADAR_REQS" ]; then
    info "Installing from $RADAR_REQS..."
    "$RADAR_VENV/bin/pip" install -r "$RADAR_REQS" -q
else
    info "Installing core radar packages..."
    "$RADAR_VENV/bin/pip" install pyserial numpy websockets scipy -q
fi

# Verify
"$RADAR_VENV/bin/python" -c "
import serial, numpy, websockets
print(f'  pyserial  {serial.VERSION}')
print(f'  numpy     {numpy.__version__}')
print(f'  websockets {websockets.__version__}')
" && info "Python radar packages verified." || warn "Some packages failed to import."

# ─── 6. (Optional) ROS Melodic desktop-full + TI mmWave ROS driver ────
if [ "$INSTALL_ROS" = true ]; then
    section "6/6 — ROS Melodic desktop-full (Docker) + ti_mmwave_rospkg"

    # ROS Melodic targets Ubuntu 18.04 Bionic — it cannot be installed natively
    # on Ubuntu 22.04 (Jammy). We use Docker with device passthrough for serial.

    if ! command -v docker &>/dev/null; then
        error "Docker is required for ROS Melodic on Ubuntu 22.04."
        error "Install Docker first:  sudo apt-get install -y docker.io"
        error "Then re-run:  bash mmwave/setup-mmwave.sh --ros"
        exit 1
    fi

    # Ensure user can run docker without sudo
    if ! id -nG "$USER" | grep -qw docker; then
        info "Adding $USER to docker group..."
        sudo usermod -aG docker "$USER"
        warn "You may need to log out and back in for docker group to take effect."
    fi

    # Create Dockerfile for ROS Melodic + ti_mmwave_rospkg
    ROS_DOCKER_DIR="$MMWAVE_DIR/ros-melodic-docker"
    mkdir -p "$ROS_DOCKER_DIR"

    info "Writing Dockerfile for ROS Melodic..."
    cat > "$ROS_DOCKER_DIR/Dockerfile" << 'DOCKERFILE'
FROM ros:melodic-ros-base-bionic

ENV DEBIAN_FRONTEND=noninteractive

# Install ros-melodic-desktop-full and build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-melodic-desktop-full \
        ros-melodic-serial \
        ros-melodic-rviz \
        python-catkin-tools \
        python-pip \
        git \
    && rm -rf /var/lib/apt/lists/*

# Create catkin workspace and clone TI mmWave ROS driver
RUN mkdir -p /catkin_ws/src
WORKDIR /catkin_ws/src
RUN git clone https://github.com/radar-lab/ti_mmwave_rospkg.git \
    && git clone https://github.com/wjwwood/serial.git

# Build the workspace
WORKDIR /catkin_ws
RUN /bin/bash -c "source /opt/ros/melodic/setup.bash && catkin_make"

# Source workspace on shell entry
RUN echo "source /opt/ros/melodic/setup.bash" >> /root/.bashrc \
    && echo "source /catkin_ws/devel/setup.bash" >> /root/.bashrc

# Default: launch an interactive shell
CMD ["/bin/bash"]
DOCKERFILE

    # Write a convenience launch script
    cat > "$ROS_DOCKER_DIR/run-ros-melodic.sh" << 'LAUNCHER'
#!/usr/bin/env bash
# Launch ROS Melodic container with USB serial device passthrough
# Usage:
#   bash run-ros-melodic.sh                         # interactive shell
#   bash run-ros-melodic.sh roslaunch ti_mmwave_rospkg 1642es2_short_range.launch
#
set -euo pipefail

IMAGE="cubeship/ros-melodic-mmwave"

# Collect all ttyUSB and mmWave devices for passthrough
DEVICE_ARGS=""
for dev in /dev/ttyUSB* /dev/radar_cfg /dev/radar_data; do
    [ -e "$dev" ] && DEVICE_ARGS+="--device=$dev "
done

# Allow GUI (rviz) via X11 forwarding
XSOCK=/tmp/.X11-unix
XAUTH=/tmp/.docker.xauth
if [ -n "${DISPLAY:-}" ]; then
    touch "$XAUTH"
    xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f "$XAUTH" nmerge - 2>/dev/null || true
    DISPLAY_ARGS="-e DISPLAY=$DISPLAY -v $XSOCK:$XSOCK:rw -v $XAUTH:$XAUTH:rw -e XAUTHORITY=$XAUTH"
else
    DISPLAY_ARGS=""
fi

# shellcheck disable=SC2086
docker run -it --rm \
    --net=host \
    --privileged \
    $DEVICE_ARGS \
    $DISPLAY_ARGS \
    -v "${HOME}/work/cubeship-mmwave-firmware/radar/config:/radar_config:ro" \
    "$IMAGE" \
    "${@:-/bin/bash}"
LAUNCHER
    chmod +x "$ROS_DOCKER_DIR/run-ros-melodic.sh"

    # Build the Docker image
    if docker image inspect "$ROS_DOCKER_IMAGE" &>/dev/null 2>&1; then
        info "Docker image $ROS_DOCKER_IMAGE already exists."
        read -rp "  Rebuild? [y/N] " rebuild
        if [[ ! "$rebuild" =~ ^[Yy]$ ]]; then
            info "Skipping rebuild."
        else
            info "Rebuilding Docker image (this may take 10-20 min)..."
            docker build -t "$ROS_DOCKER_IMAGE" "$ROS_DOCKER_DIR"
        fi
    else
        info "Building Docker image $ROS_DOCKER_IMAGE (this may take 10-20 min)..."
        docker build -t "$ROS_DOCKER_IMAGE" "$ROS_DOCKER_DIR"
    fi

    info "ROS Melodic desktop-full + ti_mmwave_rospkg ready."
    echo ""
    detail "Interactive shell:  bash $ROS_DOCKER_DIR/run-ros-melodic.sh"
    detail "Launch radar:       bash $ROS_DOCKER_DIR/run-ros-melodic.sh roslaunch ti_mmwave_rospkg 1642es2_short_range.launch"
    detail "Rviz visualizer:    bash $ROS_DOCKER_DIR/run-ros-melodic.sh roslaunch ti_mmwave_rospkg rviz_1642_2d.launch"
    detail "Custom config:      Mount /radar_config/<your>.cfg and use mmWaveQuickConfig"
else
    section "6/6 — ROS Melodic (Skipped)"
    detail "Pass --ros to install ROS Melodic desktop-full + ti_mmwave_rospkg (Docker)."
fi

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✓ mmWave Radar Setup Complete                               ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Kernel module:  cp210x (loaded + boot persistent)          ║"
echo "║  udev rules:     /etc/udev/rules.d/99-mmwave-radar.rules   ║"
echo "║  Device links:   /dev/radar_cfg  (config, 115200)           ║"
echo "║                  /dev/radar_data (data,   921600)           ║"
echo "║  Python venv:    $RADAR_VENV"
echo "║  dialout group:  $USER                                      ║"
echo "║                                                              ║"
echo "║  Next steps:                                                 ║"
echo "║  1. Log out and back in (for dialout group)                  ║"
echo "║  2. Connect RS-2944A via USB                                 ║"
echo "║  3. Verify: ls -la /dev/radar_*                              ║"
echo "║  4. Test: screen /dev/radar_cfg 115200                       ║"
echo "║  5. Run bridge:                                              ║"
echo "║     source $RADAR_VENV/bin/activate"
echo "║     python ~/work/cubeship-mmwave-firmware/radar/radar_bridge.py ║"
echo "╚══════════════════════════════════════════════════════════════╝"

if [ "$SKIP_REBOOT" = false ]; then
    echo ""
    warn "A logout/login is needed for dialout group membership."
    read -rp "Log out now? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        info "Logging out..."
        loginctl terminate-user "$USER" 2>/dev/null || {
            warn "Could not auto-logout. Please log out manually."
        }
    fi
fi
