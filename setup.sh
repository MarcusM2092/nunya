#!/bin/bash

# Universal XMRig Setup Script (MoneroOcean Version)
# Supports: Oracle Cloud, Raspberry Pi, Servers, Termux (Android)
# Run as root (or with sudo), except on Termux

set -e  # Exit on any error

echo "=========================================="
echo "Universal XMRig Mining Setup Script"
echo "MoneroOcean Fork - Auto-Detection Mode"
echo "=========================================="
echo ""

# Configuration - EDIT THESE
WALLET_ADDRESS="46m92LorTA5U87TupyUkQmAtJH85K2gSzHFMfuyBikNWhV5WEYC1Eejhuy7jQJ7QHkKMwGcmWUZVuGzwgch3fp5j31WQGXX"
WORKER_NAME="donation"  # Change this per device
XMRIG_MO_VERSION="6.21.3-mo1"

# Detect environment
detect_environment() {
    # Check if Termux (Android)
    if [ -n "$TERMUX_VERSION" ] || [ -d "$PREFIX" ]; then
        ENV="termux"
        INSTALL_DIR="$HOME/xmrig"
        PKG_MANAGER="pkg"
        USE_SYSTEMD=false
        echo "✓ Detected: Termux (Android)"
        return
    fi
    
    # Check if running as root
    if [ "$EUID" -ne 0 ] && [ "$ENV" != "termux" ]; then 
        echo "❌ Please run as root: sudo bash setup.sh"
        exit 1
    fi
    
    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH_TYPE="x64"
            echo "✓ Architecture: x86_64 (64-bit Intel/AMD)"
            ;;
        aarch64|arm64)
            ARCH_TYPE="arm64"
            echo "✓ Architecture: ARM64 (Raspberry Pi 4/5, Oracle A1, etc.)"
            ;;
        armv7l|armv7)
            ARCH_TYPE="armv7"
            echo "✓ Architecture: ARMv7 (Raspberry Pi 3/Zero 2, older devices)"
            ;;
        *)
            echo "❌ Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    # Detect OS and package manager
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        
        case $OS_NAME in
            ubuntu|debian|raspbian)
                PKG_MANAGER="apt"
                INSTALL_DIR="/opt/xmrig"
                USE_SYSTEMD=true
                echo "✓ OS: $PRETTY_NAME"
                echo "✓ Package Manager: APT"
                ;;
            centos|rhel|ol|rocky|almalinux)
                PKG_MANAGER="dnf"
                INSTALL_DIR="/opt/xmrig"
                USE_SYSTEMD=true
                echo "✓ OS: $PRETTY_NAME"
                echo "✓ Package Manager: DNF/YUM"
                ;;
            fedora)
                PKG_MANAGER="dnf"
                INSTALL_DIR="/opt/xmrig"
                USE_SYSTEMD=true
                echo "✓ OS: Fedora"
                echo "✓ Package Manager: DNF"
                ;;
            arch|manjaro)
                PKG_MANAGER="pacman"
                INSTALL_DIR="/opt/xmrig"
                USE_SYSTEMD=true
                echo "✓ OS: $PRETTY_NAME"
                echo "✓ Package Manager: Pacman"
                ;;
            *)
                echo "⚠ Unknown OS: $OS_NAME (trying generic approach)"
                PKG_MANAGER="apt"
                INSTALL_DIR="/opt/xmrig"
                USE_SYSTEMD=true
                ;;
        esac
    else
        echo "⚠ Cannot detect OS, assuming Debian-based"
        PKG_MANAGER="apt"
        INSTALL_DIR="/opt/xmrig"
        USE_SYSTEMD=true
    fi
    
    ENV="server"
}

