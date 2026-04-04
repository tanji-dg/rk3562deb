/* config_isp.c — force ISP subdev format + crop for front camera 2592x1944.
 * Sets pad0 (Sink) and pad2 (Source) on the rkisp-isp-subdev node.
 *
 * Usage: config_isp [/dev/v4l-subdevN]   (default: /dev/v4l-subdev7)
 *
 * Needed because media-ctl --set-v4l2 returns EINVAL for this driver when
 * the ISP crop registers are stale from a prior rear-camera configuration.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/media.h>
#include <linux/v4l2-mediabus.h>
#include <linux/v4l2-subdev.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define ISP_SUBDEV  "/dev/v4l-subdev7"
#define W 2592
#define H 1944

/* MEDIA_BUS_FMT_SGRBG10_1X10 = 0x300f */
#define SGRBG10_1X10 0x300f
/* MEDIA_BUS_FMT_YUYV8_2X8 = 0x2011 */
#define YUYV8_2X8    0x2011

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
	return r;
}

static int set_pad_fmt(int fd, unsigned int pad, unsigned int code, int w, int h)
{
	struct v4l2_subdev_format fmt;
	memset(&fmt, 0, sizeof(fmt));
	fmt.which = V4L2_SUBDEV_FORMAT_ACTIVE;
	fmt.pad   = pad;
	fmt.format.code   = code;
	fmt.format.width  = w;
	fmt.format.height = h;
	fmt.format.field  = V4L2_FIELD_NONE;
	if (xioctl(fd, VIDIOC_SUBDEV_S_FMT, &fmt)) {
		fprintf(stderr, "VIDIOC_SUBDEV_S_FMT pad%u: %s\n", pad, strerror(errno));
		return -1;
	}
	printf("pad%u fmt set: %ux%u code=0x%04x → got %ux%u code=0x%04x\n",
	       pad, w, h, code,
	       fmt.format.width, fmt.format.height, fmt.format.code);
	return 0;
}

static int set_pad_crop(int fd, unsigned int pad, int x, int y, int w, int h)
{
	struct v4l2_subdev_selection sel;
	memset(&sel, 0, sizeof(sel));
	sel.which  = V4L2_SUBDEV_FORMAT_ACTIVE;
	sel.pad    = pad;
	sel.target = V4L2_SEL_TGT_CROP;
	sel.r.left   = x;
	sel.r.top    = y;
	sel.r.width  = w;
	sel.r.height = h;
	if (xioctl(fd, VIDIOC_SUBDEV_S_SELECTION, &sel)) {
		fprintf(stderr, "VIDIOC_SUBDEV_S_SELECTION crop pad%u: %s\n", pad, strerror(errno));
		return -1;
	}
	printf("pad%u crop set: (%d,%d)/%dx%d\n", pad,
	       sel.r.left, sel.r.top, sel.r.width, sel.r.height);
	return 0;
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : ISP_SUBDEV;
	int fd = open(path, O_RDWR);
	if (fd < 0) { perror(path); return 1; }

	printf("=== ISP pad0 (Sink) — raw Bayer input ===\n");
	set_pad_fmt(fd, 0, SGRBG10_1X10, W, H);
	set_pad_crop(fd, 0, 0, 0, W, H);

	printf("=== ISP pad2 (Source) — processed output ===\n");
	set_pad_fmt(fd, 2, YUYV8_2X8, W, H);
	set_pad_crop(fd, 2, 0, 0, W, H);

	close(fd);
	return 0;
}
