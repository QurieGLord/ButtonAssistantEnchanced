#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Setup colors for cozy CLI feedback
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Determine script directory and details
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_NAME="$(basename "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
ZIP_NAME="${ADDON_NAME}.zip"
OUTPUT_ZIP="${PARENT_DIR}/${ZIP_NAME}"

echo -e "${BLUE}🍺 Preparing release package for ${YELLOW}${ADDON_NAME}${NC}..."

# Check if zip is installed
if ! command -v zip &> /dev/null; then
    echo -e "${RED}Error: 'zip' utility is not installed. Grab a brew and install it first.${NC}"
    exit 1
fi

# Clean up any existing old zip in the output directory
if [ -f "$OUTPUT_ZIP" ]; then
    echo -e "${YELLOW}Cleaning up old archive...${NC}"
    rm -f "$OUTPUT_ZIP"
fi

# Package the addon from the parent directory to keep folder structure
echo -e "${BLUE}Zipping addon files (excluding git stuff and scripts)...${NC}"
(
    cd "$PARENT_DIR"
    zip -r "$ZIP_NAME" "$ADDON_NAME" \
        -x "$ADDON_NAME/.git*" \
        -x "$ADDON_NAME/*/.git*" \
        -x "$ADDON_NAME/pack_release.sh" \
        -x "$ADDON_NAME/*.zip" \
        -x "$ADDON_NAME/*.tgz" \
        -x "$ADDON_NAME/*.tar.gz"
)

echo -e "${GREEN}🍻 Cheers! Release archive created successfully:${NC}"
echo -e "${YELLOW}${OUTPUT_ZIP}${NC}"
