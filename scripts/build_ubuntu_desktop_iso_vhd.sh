#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 127; }
}

for c in curl sha256sum awk grep xorriso qemu-img qemu-system-x86_64 genisoimage timeout; do
  require_cmd "$c"
done

ISO_VERSION="${ISO_VERSION:-24.04.4}"
ISO_SERIES_PATH="${ISO_SERIES_PATH:-noble}"
ARCH="${ARCH:-amd64}"
WORK_DIR="${WORK_DIR:-$PWD/.work-iso-build}"
OUT_DIR="${OUT_DIR:-$PWD/artifacts/iso-autoinstall}"
DISK_SIZE_GB="${DISK_SIZE_GB:-64}"
VM_MEMORY_MB="${VM_MEMORY_MB:-8192}"
VM_CPUS="${VM_CPUS:-4}"
BUILD_TIMEOUT_SEC="${BUILD_TIMEOUT_SEC:-21600}"
QEMU_ACCEL="${QEMU_ACCEL:-auto}"
REQUIRE_KVM="${REQUIRE_KVM:-false}"

ISO_FILE="ubuntu-${ISO_VERSION}-desktop-${ARCH}.iso"
ISO_URL="https://releases.ubuntu.com/${ISO_SERIES_PATH}/${ISO_FILE}"
RAW_FILE="ubuntu-desktop-${ISO_VERSION}-autoinstall-${ARCH}.raw"
VHD_FILE="ubuntu-desktop-${ISO_VERSION}-autoinstall-${ARCH}.vhd"
META_JSON="ubuntu-desktop-${ISO_VERSION}-autoinstall-${ARCH}.metadata.json"

mkdir -p "$WORK_DIR" "$OUT_DIR"
cd "$WORK_DIR"

BUILD_START_EPOCH="$(date -u +%s)"
BUILD_STARTED_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

HOST_KVM_DEVICE="absent"
if [[ -e /dev/kvm ]]; then
  HOST_KVM_DEVICE="present"
fi

has_kvm_support() {
  [[ -e /dev/kvm ]] || return 1
  if command -v kvm-ok >/dev/null 2>&1; then
    kvm-ok >/dev/null 2>&1 || return 1
  fi
  return 0
}

if [[ "$QEMU_ACCEL" == "auto" ]]; then
  if has_kvm_support; then
    QEMU_ACCEL="kvm"
  else
    QEMU_ACCEL="tcg"
  fi
fi

if [[ "$QEMU_ACCEL" != "kvm" && "$QEMU_ACCEL" != "tcg" ]]; then
  echo "Unsupported QEMU_ACCEL value: $QEMU_ACCEL (allowed: auto|kvm|tcg)" >&2
  exit 1
fi

if [[ "$REQUIRE_KVM" == "true" && "$QEMU_ACCEL" != "kvm" ]]; then
  echo "KVM is required but unavailable on this runner" >&2
  exit 1
fi

echo "Downloading ISO: ${ISO_URL}"
curl -fL --retry 5 --retry-delay 5 -o "$ISO_FILE" "$ISO_URL"
curl -fL --retry 5 --retry-delay 5 -o SHA256SUMS "https://releases.ubuntu.com/${ISO_SERIES_PATH}/SHA256SUMS"

EXPECTED_SHA="$(awk -v f="$ISO_FILE" '$2 == f || $2 == ("*" f) {print $1; exit}' SHA256SUMS)"
if [[ -z "$EXPECTED_SHA" ]]; then
  echo "Unable to find expected checksum for ${ISO_FILE}" >&2
  exit 1
fi
ACTUAL_SHA="$(sha256sum "$ISO_FILE" | awk '{print $1}')"
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  echo "Checksum mismatch for ${ISO_FILE}" >&2
  echo "expected=$EXPECTED_SHA actual=$ACTUAL_SHA" >&2
  exit 1
fi

echo "Creating autoinstall seed media"
cat > user-data <<'EOF'
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: ubuntu-desktop-auto
    username: azureuser
    password: "$6$rounds=4096$pk4W5ew6FboS4WHn$9xIuz7A3Nj7Q1h.LjJvwS18q2BkI1vG8LI0X0j/9mV8JbjM4Vz8v96e3q0H7dN6KLRd4j5WvbjdnN4o16q3wU0"
  keyboard:
    layout: us
  locale: en_US.UTF-8
  timezone: UTC
  storage:
    layout:
      name: direct
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - xrdp
  late-commands:
    - curtin in-target --target=/target -- systemctl enable xrdp
    - curtin in-target --target=/target -- systemctl set-default graphical.target
  shutdown: poweroff
EOF

