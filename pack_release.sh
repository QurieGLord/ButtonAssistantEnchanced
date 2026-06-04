#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_NAME="$(basename "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
TOC_FILE="${SCRIPT_DIR}/${ADDON_NAME}.toc"

if ! command -v zip >/dev/null 2>&1; then
	echo -e "${RED}Error: 'zip' utility is not installed.${NC}" >&2
	exit 1
fi

VERSION="${1:-${VERSION:-}}"
if [ -z "$VERSION" ]; then
	if [ -f "$TOC_FILE" ]; then
		VERSION="$(awk '/^## Version:/ { print $3; exit }' "$TOC_FILE")"
	fi
fi

if [ -z "$VERSION" ]; then
	echo -e "${RED}Error: unable to resolve addon version.${NC}" >&2
	exit 1
fi

VERSION="${VERSION#v}"
DIST_DIR="${DIST_DIR:-${SCRIPT_DIR}/dist}"
ZIP_NAME="${ADDON_NAME}-${VERSION}.zip"
OUTPUT_ZIP="${DIST_DIR}/${ZIP_NAME}"

mkdir -p "$DIST_DIR"
rm -f "$OUTPUT_ZIP"

echo -e "${BLUE}Preparing ${YELLOW}${ADDON_NAME} ${VERSION}${BLUE} release package...${NC}"

(
	cd "$PARENT_DIR"
	zip -r -q "$OUTPUT_ZIP" "$ADDON_NAME" \
		-x "$ADDON_NAME/.git" \
		-x "$ADDON_NAME/.git/*" \
		-x "$ADDON_NAME/.gitignore" \
		-x "$ADDON_NAME/.github" \
		-x "$ADDON_NAME/.github/*" \
		-x "$ADDON_NAME/docs" \
		-x "$ADDON_NAME/docs/*" \
		-x "$ADDON_NAME/dist" \
		-x "$ADDON_NAME/dist/*" \
		-x "$ADDON_NAME/pack_release.sh" \
		-x "$ADDON_NAME/*.zip" \
		-x "$ADDON_NAME/*.tgz" \
		-x "$ADDON_NAME/*.tar.gz" \
		-x "$ADDON_NAME/*.mp4" \
		-x "$ADDON_NAME/*.webm" \
		-x "$ADDON_NAME/*.gif" \
		-x "$ADDON_NAME/Media/demo.gif" \
		-x "$ADDON_NAME/Media/*.mp4" \
		-x "$ADDON_NAME/Media/*.webm" \
		-x "$ADDON_NAME/docs/*.mp4" \
		-x "$ADDON_NAME/.DS_Store" \
		-x "$ADDON_NAME/*/.DS_Store" \
		-x "$ADDON_NAME/Thumbs.db" \
		-x "$ADDON_NAME/*/Thumbs.db" \
		-x "$ADDON_NAME/.luacheckcache"
)

echo -e "${GREEN}Release archive created:${NC} ${YELLOW}${OUTPUT_ZIP}${NC}"
