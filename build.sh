#!/bin/bash

set -e

# check for root permissions
if [[ "$(id -u)" != 0 ]]; then
  echo "E: Requires root permissions" > /dev/stderr
  exit 1
fi

# get config
if [ -n "$1" ]; then
  CONFIG_FILE="$1"
else
  CONFIG_FILE="etc/terraform.conf"
fi

# Use a container-local build directory to avoid noexec issues
CONTAINER_BUILD_DIR="/tmp/build"
HOST_WORKING_DIR="$PWD"
source "$HOST_WORKING_DIR"/"$CONFIG_FILE"

echo -e "
#----------------------#
# INSTALL DEPENDENCIES #
#----------------------#
"
apt-get update
apt-get install -y live-build patch gnupg2 binutils zstd dirmngr curl

# Try Release file first, then Launchpad API if not found
KEY_IDS=$(curl -s http://ppa.launchpad.net/elementary-os/daily/ubuntu/dists/noble/Release | grep -E 'Signed-By|Signing-Key|fingerprint' | grep -oE '[A-F0-9]{16,40}' | sort | uniq)
# Fallback: Try Launchpad API if none found
if [ -z "$KEY_IDS" ]; then
  echo "No key found in Release file, trying Launchpad API..."
  KEY_IDS=$(curl -s "https://api.launchpad.net/1.0/~elementary-os/+archive/ubuntu/daily" | grep -oE '[A-F0-9]{16,40}')
fi
# If still not found, try to extract from apt error (if available)
if [ -z "$KEY_IDS" ]; then
  echo "ERROR: Could not detect any PPA signing keys!"
  echo "Please specify the required key(s) via the KEY_IDS environment variable."
  exit 1
fi

for KEY_ID in $KEY_IDS; do
  echo "Attempting to import key $KEY_ID..."
  # Try both full and short key IDs
  for SEARCH_ID in "$KEY_ID" "${KEY_ID: -16}"; do
    KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$SEARCH_ID"
    echo "Fetching $KEY_URL"
    KEY_TMP="/tmp/elementary-os-$SEARCH_ID.gpg"
    if curl --max-time 15 -fsSL "$KEY_URL" | grep -q "BEGIN PGP PUBLIC KEY BLOCK"; then
      curl --max-time 15 -fsSL "$KEY_URL" | gpg --dearmor -o "$KEY_TMP"
      cp "$KEY_TMP" "/etc/apt/trusted.gpg.d/elementary-os-$SEARCH_ID.gpg"
      # Also append to /etc/apt/trusted.gpg for debootstrap compatibility
      gpg --no-default-keyring --keyring "$KEY_TMP" --export >> /etc/apt/trusted.gpg
      gpg --no-default-keyring --keyring "$KEY_TMP" --export >> /etc/apt/trusted.gpg
      rm -f "$KEY_TMP"
      break
    else
      echo "WARNING: Key $SEARCH_ID could not be imported. Trying next form."
    fi
  done
  echo "Finished attempt for $KEY_ID"
done

echo "Key import complete, running apt-get update..."
apt-get update || { echo "apt-get update failed"; exit 1; }

# Import the Ubuntu Noble archive key (required for debootstrap)
UBUNTU_ARCHIVE_KEY="871920D1991BC93C"
KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$UBUNTU_ARCHIVE_KEY"
KEY_TMP="/tmp/ubuntu-archive-$UBUNTU_ARCHIVE_KEY.gpg"
echo "Importing Ubuntu archive key $UBUNTU_ARCHIVE_KEY..."
if curl --max-time 15 -fsSL "$KEY_URL" | grep -q "BEGIN PGP PUBLIC KEY BLOCK"; then
  curl --max-time 15 -fsSL "$KEY_URL" | gpg --dearmor -o "$KEY_TMP"
  cp "$KEY_TMP" "/etc/apt/trusted.gpg.d/ubuntu-archive-$UBUNTU_ARCHIVE_KEY.gpg"
  gpg --no-default-keyring --keyring "$KEY_TMP" --export >> /etc/apt/trusted.gpg
  echo "Ubuntu archive key $UBUNTU_ARCHIVE_KEY imported."
else
  echo "ERROR: Could not import Ubuntu archive key $UBUNTU_ARCHIVE_KEY!"
  exit 1
fi

ln -sfn /usr/share/debootstrap/scripts/gutsy /usr/share/debootstrap/scripts/noble

build () {
  BUILD_ARCH="$1"

  mkdir -p "$CONTAINER_BUILD_DIR/tmp/$BUILD_ARCH"
  cd "$CONTAINER_BUILD_DIR/tmp/$BUILD_ARCH" || exit

  # remove old configs and copy over new
  rm -rf config auto
  cp -r "$HOST_WORKING_DIR"/etc/* .
  cp -f "$HOST_WORKING_DIR"/"$CONFIG_FILE" terraform.conf

  if [ "$INCLUDE_APPCENTER" = "yes" ]; then
    cp "config/appcenter/appcenter.list.binary" "config/archives/appcenter.list.binary"
    cp "config/appcenter/appcenter.key.binary" "config/archives/appcenter.key.binary"
  fi

  echo -e "
#------------------#
# LIVE-BUILD CLEAN #
#------------------#
"
  lb clean

  echo -e "
#-------------------#
# LIVE-BUILD CONFIG #
#-------------------#
"
  lb config

  echo -e "
#------------------#
# LIVE-BUILD BUILD #
#------------------#
"
  lb build

  echo -e "
#---------------------------#
# MOVE OUTPUT TO BUILDS DIR #
#---------------------------#
"

  YYYYMMDD="$(date +%Y%m%d)"
  OUTPUT_DIR="$CONTAINER_BUILD_DIR/builds/$BUILD_ARCH"
  mkdir -p "$OUTPUT_DIR"
  FNAME="elementaryos-$VERSION-$CHANNEL.$YYYYMMDD$OUTPUT_SUFFIX"
  mv "$CONTAINER_BUILD_DIR/tmp/$BUILD_ARCH/live-image-$BUILD_ARCH.hybrid.iso" "$OUTPUT_DIR/${FNAME}.iso"

  cd $OUTPUT_DIR
  md5sum "${FNAME}.iso" | tee "${FNAME}.md5.txt"
  sha256sum "${FNAME}.iso" | tee "${FNAME}.sha256.txt"
  cd "$CONTAINER_BUILD_DIR"

  # Copy output back to host working directory
  mkdir -p "$HOST_WORKING_DIR/builds/$BUILD_ARCH"
  cp "$OUTPUT_DIR/"* "$HOST_WORKING_DIR/builds/$BUILD_ARCH/"
}

# remove old builds before creating new ones (on host)
rm -rf "$HOST_WORKING_DIR"/builds

if [[ "$ARCH" == "all" ]]; then
    build amd64
    build i386
else
    build "$ARCH"
fi