cat > meta-data <<'EOF'
instance-id: ubuntu-desktop-autoinstall
local-hostname: ubuntu-desktop-auto
EOF

genisoimage -quiet -output seed.iso -volid CIDATA -joliet -rock user-data meta-data

echo "Extracting kernel/initrd from ISO"
xorriso -osirrox on -indev "$ISO_FILE" -extract /casper/vmlinuz "$WORK_DIR/vmlinuz" -extract /casper/initrd "$WORK_DIR/initrd" >/dev/null 2>&1

echo "Creating raw disk (${DISK_SIZE_GB}G)"
qemu-img create -f raw "$RAW_FILE" "${DISK_SIZE_GB}G" >/dev/null

echo "Running unattended install (timeout ${BUILD_TIMEOUT_SEC}s)"
set +e
QEMU_MACHINE_ARG=(-machine q35)
QEMU_ACCEL_ARG=(-accel tcg)
if [[ "$QEMU_ACCEL" == "kvm" ]]; then
  QEMU_ACCEL_ARG=(-accel kvm)
fi
timeout --preserve-status "$BUILD_TIMEOUT_SEC" \
  qemu-system-x86_64 \
  "${QEMU_MACHINE_ARG[@]}" \
  "${QEMU_ACCEL_ARG[@]}" \
  -cpu max \
  -smp "$VM_CPUS" \
  -m "$VM_MEMORY_MB" \
  -display none \
  -serial stdio \
  -kernel "$WORK_DIR/vmlinuz" \
  -initrd "$WORK_DIR/initrd" \
  -append "autoinstall console=ttyS0,115200n8 ---" \
  -drive file="$WORK_DIR/$ISO_FILE",media=cdrom,readonly=on \
  -drive file="$WORK_DIR/seed.iso",media=cdrom,readonly=on \
  -drive file="$WORK_DIR/$RAW_FILE",if=virtio,format=raw \
  -netdev user,id=n1 \
  -device virtio-net-pci,netdev=n1 \
  -no-reboot
QEMU_RC=$?
set -e
if [[ "$QEMU_RC" -eq 124 ]]; then
  echo "Autoinstall timed out after ${BUILD_TIMEOUT_SEC}s" >&2
  exit 1
fi
if [[ "$QEMU_RC" -ne 0 ]]; then
  echo "Autoinstall failed with exit code $QEMU_RC" >&2
  exit "$QEMU_RC"
fi

echo "Converting raw disk to fixed VHD"
CONVERT_START_EPOCH="$(date -u +%s)"
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size "$RAW_FILE" "$OUT_DIR/$VHD_FILE"
CONVERT_END_EPOCH="$(date -u +%s)"
CONVERT_DURATION_SEC="$((CONVERT_END_EPOCH - CONVERT_START_EPOCH))"
VHD_SHA="$(sha256sum "$OUT_DIR/$VHD_FILE" | awk '{print $1}')"
VHD_SIZE="$(stat -c%s "$OUT_DIR/$VHD_FILE" 2>/dev/null || stat -f%z "$OUT_DIR/$VHD_FILE")"
BUILD_END_EPOCH="$(date -u +%s)"
BUILD_ENDED_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
BUILD_DURATION_SEC="$((BUILD_END_EPOCH - BUILD_START_EPOCH))"

cat > "$OUT_DIR/$META_JSON" <<EOF
{
  "iso_version": "${ISO_VERSION}",
  "iso_file": "${ISO_FILE}",
  "iso_sha256": "${ACTUAL_SHA}",
  "vhd_file": "${VHD_FILE}",
  "vhd_sha256": "${VHD_SHA}",
  "vhd_size": ${VHD_SIZE},
  "series_path": "${ISO_SERIES_PATH}",
  "arch": "${ARCH}"
}
EOF

echo "ISO_VERSION=${ISO_VERSION}"
echo "ISO_FILE=${ISO_FILE}"
echo "ISO_SHA256=${ACTUAL_SHA}"
echo "VHD_FILE=${VHD_FILE}"
echo "VHD_SHA256=${VHD_SHA}"
echo "VHD_SIZE_BYTES=${VHD_SIZE}"
echo "HOST_KVM_DEVICE=${HOST_KVM_DEVICE}"
echo "QEMU_ACCEL=${QEMU_ACCEL}"
echo "BUILD_STARTED_UTC=${BUILD_STARTED_UTC}"
echo "BUILD_ENDED_UTC=${BUILD_ENDED_UTC}"
echo "BUILD_DURATION_SEC=${BUILD_DURATION_SEC}"
echo "CONVERT_DURATION_SEC=${CONVERT_DURATION_SEC}"
echo "METADATA_FILE=${META_JSON}"

echo "Build complete: $OUT_DIR/$VHD_FILE"
