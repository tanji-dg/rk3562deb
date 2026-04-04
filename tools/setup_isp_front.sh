#!/bin/bash
# Route front camera (s5k5e8, /dev/video11) through ISP → /dev/video22 (NV12 output).
# This allows Chromium / getUserMedia / GStreamer to use the front camera.
#
# After running this, /dev/video22 outputs NV12 2592x1944 from the front camera.
# Without running this, /dev/video11 outputs raw BA10 (Bayer 10-bit packed).
set -e

W=2592; H=1944

echo "=== media1: set MIPI pipeline for front camera ==="
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-csi2-dphy4":0[fmt:SGRBG10_1X10/'"${W}x${H}"']' 2>/dev/null || true
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-csi2-dphy4":1[fmt:SGRBG10_1X10/'"${W}x${H}"']' 2>/dev/null || true
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-mipi-csi2":0[fmt:SGRBG10_1X10/'"${W}x${H}"']' 2>/dev/null || true
media-ctl -d /dev/media1 \
    --set-v4l2 '"rockchip-mipi-csi2":1[fmt:SGRBG10_1X10/'"${W}x${H}"']' 2>/dev/null || true

echo "=== media2: switch ISP input from rear → front camera ==="
# Disable rear camera link to ISP
media-ctl -d /dev/media2 \
    --links '"rkcif-mipi-lvds":0->"rkisp-isp-subdev":0[0]' 2>/dev/null || true
# Enable front camera link to ISP
media-ctl -d /dev/media2 \
    --links '"rkcif-mipi-lvds2":0->"rkisp-isp-subdev":0[1]' 2>/dev/null || true

echo "=== media2: set ISP format ==="
media-ctl -d /dev/media2 \
    --set-v4l2 '"rkisp-isp-subdev":0[fmt:SGRBG10_1X10/'"${W}x${H}"']' 2>/dev/null || true
media-ctl -d /dev/media2 \
    --set-v4l2 '"rkisp-isp-subdev":2[fmt:YUYV8_2X8/'"${W}x${H}"']' 2>/dev/null || true

echo "=== ISP link state after setup ==="
media-ctl -d /dev/media2 --print-topology 2>/dev/null | \
    grep -E '(rkcif-mipi-lvds|rkisp-isp-subdev.*0|ENABLED)' | head -10

echo ""
echo "Now capturing test frame from /dev/video22 (ISP NV12 output)..."
v4l2-ctl -d /dev/video22 \
    --set-fmt-video-mplane="width=${W},height=${H},pixelformat=NV12" \
    --stream-mplane --stream-count=1 --stream-to=/tmp/isp_front_test.raw 2>&1 && \
    echo "Success: /tmp/isp_front_test.raw (size=$(stat -c%s /tmp/isp_front_test.raw 2>/dev/null || echo unknown))" || \
    echo "Capture failed (see above)"