# Detect CPU and estimate hashrate
detect_cpu() {
    CPU_CORES=$(nproc)
    
    # Get CPU model
    if [ -f /proc/cpuinfo ]; then
        CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs)
        if [ -z "$CPU_MODEL" ]; then
            CPU_MODEL=$(grep -m1 "Processor" /proc/cpuinfo | cut -d':' -f2 | xargs)
        fi
    else
        CPU_MODEL="Unknown CPU"
    fi
    
    # Estimate hashrate per core based on architecture and CPU
    case $ARCH_TYPE in
        x64)
            # x86_64 servers: 200-800 H/s per core depending on CPU
            HASHRATE_PER_CORE=400
            ;;
        arm64)
            # Check if it's high-performance ARM
            if echo "$CPU_MODEL" | grep -iq "neoverse\|ampere\|graviton"; then
                HASHRATE_PER_CORE=500  # Oracle A1, AWS Graviton
            else
                HASHRATE_PER_CORE=150  # Raspberry Pi 4/5
            fi
            ;;
        armv7)
            HASHRATE_PER_CORE=50  # Raspberry Pi 3, very weak
            ;;
    esac
    
    ESTIMATED_HASHRATE=$((CPU_CORES * HASHRATE_PER_CORE))
    
    # Calculate optimal mining threads (leave 1 core free for system)
    MINING_THREADS=$((CPU_CORES - 1))
    if [ $MINING_THREADS -lt 1 ]; then
        MINING_THREADS=1
    fi
    
    echo "✓ CPU: $CPU_MODEL"
    echo "✓ Cores: $CPU_CORES"
    echo "✓ Mining Threads: $MINING_THREADS"
    echo "✓ Estimated Hashrate: ~${ESTIMATED_HASHRATE} H/s"
}

# Select appropriate pool port based on hashrate
select_pool_port() {
    if [ $ESTIMATED_HASHRATE -lt 500 ]; then
        POOL_URL="gulf.moneroocean.stream:443"
        POOL_DIFF="100 diff (<500 H/s)"
    elif [ $ESTIMATED_HASHRATE -lt 2000 ]; then
        POOL_URL="gulf.moneroocean.stream:20001"
        POOL_DIFF="10000 diff (500-2000 H/s)"
    elif [ $ESTIMATED_HASHRATE -lt 4000 ]; then
        POOL_URL="gulf.moneroocean.stream:20002"
        POOL_DIFF="20000 diff (2-4 kH/s)"
    else
        POOL_URL="gulf.moneroocean.stream:20004"
        POOL_DIFF="40000 diff (4+ kH/s)"
    fi
    
    echo "✓ Selected Pool: $POOL_URL ($POOL_DIFF)"
}

# Install dependencies based on package manager
install_dependencies() {
    echo ""
    echo "[1/5] Installing dependencies..."
    
    case $PKG_MANAGER in
        apt)
            apt update -qq
            apt install -y wget tar hwloc libhwloc-dev ca-certificates 2>/dev/null || \
            apt install -y wget tar hwloc ca-certificates 2>/dev/null || true
            ;;
        dnf)
            dnf install -y wget tar hwloc-libs 2>/dev/null || \
            yum install -y wget tar hwloc-libs 2>/dev/null || true
            ;;
        pacman)
            pacman -Sy --noconfirm wget tar hwloc 2>/dev/null || true
            ;;
        pkg)
            pkg update -y
            pkg install -y wget tar 2>/dev/null || true
            ;;
    esac
    
    echo "✓ Dependencies installed"
}

