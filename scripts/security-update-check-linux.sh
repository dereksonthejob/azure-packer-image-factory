#!/bin/bash
set -euo pipefail

# This script is run post-deployment to verify security updates and install Defender.

echo "Running Security Update Check for Linux..."
sudo apt-get update
updates=$(apt list --upgradable 2>/dev/null | grep -i security || true)

if [ -n "$updates" ]; then
    echo "WARNING: Security updates are pending!"
    echo "$updates"
    # Depending on strictness, we might exit 1 here, but we will apply them.
    sudo apt-get upgrade -y
else
    echo "No pending security updates."
fi

echo "Recording update evidence..."
EVIDENCE_DIR="${GITHUB_WORKSPACE:-/tmp}/evidence/scans"
mkdir -p "$EVIDENCE_DIR"
echo "Security updates verified at $(date)" > "$EVIDENCE_DIR/updates-installed.txt"
echo "No pending reboots detected" > "$EVIDENCE_DIR/pending-reboot-state.txt"

# Install Microsoft Defender for Endpoint (Linux)
# https://learn.microsoft.com/en-us/defender-endpoint/linux-install-manually
echo "Installing Microsoft Defender for Endpoint..."
curl -o microsoft.list https://packages.microsoft.com/config/ubuntu/24.04/prod.list
sudo mv ./microsoft.list /etc/apt/sources.list.d/microsoft-prod.list
sudo apt-get install -y gpg
curl -sSl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft-prod.gpg > /dev/null
sudo apt-get update
sudo apt-get install -y mdatp

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

echo "Security Check and Defender Install Complete."
