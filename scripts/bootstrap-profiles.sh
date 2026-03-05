#!/bin/bash
set -e

# Configuration
RG_NAME="RG-PACKER-IMAGE-FACTORY-EASTUS"
GALLERY_NAME="acgpackerfactoryeastus"
PUBLISHER_NAME="DerekColeman"
PROFILES_DIR="profiles"

# Ensure profiles directory exists
mkdir -p "$PROFILES_DIR"

# Function to create definition and profile
create_profile() {
    local profile_id=$1
    local os_family=$2
    local offer=$3
    local sku=$4
    local definition_name=$5
    local gen=$6
    local vm_size=$7
    local os_line=$8
    local publisher=${9}

    echo "========================================================"
    echo "Creating Profile: $profile_id ($gen)"
    echo "========================================================"

    # Determine OS State and Type for az cli
    local os_type="Windows"
    if [ "$os_family" == "linux" ]; then
        os_type="Linux"
    fi

    # Create Image Definition in Azure
    echo "Creating Azure Compute Gallery Definition ($definition_name)..."
    az sig image-definition create \
        -g "$RG_NAME" \
        -r "$GALLERY_NAME" \
        -i "$definition_name" \
        -p "$PUBLISHER_NAME" \
        -f "$offer" \
        -s "$sku" \
        --os-type "$os_type" \
        --os-state Generalized \
        --hyper-v-generation "$gen" \
        --only-show-errors

    # Create profile.yml
    local profile_path="$PROFILES_DIR/$profile_id/profile.yml"
    mkdir -p "$PROFILES_DIR/$profile_id"
    
    echo "Writing $profile_path..."
    
    if [ "$os_family" == "linux" ]; then
        cat <<EOF > "$profile_path"
profile_id: $profile_id
os_family: $os_family
os_line: $os_line
source_image_urn: $publisher:$offer:$sku:latest
gallery:
  image_definition: $definition_name
  publisher: $PUBLISHER_NAME
  offer: $offer
  sku: $sku
test:
  vm_size: $vm_size
EOF
    else
        cat <<EOF > "$profile_path"
profile_id: $profile_id
os_family: $os_family
source_image_urn: $publisher:$offer:$sku:latest
gallery:
  image_definition: $definition_name
  publisher: $PUBLISHER_NAME
  offer: $offer
  sku: $sku
test:
  vm_size: $vm_size
EOF
    fi

    # Append security_type for Gen2
    if [ "$gen" == "V2" ]; then
        sed -i '' '/source_image_urn:/a\
security_type: TrustedLaunchSupported\
' "$profile_path"
    fi
    
    echo "Done with $profile_id."
    echo ""
}

# --- SQL SERVER 2025 ---
create_profile "sql2025-ws2025-enterprise" "windows" "sql2025-ws2025" "enterprise-gen2" "imgdef-sql2025-ws2025-enterprise-gen2" "V2" "Standard_D4as_v5" "" "MicrosoftSQLServer"
create_profile "sql2025-ws2025-standard" "windows" "sql2025-ws2025" "standard-gen2" "imgdef-sql2025-ws2025-standard-gen2" "V2" "Standard_D4as_v5" "" "MicrosoftSQLServer"
create_profile "sql2025-ws2025-developer" "windows" "sql2025-ws2025" "entdev-gen2" "imgdef-sql2025-ws2025-developer-gen2" "V2" "Standard_D4as_v5" "" "MicrosoftSQLServer"

# --- SQL SERVER 2019 (Gen 2) ---
create_profile "sql2019-ws2022-enterprise" "windows" "sql2019-ws2022" "enterprise-gen2" "imgdef-sql2019-ws2022-enterprise-gen2" "V2" "Standard_D4as_v5" "" "MicrosoftSQLServer"
create_profile "sql2019-ws2022-standard" "windows" "sql2019-ws2022" "standard-gen2" "imgdef-sql2019-ws2022-standard-gen2" "V2" "Standard_D4as_v5" "" "MicrosoftSQLServer"
create_profile "sql2019-ws2022-developer" "windows" "sql2019-ws2022" "sqldev-gen2" "imgdef-sql2019-ws2022-developer-gen2" "V2" "Standard_D4as_v5" "" "MicrosoftSQLServer"

# --- SQL SERVER 2019 (Gen 1) ---
create_profile "sql2019-ws2022-enterprise-gen1" "windows" "sql2019-ws2022" "enterprise" "imgdef-sql2019-ws2022-enterprise" "V1" "Standard_D4as_v5" "" "MicrosoftSQLServer"
create_profile "sql2019-ws2022-standard-gen1" "windows" "sql2019-ws2022" "standard" "imgdef-sql2019-ws2022-standard" "V1" "Standard_D4as_v5" "" "MicrosoftSQLServer"
create_profile "sql2019-ws2022-developer-gen1" "windows" "sql2019-ws2022" "sqldev" "imgdef-sql2019-ws2022-developer" "V1" "Standard_D4as_v5" "" "MicrosoftSQLServer"

# --- UBUNTU 24.04 MINIMAL ---
create_profile "ubuntu-server-2404-minimal" "linux" "ubuntu-24_04-lts" "minimal" "imgdef-ubuntu-server-2404-minimal-gen2" "V2" "Standard_D2ads_v6" "ubuntu-server" "Canonical"
create_profile "ubuntu-server-2404-minimal-gen1" "linux" "ubuntu-24_04-lts" "minimal-gen1" "imgdef-ubuntu-server-2404-minimal" "V1" "Standard_D2ads_v6" "ubuntu-server" "Canonical"

# --- UBUNTU 22.04 MINIMAL ---
create_profile "ubuntu-server-2204-minimal" "linux" "ubuntu-22_04-lts" "ubuntu-minimal" "imgdef-ubuntu-server-2204-minimal-gen2" "V2" "Standard_D2ads_v6" "ubuntu-server" "Canonical"
create_profile "ubuntu-server-2204-minimal-gen1" "linux" "ubuntu-22_04-lts" "ubuntu-minimal-gen1" "imgdef-ubuntu-server-2204-minimal" "V1" "Standard_D2ads_v6" "ubuntu-server" "Canonical"

echo "All profiles created successfully!"