# Download and install XMRig
install_xmrig() {
    echo ""
    echo "[2/5] Downloading XMRig..."
    
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Determine download URL
    case $ARCH_TYPE in
        x64)
            XMRIG_FILE="xmrig-${XMRIG_MO_VERSION}-linux-static-x64.tar.gz"
            ;;
        arm64)
            XMRIG_FILE="xmrig-${XMRIG_MO_VERSION}-linux-static-arm64.tar.gz"
            ;;
        armv7)
            XMRIG_FILE="xmrig-${XMRIG_MO_VERSION}-linux-static-armv7l.tar.gz"
            ;;
    esac
    
    DOWNLOAD_URL="https://github.com/MoneroOcean/xmrig/releases/download/v${XMRIG_MO_VERSION}/${XMRIG_FILE}"
    
    # Download with retry
    for i in {1..3}; do
        if wget -q --show-progress "$DOWNLOAD_URL" 2>/dev/null || wget "$DOWNLOAD_URL"; then
            break
        fi
        echo "⚠ Download failed, retrying ($i/3)..."
        sleep 2
    done
    
    # Extract
    echo "[3/5] Extracting..."
    tar -xzf "$XMRIG_FILE" 2>/dev/null || tar -xf "$XMRIG_FILE"
    cp xmrig-${XMRIG_MO_VERSION}/* . 2>/dev/null || true
    rm -rf xmrig-${XMRIG_MO_VERSION} "$XMRIG_FILE"
    chmod +x xmrig
    
    echo "✓ XMRig installed to $INSTALL_DIR"
}

# Configure system optimizations
configure_system() {
    echo ""
    echo "[4/5] Configuring system..."
    
    # Disable SELinux if it exists (Oracle/RHEL)
    if command -v setenforce >/dev/null 2>&1; then
        setenforce 0 2>/dev/null || true
        if [ -f /etc/selinux/config ]; then
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
        fi
        echo "✓ SELinux disabled"
    fi
    
    # Enable huge pages for better performance (server only)
    if [ "$ENV" = "server" ] && [ "$EUID" -eq 0 ]; then
        sysctl -w vm.nr_hugepages=128 2>/dev/null || true
        echo "vm.nr_hugepages=128" >> /etc/sysctl.conf 2>/dev/null || true
        echo "✓ Huge pages enabled"
    fi
}

# Create service (systemd or manual)
create_service() {
    echo ""
    echo "[5/5] Creating service..."
    
    if [ "$USE_SYSTEMD" = true ]; then
        # Create systemd service
        cat > /etc/systemd/system/xmrig.service <<EOF
[Unit]
Description=XMRig Monero Miner
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/xmrig -o $POOL_URL -u $WALLET_ADDRESS --tls -p $WORKER_NAME -k --threads=$MINING_THREADS --cpu-priority=3 --coin monero
Restart=always
RestartSec=10
Nice=10
CPUQuota=85%

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable xmrig
        systemctl start xmrig
        
        echo "✓ Systemd service created and started"
    else
        # For Termux - create simple start script
        cat > "$INSTALL_DIR/start.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
cd $INSTALL_DIR
./xmrig -o $POOL_URL -u $WALLET_ADDRESS --tls -p $WORKER_NAME -k --threads=$MINING_THREADS --cpu-priority=3 --coin monero
EOF
        chmod +x "$INSTALL_DIR/start.sh"
        
        # Start in background
        nohup "$INSTALL_DIR/start.sh" > "$INSTALL_DIR/xmrig.log" 2>&1 &
        
        echo "✓ XMRig started in background"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "Installation Complete!"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Device: $(hostname)"
    echo "  Worker: $WORKER_NAME"
    echo "  Threads: $MINING_THREADS / $CPU_CORES cores"
    echo "  Est. Hashrate: ~${ESTIMATED_HASHRATE} H/s"
    echo "  Pool: $POOL_URL"
    echo ""
    
    if [ "$USE_SYSTEMD" = true ]; then
        echo "Management Commands:"
        echo "  Check status:  systemctl status xmrig"
        echo "  View logs:     journalctl -u xmrig -f"
        echo "  Stop mining:   systemctl stop xmrig"
        echo "  Start mining:  systemctl start xmrig"
        echo "  Restart:       systemctl restart xmrig"
    else
        echo "Management Commands:"
        echo "  View logs:     cat $INSTALL_DIR/xmrig.log"
        echo "  Stop mining:   pkill xmrig"
        echo "  Start mining:  $INSTALL_DIR/start.sh &"
        echo "  Manual start:  cd $INSTALL_DIR && ./xmrig [options]"
    fi
    
    echo ""
    echo "Files:"
    echo "  Binary: $INSTALL_DIR/xmrig"
    echo "  Config: $INSTALL_DIR/config.json (optional)"
    if [ "$USE_SYSTEMD" = true ]; then
        echo "  Service: /etc/systemd/system/xmrig.service"
    fi
    echo ""
    
    if [ "$USE_SYSTEMD" = true ]; then
        sleep 2
        systemctl status xmrig --no-pager || true
    else
        echo "Mining started! Check logs to verify it's working."
    fi
}

# Main execution
main() {
    detect_environment
    detect_cpu
    select_pool_port
    echo ""
    echo "=========================================="
    
    install_dependencies
    install_xmrig
    configure_system
    create_service
    print_summary
}

# Run main function
main
