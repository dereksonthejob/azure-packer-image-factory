#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# ── Security Update Check + CVE Hardening Script ──────────────────────────────
# Runs inside the Packer build VM (not on the GitHub runner).
# Outputs all results to stdout so Packer captures them in packerbuild.log.
# Commercial Marketplace Policy 200: Defender must be installed, scanned,
# then COMPLETELY REMOVED before deprovision / sysprep.

echo "=== Linux Security Update Check ==="
echo "Started at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── 1. Kernel boot parameter compliance check ──────────────────────────────────
# Azure Marketplace Policy 200 requires `console=ttyS0` in kernel cmdline.
echo ""
echo "=== KERNEL BOOT PARAMETER AUDIT ==="
CURRENT_CMDLINE=$(cat /proc/cmdline)
echo "Current kernel cmdline: $CURRENT_CMDLINE"
if echo "$CURRENT_CMDLINE" | grep -q "console=ttyS0"; then
    echo "OK: console=ttyS0 present."
else
    echo "WARNING: console=ttyS0 NOT FOUND in kernel cmdline — this will fail Azure Marketplace certification."
    echo "REMEDIATION: Ensure GRUB_CMDLINE_LINUX in /etc/default/grub includes 'console=ttyS0' and run 'update-grub'."
    # Auto-remediate if grub is present
    if [ -f /etc/default/grub ]; then
        echo "Attempting auto-remediation of /etc/default/grub..."
        if grep -q 'GRUB_CMDLINE_LINUX=' /etc/default/grub; then
            sudo sed -i 's/GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 console=ttyS0 earlyprintk=ttyS0"/' /etc/default/grub
        else
            echo 'GRUB_CMDLINE_LINUX="console=ttyS0 earlyprintk=ttyS0"' | sudo tee -a /etc/default/grub
        fi
        sudo update-grub 2>&1 || true
        echo "GRUB updated. Verifying..."
        grep 'GRUB_CMDLINE_LINUX' /etc/default/grub
    fi
fi

# ── 2. Apply security updates ──────────────────────────────────────────────────
echo ""
echo "=== SECURITY UPDATES ==="

if command -v apt-get &> /dev/null; then
    # ── Debian/Ubuntu ─────────────────────────────────────────────────────────
    export DEBIAN_FRONTEND=noninteractive
    DPKG_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

    echo "Refreshing apt package index..."
    sudo apt-get update -qq

    PENDING=$(apt list --upgradable 2>/dev/null | grep -i security || true)
    if [ -n "$PENDING" ]; then
        echo "Pending security updates found — applying:"
        echo "$PENDING"
        sudo apt-get upgrade -y $DPKG_OPTS
    else
        # Run full upgrade to ensure no CVEs slip through via transitive deps
        echo "No explicit security-tagged updates pending. Running full upgrade for CVE coverage..."
        sudo apt-get upgrade -y $DPKG_OPTS
    fi

    echo "Installed package count: $(dpkg -l | grep -c '^ii')"

    # ── Install, scan, and REMOVE Defender (apt path) ─────────────────────────
    echo ""
    echo "=== DEFENDER SCAN (INSTALL → SCAN → REMOVE) ==="

    echo "Configuring Microsoft package repository..."
    # Detect Ubuntu version dynamically rather than hardcoding 24.04
    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "24.04")
    curl -fsSL "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VERSION}/prod.list" \
        -o /tmp/microsoft-prod.list 2>&1 || {
        # Fallback to 24.04 if the detected version has no repo yet
        echo "WARNING: No Microsoft repo for Ubuntu ${UBUNTU_VERSION}, falling back to 24.04 repo"
        curl -fsSL "https://packages.microsoft.com/config/ubuntu/24.04/prod.list" \
            -o /tmp/microsoft-prod.list
    }
    sudo mv /tmp/microsoft-prod.list /etc/apt/sources.list.d/microsoft-prod.list

    sudo apt-get install -y -qq gpg
    curl -sSl https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor \
        | sudo tee /usr/share/keyrings/microsoft-prod.gpg > /dev/null
    sudo apt-get update -qq

    echo "Installing mdatp..."
    sudo apt-get install -y -qq $DPKG_OPTS mdatp

    echo "--- mdatp health ---"
    mdatp health || echo "WARNING: mdatp health check failed"

    echo "--- mdatp quick scan ---"
    mdatp scan quick 2>&1 || echo "WARNING: mdatp scan failed"

    echo ""
    echo "=== REMOVING DEFENDER (Marketplace Policy 200 Compliance) ==="
    sudo apt-get purge -y mdatp 2>&1 || echo "WARNING: mdatp purge failed"
    sudo rm -rf /etc/opt/microsoft/mdatp
    sudo rm -rf /var/opt/microsoft/mdatp
    sudo rm -f /usr/share/keyrings/microsoft-prod.gpg
    sudo rm -f /etc/apt/sources.list.d/microsoft-prod.list
    sudo apt-get update -qq
    echo "Defender removed and repository cleaned up."

elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
    # ── RHEL / Oracle / AlmaLinux / Rocky ─────────────────────────────────────
    PKG_MGR="yum"
    if command -v dnf &> /dev/null; then PKG_MGR="dnf"; fi
    echo "Using $PKG_MGR for security updates..."

    # Apply security updates
    sudo $PKG_MGR check-update --security 2>&1 || true
    sudo $PKG_MGR update --security -y 2>&1 || true

    echo "Installed package count: $(rpm -qa | wc -l)"

    # ── Install, scan, and REMOVE Defender (rpm path) ─────────────────────────
    echo ""
    echo "=== DEFENDER SCAN (INSTALL → SCAN → REMOVE) ==="
    RHEL_VER=$(rpm -E '%{rhel}' 2>/dev/null || echo "8")
    MDATP_REPO_URL="https://packages.microsoft.com/config/rhel/${RHEL_VER}/prod.repo"

    echo "Configuring Microsoft RHEL ${RHEL_VER} repository..."
    sudo $PKG_MGR install -y curl 2>/dev/null || true
    curl -fsSL "$MDATP_REPO_URL" | sudo tee /etc/yum.repos.d/microsoft-prod.repo > /dev/null

    echo "Installing mdatp..."
    sudo $PKG_MGR install -y mdatp 2>&1 || {
        echo "WARNING: mdatp install failed for RHEL ${RHEL_VER} — skipping Defender scan."
    }

    if command -v mdatp &>/dev/null; then
        echo "--- mdatp health ---"
        mdatp health || echo "WARNING: mdatp health check failed"

        echo "--- mdatp quick scan ---"
        mdatp scan quick 2>&1 || echo "WARNING: mdatp scan failed"

        echo ""
        echo "=== REMOVING DEFENDER (Marketplace Policy 200 Compliance) ==="
        sudo $PKG_MGR remove -y mdatp 2>&1 || echo "WARNING: mdatp remove failed"
        sudo rm -rf /etc/opt/microsoft/mdatp
        sudo rm -rf /var/opt/microsoft/mdatp
        sudo rm -f /etc/yum.repos.d/microsoft-prod.repo
        echo "Defender removed and repository cleaned up."
    fi
else
    echo "ERROR: No recognized package manager found (apt-get, dnf, yum). Cannot apply updates."
    exit 1
fi

# ── 3. Final evidence summary ──────────────────────────────────────────────────
echo ""
echo "=== EVIDENCE SUMMARY ==="
echo "Security updates applied at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"
uname -a

echo ""
echo "=== Security Check Complete ==="


# -----------------------------------------------------------------------
# POLICY CHECK: Accelerated Networking driver (G4)
# hv_netvsc (Hyper-V) or mlx5_core (Mellanox/ConnectX) must be available
# -----------------------------------------------------------------------
echo "=== Checking Accelerated Networking driver availability ==="
if lsmod 2>/dev/null | grep -qE 'hv_netvsc|mlx5_core'; then
    echo "  ✅ Accelerated Networking driver present"
elif modinfo hv_netvsc >/dev/null 2>&1 || modinfo mlx5_core >/dev/null 2>&1; then
    echo "  ⚠️  AN driver available but not loaded — loading hv_netvsc..."
    modprobe hv_netvsc 2>/dev/null || true
else
    echo "  ⚠️  WARNING: No Accelerated Networking driver found (hv_netvsc or mlx5_core)"
    echo "  This may cause Marketplace certification warnings."
fi

# -----------------------------------------------------------------------
# POLICY CHECK: OS Disk Size (G5)
# Linux: root partition must be <= 50 GB for Marketplace certification
# -----------------------------------------------------------------------
echo "=== Checking OS disk size ==="
ROOT_SIZE_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$2); print $2}')
if [ -n "$ROOT_SIZE_GB" ] && [ "$ROOT_SIZE_GB" -le 50 ] 2>/dev/null; then
    echo "  ✅ Root partition: ${ROOT_SIZE_GB}GB (within 50GB limit)"
else
    echo "  ⚠️  WARNING: Root partition ${ROOT_SIZE_GB}GB may exceed 50GB Marketplace limit"
fi
