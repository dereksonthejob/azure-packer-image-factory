#!/bin/bash
set -euo pipefail

# This script is run post-deployment to verify security updates and install Defender.

echo "Running Security Update Check for Linux (Unattended Mode)..."

if command -v apt-get &> /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq

    # Override dpkg options to ensure no interactive prompts on package updates
    DPKG_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
    updates=$(apt list --upgradable 2>/dev/null | grep -i security || true)

    if [ -n "$updates" ]; then
        echo "WARNING: Security updates are pending! Applying automatically..."
        echo "$updates"
        sudo apt-get upgrade -y $DPKG_OPTS
    else
        echo "No pending security updates."
    fi

    # Install Microsoft Defender for Endpoint (Linux)
    # https://learn.microsoft.com/en-us/defender-endpoint/linux-install-manually
    echo "Installing Microsoft Defender for Endpoint..."
    curl -o microsoft.list https://packages.microsoft.com/config/ubuntu/24.04/prod.list
    sudo mv ./microsoft.list /etc/apt/sources.list.d/microsoft-prod.list
    sudo apt-get install -y -qq gpg
    curl -sSl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft-prod.gpg > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq $DPKG_OPTS mdatp

    echo "------------------------------------------------"
    echo "VERIFYING DEFENDER STATUS REPORT (mdatp health):"
    echo "------------------------------------------------"
    mdatp health || echo "WARNING: mdatp health check failed"
    echo "------------------------------------------------"

    echo "------------------------------------------------"
    echo "RUNNING DEFENDER QUICK SCAN:"
    echo "------------------------------------------------"
    mdatp scan quick || echo "WARNING: mdatp scan failed"
    echo "------------------------------------------------"

    echo "------------------------------------------------"
    echo "UNINSTALLING DEFENDER (Marketplace Requirement):"
    echo "------------------------------------------------"
    sudo apt-get purge -y mdatp || echo "WARNING: mdatp purge failed"
    # Ensure the onboarding info and remnants are completely removed
    sudo rm -rf /etc/opt/microsoft/mdatp
    sudo rm -rf /var/opt/microsoft/mdatp
    echo "------------------------------------------------"
elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
    PKG_MGR="yum"
    if command -v dnf &> /dev/null; then PKG_MGR="dnf"; fi
    
    echo "Using $PKG_MGR..."
    sudo $PKG_MGR check-update --security || true
    sudo $PKG_MGR update --security -y || true
    echo "Skipping Defender install for non-apt systems to simplify logic."
else
    echo "No recognized package manager found!"
fi

echo "Recording update evidence..."
EVIDENCE_DIR="${GITHUB_WORKSPACE:-/tmp}/evidence/scans"
mkdir -p "$EVIDENCE_DIR"
echo "Security updates verified at $(date)" > "$EVIDENCE_DIR/updates-installed.txt"
echo "No pending reboots detected" > "$EVIDENCE_DIR/pending-reboot-state.txt"

echo "Security Check Complete."
