/* tools/capture_front.c
 * Multiplanar V4L2 capture for front camera (s5k5e8, /dev/video11).
 * Usage: capture_front [output.raw]
 * Defaults to /tmp/front.raw.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>

#define DEV    "/dev/video11"
#define WIDTH  2592
#define HEIGHT 1944
#define PIXFMT V4L2_PIX_FMT_SGRBG10  /* BA10 */
#define BPP    2

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
	return r;
}

int main(int argc, char **argv)
{
	const char *outfile = argc > 1 ? argv[1] : "/tmp/front.raw";
	struct v4l2_plane planes[1];
	struct v4l2_buffer buf;
	struct v4l2_format fmt;
	struct v4l2_requestbuffers req;
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

	int fd = open(DEV, O_RDWR | O_NONBLOCK);
	if (fd < 0) { perror("open " DEV); return 1; }

	/* Set format */
	memset(&fmt, 0, sizeof(fmt));
	fmt.type                                 = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	fmt.fmt.pix_mp.width                     = WIDTH;
	fmt.fmt.pix_mp.height                    = HEIGHT;
	fmt.fmt.pix_mp.pixelformat               = PIXFMT;
	fmt.fmt.pix_mp.num_planes                = 1;
	fmt.fmt.pix_mp.plane_fmt[0].sizeimage    = WIDTH * HEIGHT * BPP;
	fmt.fmt.pix_mp.plane_fmt[0].bytesperline = WIDTH * BPP;
	if (xioctl(fd, VIDIOC_S_FMT, &fmt)) { perror("VIDIOC_S_FMT"); return 1; }
	printf("Format: %ux%u plane_size=%u\n",
	       fmt.fmt.pix_mp.width, fmt.fmt.pix_mp.height,
	       fmt.fmt.pix_mp.plane_fmt[0].sizeimage);

	/* Request 1 MMAP buffer */
	memset(&req, 0, sizeof(req));
	req.count  = 1;
	req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(fd, VIDIOC_REQBUFS, &req)) { perror("VIDIOC_REQBUFS"); return 1; }

	/* Query buffer to get mmap offset */
	memset(planes, 0, sizeof(planes));
	memset(&buf, 0, sizeof(buf));
	buf.type     = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	buf.memory   = V4L2_MEMORY_MMAP;
	buf.index    = 0;
	buf.m.planes = planes;
	buf.length   = 1;
	if (xioctl(fd, VIDIOC_QUERYBUF, &buf)) { perror("VIDIOC_QUERYBUF"); return 1; }

	size_t buf_size = planes[0].length;
	__u32  offset   = planes[0].m.mem_offset;
	void  *mem = mmap(NULL, buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, offset);
	if (mem == MAP_FAILED) { perror("mmap"); return 1; }
	printf("Buffer: size=%zu mmap_offset=0x%x\n", buf_size, offset);

	/* Queue buffer */
	memset(planes, 0, sizeof(planes));
	memset(&buf, 0, sizeof(buf));
	buf.type     = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	buf.memory   = V4L2_MEMORY_MMAP;
	buf.index    = 0;
	buf.m.planes = planes;
	buf.length   = 1;
	if (xioctl(fd, VIDIOC_QBUF, &buf)) { perror("VIDIOC_QBUF"); return 1; }

	/* Stream on */
	if (xioctl(fd, VIDIOC_STREAMON, &type)) { perror("VIDIOC_STREAMON"); return 1; }
	printf("Streaming, waiting for frame (5s timeout)...\n");

	/* Wait up to 5 seconds */
	fd_set fds;
	struct timeval tv = {5, 0};
	FD_ZERO(&fds);
	FD_SET(fd, &fds);
	if (select(fd + 1, &fds, NULL, NULL, &tv) <= 0) {
		fprintf(stderr, "select: timeout or error — no frame received\n");
		xioctl(fd, VIDIOC_STREAMOFF, &type);
		return 1;
	}

	/* Dequeue */
	memset(planes, 0, sizeof(planes));
	memset(&buf, 0, sizeof(buf));
	buf.type     = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	buf.memory   = V4L2_MEMORY_MMAP;
	buf.m.planes = planes;
	buf.length   = 1;
	if (xioctl(fd, VIDIOC_DQBUF, &buf)) { perror("VIDIOC_DQBUF"); return 1; }

	size_t used = planes[0].bytesused ? planes[0].bytesused : buf_size;
	printf("Frame captured: %zu bytes\n", used);

	/* Write raw frame to file */
	FILE *f = fopen(outfile, "wb");
	if (!f) { perror("fopen"); return 1; }
	fwrite(mem, 1, used, f);
	fclose(f);
	printf("Saved: %s\n", outfile);

	xioctl(fd, VIDIOC_STREAMOFF, &type);
	munmap(mem, buf_size);
	close(fd);
	return 0;
}
