#!/bin/bash
# Run on device after deploying capture_front binary.
# Usage: bash capture_front.sh [--test-pattern]
#   --test-pattern  enable sensor color bar test pattern before capture
set -e

BINARY=/tmp/capture_front
TS=$(date +%Y%m%d_%H%M%S)
OUTFILE="/tmp/front_${TS}.raw"
TEST_PATTERN=0

for arg in "$@"; do
    [ "$arg" = "--test-pattern" ] && TEST_PATTERN=1
done

# Set pipeline formats — ignore EINVAL (driver returns it if already at this format)
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-csi2-dphy4":0[fmt:SGRBG10_1X10/2592x1944]' 2>/dev/null || true
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-csi2-dphy4":1[fmt:SGRBG10_1X10/2592x1944]' 2>/dev/null || true
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-mipi-csi2":0[fmt:SGRBG10_1X10/2592x1944]' 2>/dev/null || true
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-mipi-csi2":1[fmt:SGRBG10_1X10/2592x1944]' 2>/dev/null || true

# Test pattern: 0=Disabled, 1=Vertical Color Bar Type 1
v4l2-ctl -d /dev/v4l-subdev6 -c test_pattern="${TEST_PATTERN}"
[ "$TEST_PATTERN" -eq 1 ] && echo "Test pattern ON" || echo "Test pattern OFF"

echo "Capturing → ${OUTFILE}"
"${BINARY}" "${OUTFILE}"
echo "Done: ${OUTFILE}"
echo ""
echo "On host run:"
echo "  scp chaos@192.168.2.109:${OUTFILE} . && python3 tools/analyze_raw.py $(basename ${OUTFILE})"
