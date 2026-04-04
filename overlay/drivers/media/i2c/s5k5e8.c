// SPDX-License-Identifier: GPL-2.0
/*
 * s5k5e8 driver
 *
 * Copyright (C) 2020 Rockchip Electronics Co., Ltd.
 *
 * V0.0X01.0X01 add poweron function.
 * V0.0X01.0X02 fix mclk issue when probe multiple camera.
 */

#include <linux/clk.h>
#include <linux/device.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/sysfs.h>
#include <linux/slab.h>
#include <linux/version.h>
#include <linux/rk-camera-module.h>
#include <linux/rk-preisp.h>
#include <media/media-entity.h>
#include <media/v4l2-async.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-subdev.h>
#include <linux/pinctrl/consumer.h>

#define DRIVER_VERSION			KERNEL_VERSION(0, 0x01, 0x02)

#ifndef V4L2_CID_DIGITAL_GAIN
#define V4L2_CID_DIGITAL_GAIN		V4L2_CID_GAIN
#endif

#define S5K5E8_LANES			2
#define S5K5E8_BITS_PER_SAMPLE	10

#define S5K5E8_LINK_FREQ_200MHZ		200000000ULL
#define S5K5E8_LINK_FREQ_366MHZ		366000000ULL
/* 384 MHz = 768 Mbps/lane — proportional scale of MediaTek 832 Mbps @ 24 vs 26 MHz MCLK */
#define S5K5E8_LINK_FREQ_384MHZ		384000000ULL

/* pixel rate = link frequency * 2 * lanes / BITS_PER_SAMPLE */
#define S5K5E8_PIXEL_RATE(_link_freq) \
	((_link_freq) / S5K5E8_BITS_PER_SAMPLE * 2 * S5K5E8_LANES)

#define S5K5E8_XVCLK_FREQ		 24000000

#define CHIP_ID				0x5E80
#define S5K5E8_REG_CHIP_ID		0x0000	//read only reg

#define S5K5E8_REG_CTRL_MODE		0x0100
#define S5K5E8_MODE_SW_STANDBY	0x00
#define S5K5E8_MODE_STREAMING		0x01

/*
 * mirror&flip
 * 0: No mirror&flip
 * 1: horizontal mirror
 * 2: Vertical flip
 * 3: Horizontal mirror & Vertical flip
 */
#define S5K5E8_REG_ORIENTATION_MODE	0x0101
#define MIRROR_BIT_MASK			BIT(0)
#define FLIP_BIT_MASK			BIT(1)


#define S5K5E8_REG_EXPOSURE		0x0202
#define	S5K5E8_EXPOSURE_MIN		2
#define	S5K5E8_EXPOSURE_STEP		1
#define S5K5E8_VTS_MAX		0xfffc

#define S5K5E8_REG_GAIN		0x0204
#define S5K5E8_GAIN_MIN		0x0020
#define S5K5E8_GAIN_MAX		0x0800
#define S5K5E8_GAIN_STEP		1
#define S5K5E8_GAIN_DEFAULT	32

// #define S5K5E8_REG_DGAIN	0x020d
#define S5K5E8_REG_DGAINGR	0x020e
#define S5K5E8_REG_DGAINR    0x0210
#define S5K5E8_REG_DGAINB    0x0212
#define S5K5E8_REG_DGAINGB   0x0214
// #define S5K5E8_DGAIN_MODE	1


#define S5K5E8_REG_TEST_PATTERN	0x0601
#define S5K5E8_TEST_PATTERN_ENABLE	0x1
#define S5K5E8_TEST_PATTERN_DISABLE	0x0

#define S5K5E8_REG_VTS		0x0340

#define REG_NULL			0xFFFF
#define REG_DELAY			0xFFFE

#define S5K5E8_REG_VALUE_08BIT	1
#define S5K5E8_REG_VALUE_16BIT	2
#define S5K5E8_REG_VALUE_24BIT	3

#define OF_CAMERA_PINCTRL_STATE_DEFAULT	"rockchip,camera_default"
#define OF_CAMERA_PINCTRL_STATE_SLEEP	"rockchip,camera_sleep"
#define OF_CAMERA_HDR_MODE		"rockchip,camera-hdr-mode"
#define S5K5E8_NAME			"s5k5e8"

static const char * const s5k5e8_supply_names[] = {
	"dovdd",	/* Digital I/O power */
	"dvdd",		/* Digital core power */
	"avdd",		/* Analog power */
};

#define S5K5E8_NUM_SUPPLIES ARRAY_SIZE(s5k5e8_supply_names)

struct regval {
	u16 addr;
	u16 val;
};

struct s5k5e8_mode {
	u32 width;
	u32 height;
	struct v4l2_fract max_fps;
	u32 hts_def;
	u32 vts_def;
	u32 exp_def;
	const struct regval *reg_list;
	u32 link_freq_idx;
	u32 hdr_mode;
	u32 vc[PAD_MAX];
};

struct s5k5e8 {
	struct i2c_client	*client;
	struct clk		*xvclk;
	struct gpio_desc	*reset_gpio;
	struct gpio_desc	*pwdn_gpio;
	struct gpio_desc	*pwren_gpio;
	struct gpio_desc	*iovdd_gpio;
	struct gpio_desc	*avdd_gpio;
	struct gpio_desc	*dvdd_gpio;
	struct regulator_bulk_data supplies[S5K5E8_NUM_SUPPLIES];

	struct pinctrl		*pinctrl;
	struct pinctrl_state	*pins_default;
	struct pinctrl_state	*pins_sleep;

	struct v4l2_subdev	subdev;
	struct media_pad	pad;
	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl	*exposure;
	struct v4l2_ctrl	*anal_gain;
	struct v4l2_ctrl	*digi_gain;
	struct v4l2_ctrl	*h_flip;
	struct v4l2_ctrl	*v_flip;
	struct v4l2_ctrl	*hblank;
	struct v4l2_ctrl	*vblank;
	struct v4l2_ctrl	*pixel_rate;
	struct v4l2_ctrl	*link_freq;
	struct v4l2_ctrl	*test_pattern;
	struct mutex		mutex;
	bool			streaming;
	bool			power_on;
	const struct s5k5e8_mode *cur_mode;
	u32			module_index;
	const char		*module_facing;
	const char		*module_name;
	const char		*len_name;
	u8			flip;
};

#define to_s5k5e8(sd) container_of(sd, struct s5k5e8, subdev)

/*
 * Xclk 24Mhz
 */
/*
 * Global sensor init sequence from MediaTek S5K5E8YXV36 driver.
 * This variant uses a different PLL path (0x0308/0x0309) from what the
 * original Rockchip table expected (0x030F).  The MediaTek sensor_init()
 * analog register values match the POR readbacks we observe on this silicon.
 */
static const struct regval s5k5e8_global_regs[] = {
	{0x0100, 0x00},
	{0x3906, 0x7E},
	{0x3C01, 0x0F},
	{0x3C14, 0x00},
	{0x3235, 0x08},
	{0x3063, 0x2E},
	{0x307A, 0x10},
	{0x307B, 0x0E},
	{0x3079, 0x20},
	{0x3070, 0x05},
	{0x3067, 0x06},
	{0x3071, 0x62},
	{0x3203, 0x43},
	{0x3205, 0x43},
	{0x320B, 0x42},
	{0x3007, 0x00},
	{0x3008, 0x14},
	{0x3020, 0x58},
	{0x300D, 0x34},
	{0x300E, 0x17},
	{0x3021, 0x02},
	{0x3010, 0x59},
	{0x3002, 0x01},
	{0x3005, 0x01},
	{0x3008, 0x04},
	{0x300F, 0x70},
	{0x3010, 0x69},
	{0x3017, 0x10},
	{0x3019, 0x19},
	{0x300C, 0x62},
	{0x3064, 0x10},
	{0x3C08, 0x0E},
	{0x3C09, 0x10},
	{0x3C31, 0x0D},
	{0x3C32, 0xAC},
	{0x3303, 0x02},
	{REG_NULL, 0x00},
};

/*
 * Xclk 24Mhz, max_framerate ~30fps
 * mipi_datarate per lane ~768Mbps (2 lanes)
 * Full resolution 2592x1944.
 *
 * Adapted from MediaTek S5K5E8YXV36 capture-30fps table.
 * Key change: OP PLL uses 0x0308/0x0309 (not 0x030F which is unwriteable
 * on this silicon).  0x0308 scaled proportionally from MediaTek 0x30@26MHz
 * to 0x34@24MHz to keep approximately the same output bit rate (~768 Mbps).
 * 0x3C0D=0x04 is written via __s5k5e8_start_stream just before streaming.
 */
static const struct regval s5k5e8_linear_2592x1944_regs[] = {
	{0x0100, 0x00},
	{REG_DELAY, 33000},	/* 33 ms — wait for standby per MediaTek sequence */
	{0x0136, 0x18},		/* MCLK = 24 MHz */
	{0x0137, 0x00},
	{0x0305, 0x06},		/* vt_pre_pll_clk_div = 6 */
	{0x0306, 0x18},		/* pll2 pre-divider = 24 */
	{0x0307, 0x9B},		/* vt pll multiplier = 155 → vt_sys_clk ≈ 620 MHz */
	{0x0308, 0x34},		/* op pll multiplier = 52 (scaled 48*26/24) → ~768 Mbps */
	{0x0309, 0x02},		/* op_pix_clk_div = 2 */
	{0x3C1F, 0x00},
	{0x3C17, 0x00},
	{0x3C0B, 0x04},
	{0x3C1C, 0x47},
	{0x3C1D, 0x15},
	{0x3C14, 0x04},
	{0x3C16, 0x00},
	{0x0820, 0x03},		/* MIPI bit rate target = 768 Mbps (0x0300) */
	{0x0821, 0x00},
	{0x0114, 0x01},		/* 2-lane CSI-2 */
	{0x0344, 0x00},		/* X start = 8 */
	{0x0345, 0x08},
	{0x0346, 0x00},		/* Y start = 8 */
	{0x0347, 0x08},
	{0x0348, 0x0A},		/* X end = 2599 */
	{0x0349, 0x27},
	{0x034A, 0x07},		/* Y end = 1951 */
	{0x034B, 0x9F},
	{0x034C, 0x0A},		/* X output = 2592 */
	{0x034D, 0x20},
	{0x034E, 0x07},		/* Y output = 1944 */
	{0x034F, 0x98},
	{0x0900, 0x00},		/* no binning */
	{0x0901, 0x00},
	{0x0381, 0x01},
	{0x0383, 0x01},
	{0x0385, 0x01},
	{0x0387, 0x01},
	{0x0340, 0x07},		/* VTS = 1968 */
	{0x0341, 0xB0},
	{0x0342, 0x0B},		/* HTS = 2856 */
	{0x0343, 0x28},
	{0x0200, 0x00},
	{0x0201, 0x00},
	{0x0202, 0x03},		/* default exposure = 990 lines */
	{0x0203, 0xDE},
	{0x3303, 0x02},
	/* 0x3C0D=0x04 written by __s5k5e8_start_stream just before STREAMON */
	{REG_NULL, 0x00},
};

static const struct regval s5k5e8_linear_1920x1080_regs[] = {
	{0x0100, 0x00},
	{0x0136, 0x18},
	{0x0137, 0x00},
	{0x0305, 0x06},
	{0x0306, 0x00},
	{0x0307, 0x8C},
	{0x030D, 0x06},
	{0x030E, 0x00},
	{0x030F, 0x64},
	{0x3C1F, 0x00},
	{0x3C17, 0x00},
	{0x3C1C, 0x05},
	{0x3C1D, 0x15},
	{0x0301, 0x04},
	{0x0820, 0x01},
	{0x0821, 0x90},
	{0x0822, 0x00},
	{0x0823, 0x00},
	{0x0112, 0x0A},
	{0x0113, 0x0A},
	{0x0114, 0x01},
	{0x3906, 0x00},
	{0x0344, 0x02},
	{0x0345, 0xA8},
	{0x0346, 0x02},
	{0x0347, 0xB4},
	{0x0348, 0x0A},
	{0x0349, 0x27},
	{0x034A, 0x06},
	{0x034B, 0xEB},
	{0x034C, 0x07},
	{0x034D, 0x80},
	{0x034E, 0x04},
	{0x034F, 0x38},
	{0x0900, 0x00},
	{0x0901, 0x00},
	{0x0381, 0x01},
	{0x0383, 0x01},
	{0x0385, 0x01},
	{0x0387, 0x01},
	{0x0101, 0x00},
	{0x0340, 0x09},
	{0x0341, 0xE2},
	{0x0342, 0x0E},
	{0x0343, 0x68},
	{0x0200, 0x0D},
	{0x0201, 0xD8},
	{0x0202, 0x00},
	{0x0203, 0x02},
	{0x3400, 0x01},
	{0x0100, 0x01},
	{REG_NULL, 0x00},
};

static const struct s5k5e8_mode supported_modes[] = {
	{
		/* Full resolution 2592x1944, ~30fps, 768 Mbps/lane */
		.width = 2592,
		.height = 1944,
		.max_fps = {
			.numerator = 10000,
			.denominator = 300000,
		},
		.exp_def = 0x03DE,	/* 990 lines default exposure */
		.hts_def = 0x0B28,	/* 2856 */
		.vts_def = 0x07B0,	/* 1968 */
		.reg_list = s5k5e8_linear_2592x1944_regs,
		.link_freq_idx = 2,	/* 384 MHz = 768 Mbps/lane */
		.hdr_mode = NO_HDR,
		.vc[PAD0] = 0,
	},
};

static const s64 link_freq_menu_items[] = {
	S5K5E8_LINK_FREQ_200MHZ,
	S5K5E8_LINK_FREQ_366MHZ,
	S5K5E8_LINK_FREQ_384MHZ,
};

static const char * const s5k5e8_test_pattern_menu[] = {
	"Disabled",
	"Vertical Color Bar Type 1",
	"Vertical Color Bar Type 2",
	"Vertical Color Bar Type 3",
	"Vertical Color Bar Type 4"
};

/* Write registers up to 4 at a time */
static int s5k5e8_write_reg(struct i2c_client *client, u16 reg,
			    u32 len, u32 val)
{
	u32 buf_i, val_i;
	u8 buf[6];
	u8 *val_p;
	__be32 val_be;

	if (len > 4)
		return -EINVAL;

	buf[0] = reg >> 8;
	buf[1] = reg & 0xff;

	val_be = cpu_to_be32(val);
	val_p = (u8 *)&val_be;
	buf_i = 2;
	val_i = 4 - len;

	while (val_i < 4)
		buf[buf_i++] = val_p[val_i++];

	if (i2c_master_send(client, buf, len + 2) != len + 2)
		return -EIO;

	return 0;
}

static int s5k5e8_write_array(struct i2c_client *client,
			      const struct regval *regs)
{
	u32 i;
	int ret = 0;

	for (i = 0; ret == 0 && regs[i].addr != REG_NULL; i++)
		if (unlikely(regs[i].addr == REG_DELAY))
			usleep_range(regs[i].val, regs[i].val * 2);
		else
			ret = s5k5e8_write_reg(client, regs[i].addr,
					       S5K5E8_REG_VALUE_08BIT,
					       regs[i].val);

	return ret;
}

/* Read registers up to 4 at a time */
static int s5k5e8_read_reg(struct i2c_client *client, u16 reg,
			   unsigned int len, u32 *val)
{
	struct i2c_msg msgs[2];
	u8 *data_be_p;
	__be32 data_be = 0;
	__be16 reg_addr_be = cpu_to_be16(reg);
	int ret;

	if (len > 4 || !len)
		return -EINVAL;

	data_be_p = (u8 *)&data_be;
	/* Write register address */
	msgs[0].addr = client->addr;
	msgs[0].flags = 0;
	msgs[0].len = 2;
	msgs[0].buf = (u8 *)&reg_addr_be;

	/* Read data from register */
	msgs[1].addr = client->addr;
	msgs[1].flags = I2C_M_RD;
	msgs[1].len = len;
	msgs[1].buf = &data_be_p[4 - len];

	ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
	if (ret != ARRAY_SIZE(msgs))
		return -EIO;

	*val = be32_to_cpu(data_be);

	return 0;
}

static int s5k5e8_get_reso_dist(const struct s5k5e8_mode *mode,
				struct v4l2_mbus_framefmt *framefmt)
{
	return abs(mode->width - framefmt->width) +
			abs(mode->height - framefmt->height);
}

static const struct s5k5e8_mode *
s5k5e8_find_best_fit(struct v4l2_subdev_format *fmt)
{
	struct v4l2_mbus_framefmt *framefmt = &fmt->format;
	int dist;
	int cur_best_fit = 0;
	int cur_best_fit_dist = -1;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(supported_modes); i++) {
		dist = s5k5e8_get_reso_dist(&supported_modes[i], framefmt);
		if (cur_best_fit_dist == -1 || dist < cur_best_fit_dist) {
			cur_best_fit_dist = dist;
			cur_best_fit = i;
		}
	}
	return &supported_modes[cur_best_fit];
}

static int s5k5e8_get_fmtcode(int orientationmode)
{
	int fmtcode = 0;

	switch (orientationmode) {
	case 0:
		fmtcode = MEDIA_BUS_FMT_SGRBG10_1X10;
		break;
	case 1:
		fmtcode = MEDIA_BUS_FMT_SRGGB10_1X10;
		break;
	case 2:
		fmtcode = MEDIA_BUS_FMT_SBGGR10_1X10;
		break;
	case 3:
		fmtcode = MEDIA_BUS_FMT_SGBRG10_1X10;
		break;
	default:
		fmtcode = MEDIA_BUS_FMT_SGRBG10_1X10;
		break;
	}
	return fmtcode;
}

static int s5k5e8_set_fmt(struct v4l2_subdev *sd,
			  struct v4l2_subdev_state *cfg,
			  struct v4l2_subdev_format *fmt)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);
	const struct s5k5e8_mode *mode;
	s64 h_blank, vblank_def;
	u32 dst_link_freq;
	u64 dst_pixel_rate;

	mutex_lock(&s5k5e8->mutex);
	mode = s5k5e8_find_best_fit(fmt);
	fmt->format.code = s5k5e8_get_fmtcode(s5k5e8->flip);
	fmt->format.width = mode->width;
	fmt->format.height = mode->height;
	fmt->format.field = V4L2_FIELD_NONE;
	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY) {
#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
		*v4l2_subdev_get_try_format(sd, cfg, fmt->pad) = fmt->format;
#else
		mutex_unlock(&s5k5e8->mutex);
		return -ENOTTY;
#endif
	} else {
		s5k5e8->cur_mode = mode;
		h_blank = mode->hts_def - mode->width;
		__v4l2_ctrl_modify_range(s5k5e8->hblank, h_blank,
					 h_blank, 1, h_blank);
		vblank_def = mode->vts_def - mode->height;
		__v4l2_ctrl_modify_range(s5k5e8->vblank, vblank_def,
					 S5K5E8_VTS_MAX - mode->height,
					 1, vblank_def);
		dst_link_freq = mode->link_freq_idx;
		dst_pixel_rate = S5K5E8_PIXEL_RATE(
			link_freq_menu_items[mode->link_freq_idx]);
		__v4l2_ctrl_s_ctrl_int64(s5k5e8->pixel_rate, dst_pixel_rate);
		__v4l2_ctrl_s_ctrl(s5k5e8->link_freq, dst_link_freq);
	}

	mutex_unlock(&s5k5e8->mutex);

	return 0;
}

static int s5k5e8_get_fmt(struct v4l2_subdev *sd,
			  struct v4l2_subdev_state *cfg,
			  struct v4l2_subdev_format *fmt)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);
	const struct s5k5e8_mode *mode = s5k5e8->cur_mode;

	mutex_lock(&s5k5e8->mutex);
	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY) {
#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
		fmt->format = *v4l2_subdev_get_try_format(sd, cfg, fmt->pad);
#else
		mutex_unlock(&s5k5e8->mutex);
		return -ENOTTY;
#endif
	} else {
		fmt->format.width = mode->width;
		fmt->format.height = mode->height;
		fmt->format.code = s5k5e8_get_fmtcode(s5k5e8->flip);
		fmt->format.field = V4L2_FIELD_NONE;
		/* format info: width/height/data type/virctual channel */
		if (fmt->pad < PAD_MAX && mode->hdr_mode != NO_HDR)
			fmt->reserved[0] = mode->vc[fmt->pad];
		else
			fmt->reserved[0] = mode->vc[PAD0];
	}
	mutex_unlock(&s5k5e8->mutex);

	return 0;
}

static int s5k5e8_enum_mbus_code(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *cfg,
				 struct v4l2_subdev_mbus_code_enum *code)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);

	if (code->index != 0)
		return -EINVAL;
	code->code = s5k5e8_get_fmtcode(s5k5e8->flip);

	return 0;
}

static int s5k5e8_enum_frame_sizes(struct v4l2_subdev *sd,
				   struct v4l2_subdev_state *cfg,
				   struct v4l2_subdev_frame_size_enum *fse)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);

	if (fse->index >= ARRAY_SIZE(supported_modes))
		return -EINVAL;

	if (fse->code != s5k5e8_get_fmtcode(s5k5e8->flip))
		return -EINVAL;

	fse->min_width = supported_modes[fse->index].width;
	fse->max_width = supported_modes[fse->index].width;
	fse->max_height = supported_modes[fse->index].height;
	fse->min_height = supported_modes[fse->index].height;

	return 0;
}

static int s5k5e8_enable_test_pattern(struct s5k5e8 *s5k5e8, u32 pattern)
{
	u32 val;

	if (pattern)
		val = (pattern - 1) | S5K5E8_TEST_PATTERN_ENABLE;
	else
		val = S5K5E8_TEST_PATTERN_DISABLE;

	return s5k5e8_write_reg(s5k5e8->client, S5K5E8_REG_TEST_PATTERN,
				S5K5E8_REG_VALUE_08BIT, val);
}

static int s5k5e8_g_frame_interval(struct v4l2_subdev *sd,
				   struct v4l2_subdev_frame_interval *fi)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);
	const struct s5k5e8_mode *mode = s5k5e8->cur_mode;

	mutex_lock(&s5k5e8->mutex);
	fi->interval = mode->max_fps;
	mutex_unlock(&s5k5e8->mutex);

	return 0;
}

static int s5k5e8_g_mbus_config(struct v4l2_subdev *sd, unsigned int pad,
				struct v4l2_mbus_config *config)
{
	if (pad != 0)
		return -EINVAL;

	config->type = V4L2_MBUS_CSI2_DPHY;
	config->bus.mipi_csi2.num_data_lanes = S5K5E8_LANES;

	return 0;
}

static void s5k5e8_get_module_inf(struct s5k5e8 *s5k5e8,
				  struct rkmodule_inf *inf)
{
	memset(inf, 0, sizeof(*inf));
	strscpy(inf->base.sensor, S5K5E8_NAME, sizeof(inf->base.sensor));
	strscpy(inf->base.module, s5k5e8->module_name,
		sizeof(inf->base.module));
	strscpy(inf->base.lens, s5k5e8->len_name, sizeof(inf->base.lens));
}

static long s5k5e8_ioctl(struct v4l2_subdev *sd, unsigned int cmd, void *arg)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);
	struct rkmodule_hdr_cfg *hdr;
	u32 i, h, w;
	u32 dst_link_freq;
	u64 dst_pixel_rate;
	long ret = 0;

	switch (cmd) {
	case RKMODULE_GET_MODULE_INFO:
		s5k5e8_get_module_inf(s5k5e8, (struct rkmodule_inf *)arg);
		break;
	case RKMODULE_GET_HDR_CFG:
		hdr = (struct rkmodule_hdr_cfg *)arg;
		hdr->esp.mode = HDR_NORMAL_VC;
		hdr->hdr_mode = s5k5e8->cur_mode->hdr_mode;
		break;
	case RKMODULE_SET_HDR_CFG:
		hdr = (struct rkmodule_hdr_cfg *)arg;
		w = s5k5e8->cur_mode->width;
		h = s5k5e8->cur_mode->height;
		for (i = 0; i < ARRAY_SIZE(supported_modes); i++) {
			if (w == supported_modes[i].width &&
			    h == supported_modes[i].height &&
			    supported_modes[i].hdr_mode == hdr->hdr_mode) {
				s5k5e8->cur_mode = &supported_modes[i];
				break;
			}
		}
		if (i == ARRAY_SIZE(supported_modes)) {
			dev_err(&s5k5e8->client->dev,
				"not find hdr mode:%d %dx%d config\n",
				hdr->hdr_mode, w, h);
			ret = -EINVAL;
		} else {
			w = s5k5e8->cur_mode->hts_def -
			    s5k5e8->cur_mode->width;
			h = s5k5e8->cur_mode->vts_def -
			    s5k5e8->cur_mode->height;
			__v4l2_ctrl_modify_range(s5k5e8->hblank, w, w, 1, w);
			__v4l2_ctrl_modify_range(s5k5e8->vblank, h,
						 S5K5E8_VTS_MAX -
						 s5k5e8->cur_mode->height,
						 1, h);
			dst_link_freq = s5k5e8->cur_mode->link_freq_idx;
			dst_pixel_rate = S5K5E8_PIXEL_RATE(
				link_freq_menu_items[s5k5e8->cur_mode->link_freq_idx]);
			__v4l2_ctrl_s_ctrl_int64(s5k5e8->pixel_rate,
						 dst_pixel_rate);
			__v4l2_ctrl_s_ctrl(s5k5e8->link_freq,
					   dst_link_freq);
		}
		break;
	case PREISP_CMD_SET_HDRAE_EXP:
		break;
	default:
		ret = -ENOIOCTLCMD;
		break;
	}

	return ret;
}

#ifdef CONFIG_COMPAT
static long s5k5e8_compat_ioctl32(struct v4l2_subdev *sd,
				  unsigned int cmd, unsigned long arg)
{
	void __user *up = compat_ptr(arg);
	struct rkmodule_inf *inf;
	struct rkmodule_awb_cfg *cfg;
	struct rkmodule_hdr_cfg *hdr;
	struct preisp_hdrae_exp_s *hdrae;
	long ret;

	switch (cmd) {
	case RKMODULE_GET_MODULE_INFO:
		inf = kzalloc(sizeof(*inf), GFP_KERNEL);
		if (!inf) {
			ret = -ENOMEM;
			return ret;
		}

		ret = s5k5e8_ioctl(sd, cmd, inf);
		if (!ret)
			ret = copy_to_user(up, inf, sizeof(*inf));
		kfree(inf);
		break;
	case RKMODULE_AWB_CFG:
		cfg = kzalloc(sizeof(*cfg), GFP_KERNEL);
		if (!cfg) {
			ret = -ENOMEM;
			return ret;
		}

		ret = copy_from_user(cfg, up, sizeof(*cfg));
		if (!ret)
			ret = s5k5e8_ioctl(sd, cmd, cfg);
		kfree(cfg);
		break;
	case RKMODULE_GET_HDR_CFG:
		hdr = kzalloc(sizeof(*hdr), GFP_KERNEL);
		if (!hdr) {
			ret = -ENOMEM;
			return ret;
		}

		ret = s5k5e8_ioctl(sd, cmd, hdr);
		if (!ret)
			ret = copy_to_user(up, hdr, sizeof(*hdr));
		kfree(hdr);
		break;
	case RKMODULE_SET_HDR_CFG:
		hdr = kzalloc(sizeof(*hdr), GFP_KERNEL);
		if (!hdr) {
			ret = -ENOMEM;
			return ret;
		}

		ret = copy_from_user(hdr, up, sizeof(*hdr));
		if (!ret)
			ret = s5k5e8_ioctl(sd, cmd, hdr);
		kfree(hdr);
		break;
	case PREISP_CMD_SET_HDRAE_EXP:
		hdrae = kzalloc(sizeof(*hdrae), GFP_KERNEL);
		if (!hdrae) {
			ret = -ENOMEM;
			return ret;
		}

		ret = copy_from_user(hdrae, up, sizeof(*hdrae));
		if (!ret)
			ret = s5k5e8_ioctl(sd, cmd, hdrae);
		kfree(hdrae);
		break;
	default:
		ret = -ENOIOCTLCMD;
		break;
	}

	return ret;
}
#endif

/* Registers to verify after write — MIPI-critical and analog-critical */
static const u16 s5k5e8_verify_regs[] = {
	0x0100, /* stream ctrl */
	0x0114, /* lane mode */
	0x0305, /* vt pll pre-div */
	0x0306, /* op pll pre-div (MediaTek path) */
	0x0307, /* vt pll mul */
	0x0308, /* op pll mul (MediaTek — used instead of 030F) */
	0x0309, /* op_pix_clk_div */
	0x0820, /* mipi data rate hi */
	0x0821, /* mipi data rate lo */
	0x307A, /* analog (MediaTek init) */
	0x307B, /* analog */
	0x3C08, /* analog */
	0x3C31, /* analog */
	0x3C0D, /* pll select */
	0x3C0B, /* clock control */
};

static int __s5k5e8_start_stream(struct s5k5e8 *s5k5e8)
{
	struct i2c_client *client = s5k5e8->client;
	struct device *dev = &client->dev;
	u32 val;
	int ret;
	int i;

	ret = s5k5e8_write_array(client, s5k5e8_global_regs);
	if (ret)
		return ret;

	ret = s5k5e8_write_array(client, s5k5e8->cur_mode->reg_list);
	if (ret)
		return ret;

	/* Read back key registers to verify MediaTek-path PLL configuration */
	dev_info(dev, "s5k5e8 register verify after init:\n");
	for (i = 0; i < ARRAY_SIZE(s5k5e8_verify_regs); i++) {
		ret = s5k5e8_read_reg(client, s5k5e8_verify_regs[i],
				      S5K5E8_REG_VALUE_08BIT, &val);
		dev_info(dev, "  reg 0x%04X = 0x%02X%s\n",
			 s5k5e8_verify_regs[i], val,
			 ret ? " (READ ERR)" : "");
	}
	ret = 0;

	/* In case these controls are set before streaming */
	mutex_unlock(&s5k5e8->mutex);
	ret = v4l2_ctrl_handler_setup(&s5k5e8->ctrl_handler);
	mutex_lock(&s5k5e8->mutex);
	if (ret)
		return ret;

	/*
	 * 0x3C0D=0x04: enable PLL output select before starting stream.
	 * Required by MediaTek S5K5E8YXV36 driver — without this write
	 * the sensor does not generate MIPI HS data.
	 */
	ret = s5k5e8_write_reg(client, 0x3C0D,
			       S5K5E8_REG_VALUE_08BIT, 0x04);
	if (ret)
		return ret;

	ret = s5k5e8_write_reg(client, S5K5E8_REG_CTRL_MODE,
			       S5K5E8_REG_VALUE_08BIT, S5K5E8_MODE_STREAMING);
	if (ret)
		return ret;

	/*
	 * Post-streaming writes per MediaTek sequence:
	 * 0x3C22 written twice, then 0x3C0D=0x00 to deselect PLL mux.
	 */
	s5k5e8_write_reg(client, 0x3C22, S5K5E8_REG_VALUE_08BIT, 0x00);
	s5k5e8_write_reg(client, 0x3C22, S5K5E8_REG_VALUE_08BIT, 0x00);
	s5k5e8_write_reg(client, 0x3C0D, S5K5E8_REG_VALUE_08BIT, 0x00);

	return 0;
}

static int __s5k5e8_stop_stream(struct s5k5e8 *s5k5e8)
{
	return s5k5e8_write_reg(s5k5e8->client, S5K5E8_REG_CTRL_MODE,
				S5K5E8_REG_VALUE_08BIT, S5K5E8_MODE_SW_STANDBY);
}

static int s5k5e8_s_stream(struct v4l2_subdev *sd, int on)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);
	struct i2c_client *client = s5k5e8->client;
	int ret = 0;

	mutex_lock(&s5k5e8->mutex);
	on = !!on;
	if (on == s5k5e8->streaming)
		goto unlock_and_return;

	if (on) {
		ret = pm_runtime_get_sync(&client->dev);
		if (ret < 0) {
			pm_runtime_put_noidle(&client->dev);
			goto unlock_and_return;
		}

		ret = __s5k5e8_start_stream(s5k5e8);
		if (ret) {
			v4l2_err(sd, "start stream failed while write regs\n");
			pm_runtime_put(&client->dev);
			goto unlock_and_return;
		}
	} else {
		__s5k5e8_stop_stream(s5k5e8);
		pm_runtime_put(&client->dev);
	}

	s5k5e8->streaming = on;

unlock_and_return:
	mutex_unlock(&s5k5e8->mutex);

	return ret;
}

static int s5k5e8_s_power(struct v4l2_subdev *sd, int on)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);
	struct i2c_client *client = s5k5e8->client;
	int ret = 0;

	mutex_lock(&s5k5e8->mutex);

	/* If the power state is not modified - no work to do. */
	if (s5k5e8->power_on == !!on)
		goto unlock_and_return;

	if (on) {
		ret = pm_runtime_get_sync(&client->dev);
		if (ret < 0) {
			pm_runtime_put_noidle(&client->dev);
			goto unlock_and_return;
		}

		s5k5e8->power_on = true;
	} else {
		pm_runtime_put(&client->dev);
		s5k5e8->power_on = false;
	}

unlock_and_return:
	mutex_unlock(&s5k5e8->mutex);

	return ret;
}

/* Calculate the delay in us by clock rate and clock cycles */
static inline u32 s5k5e8_cal_delay(u32 cycles)
{
	return DIV_ROUND_UP(cycles, S5K5E8_XVCLK_FREQ / 1000 / 1000);
}

static int __s5k5e8_power_on(struct s5k5e8 *s5k5e8)
{
	int ret;
	u32 delay_us;
	struct device *dev = &s5k5e8->client->dev;

	if (!IS_ERR_OR_NULL(s5k5e8->pins_default)) {
		ret = pinctrl_select_state(s5k5e8->pinctrl,
					   s5k5e8->pins_default);
		if (ret < 0)
			dev_err(dev, "could not set pins\n");
	}
	ret = clk_set_rate(s5k5e8->xvclk, S5K5E8_XVCLK_FREQ);
	if (ret < 0)
		dev_warn(dev, "Failed to set xvclk rate (24MHz)\n");
	if (clk_get_rate(s5k5e8->xvclk) != S5K5E8_XVCLK_FREQ)
		dev_warn(dev, "xvclk mismatched, modes are based on 24MHz\n");
	ret = clk_prepare_enable(s5k5e8->xvclk);
	if (ret < 0) {
		dev_err(dev, "Failed to enable xvclk\n");
		return ret;
	}
	if (!IS_ERR(s5k5e8->dvdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->dvdd_gpio, 0);
	if (!IS_ERR(s5k5e8->avdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->avdd_gpio, 0);

	if (!IS_ERR(s5k5e8->iovdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->iovdd_gpio, 0);
	if (!IS_ERR(s5k5e8->reset_gpio))
		gpiod_set_value_cansleep(s5k5e8->reset_gpio, 0);

	if (!IS_ERR(s5k5e8->pwdn_gpio))
		gpiod_set_value_cansleep(s5k5e8->pwdn_gpio, 0);

	usleep_range(500, 1000);
	ret = regulator_bulk_enable(S5K5E8_NUM_SUPPLIES, s5k5e8->supplies);

	if (ret < 0) {
		dev_err(dev, "Failed to enable regulators\n");
		goto disable_clk;
	}
	if (!IS_ERR(s5k5e8->dvdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->dvdd_gpio, 1);
	if (!IS_ERR(s5k5e8->avdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->avdd_gpio, 1);

	if (!IS_ERR(s5k5e8->iovdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->iovdd_gpio, 1);

	if (!IS_ERR(s5k5e8->pwren_gpio))
		gpiod_set_value_cansleep(s5k5e8->pwren_gpio, 1);

	usleep_range(1000, 1100);
	if (!IS_ERR(s5k5e8->pwdn_gpio))
		gpiod_set_value_cansleep(s5k5e8->pwdn_gpio, 1);
	usleep_range(100, 150);
	if (!IS_ERR(s5k5e8->reset_gpio))
		gpiod_set_value_cansleep(s5k5e8->reset_gpio, 1);

	usleep_range(12000, 16000);
	/* 8192 cycles prior to first SCCB transaction */
	delay_us = s5k5e8_cal_delay(8192);
	usleep_range(delay_us, delay_us * 2);

	return 0;

disable_clk:
	clk_disable_unprepare(s5k5e8->xvclk);

	return ret;
}

static void __s5k5e8_power_off(struct s5k5e8 *s5k5e8)
{
	int ret;
	struct device *dev = &s5k5e8->client->dev;

	if (!IS_ERR(s5k5e8->dvdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->dvdd_gpio, 0);

	if (!IS_ERR(s5k5e8->avdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->avdd_gpio, 0);

	if (!IS_ERR(s5k5e8->iovdd_gpio))
		gpiod_set_value_cansleep(s5k5e8->iovdd_gpio, 0);

	if (!IS_ERR(s5k5e8->pwdn_gpio))
		gpiod_set_value_cansleep(s5k5e8->pwdn_gpio, 0);
	clk_disable_unprepare(s5k5e8->xvclk);
	if (!IS_ERR(s5k5e8->reset_gpio))
		gpiod_set_value_cansleep(s5k5e8->reset_gpio, 0);
	if (!IS_ERR_OR_NULL(s5k5e8->pins_sleep)) {
		ret = pinctrl_select_state(s5k5e8->pinctrl,
					   s5k5e8->pins_sleep);
		if (ret < 0)
			dev_dbg(dev, "could not set pins\n");
	}
	regulator_bulk_disable(S5K5E8_NUM_SUPPLIES, s5k5e8->supplies);
	if (!IS_ERR(s5k5e8->pwren_gpio))
		gpiod_set_value_cansleep(s5k5e8->pwren_gpio, 0);
}

static int s5k5e8_runtime_resume(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);

	return __s5k5e8_power_on(s5k5e8);
}

static int s5k5e8_runtime_suspend(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);

	__s5k5e8_power_off(s5k5e8);

	return 0;
}

#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
static int s5k5e8_open(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);
	struct v4l2_mbus_framefmt *try_fmt =
				v4l2_subdev_get_try_format(sd, fh->state, 0);
	const struct s5k5e8_mode *def_mode = &supported_modes[0];

	mutex_lock(&s5k5e8->mutex);
	/* Initialize try_fmt */
	try_fmt->width = def_mode->width;
	try_fmt->height = def_mode->height;
	try_fmt->code = s5k5e8_get_fmtcode(s5k5e8->flip);
	try_fmt->field = V4L2_FIELD_NONE;

	mutex_unlock(&s5k5e8->mutex);
	/* No crop or compose */

	return 0;
}
#endif

static int s5k5e8_enum_frame_interval(struct v4l2_subdev *sd,
				      struct v4l2_subdev_state *cfg,
				struct v4l2_subdev_frame_interval_enum *fie)
{
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);

	if (fie->index >= ARRAY_SIZE(supported_modes))
		return -EINVAL;

	fie->code = s5k5e8_get_fmtcode(s5k5e8->flip);

	fie->width = supported_modes[fie->index].width;
	fie->height = supported_modes[fie->index].height;
	fie->interval = supported_modes[fie->index].max_fps;
	fie->reserved[0] = supported_modes[fie->index].hdr_mode;
	return 0;
}

static const struct dev_pm_ops s5k5e8_pm_ops = {
	SET_RUNTIME_PM_OPS(s5k5e8_runtime_suspend,
			   s5k5e8_runtime_resume, NULL)
};

#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
static const struct v4l2_subdev_internal_ops s5k5e8_internal_ops = {
	.open = s5k5e8_open,
};
#endif

static const struct v4l2_subdev_core_ops s5k5e8_core_ops = {
	.s_power = s5k5e8_s_power,
	.ioctl = s5k5e8_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl32 = s5k5e8_compat_ioctl32,
#endif
};

static const struct v4l2_subdev_video_ops s5k5e8_video_ops = {
	.s_stream = s5k5e8_s_stream,
	.g_frame_interval = s5k5e8_g_frame_interval,
};

static const struct v4l2_subdev_pad_ops s5k5e8_pad_ops = {
	.enum_mbus_code = s5k5e8_enum_mbus_code,
	.enum_frame_size = s5k5e8_enum_frame_sizes,
	.enum_frame_interval = s5k5e8_enum_frame_interval,
	.get_fmt = s5k5e8_get_fmt,
	.set_fmt = s5k5e8_set_fmt,
	.get_mbus_config = s5k5e8_g_mbus_config,
};

static const struct v4l2_subdev_ops s5k5e8_subdev_ops = {
	.core	= &s5k5e8_core_ops,
	.video	= &s5k5e8_video_ops,
	.pad	= &s5k5e8_pad_ops,
};

static int s5k5e8_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct s5k5e8 *s5k5e8 = container_of(ctrl->handler,
					     struct s5k5e8, ctrl_handler);
	struct i2c_client *client = s5k5e8->client;
	s64 max;
	u32 again = 0;
	u32 dgain = 0;
	int ret = 0;
	u32 val = 0;

	/*Propagate change of current control to all related controls*/
	switch (ctrl->id) {
	case V4L2_CID_VBLANK:
		/*Update max exposure while meeting expected vblanking*/
		max = s5k5e8->cur_mode->height + ctrl->val - 4;
		__v4l2_ctrl_modify_range(s5k5e8->exposure,
					 s5k5e8->exposure->minimum,
					 max,
					 s5k5e8->exposure->step,
					 s5k5e8->exposure->default_value);
		break;
	}

	if (!pm_runtime_get_if_in_use(&client->dev))
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		/* 4 least significant bits of expsoure are fractional part */
		ret = s5k5e8_write_reg(s5k5e8->client, S5K5E8_REG_EXPOSURE,
					 S5K5E8_REG_VALUE_16BIT,
					 ctrl->val);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		again = ctrl->val > 512 ? 512 : ctrl->val;
		dgain = ctrl->val > 512 ? ctrl->val - 512 : 0;
		ret = s5k5e8_write_reg(s5k5e8->client, S5K5E8_REG_GAIN,
				       S5K5E8_REG_VALUE_16BIT,
				       again);
		if (dgain > 0) {
			ret |= s5k5e8_write_reg(s5k5e8->client,
						S5K5E8_REG_DGAINGR,
						S5K5E8_REG_VALUE_16BIT,
						dgain);
			ret |= s5k5e8_write_reg(s5k5e8->client,
						S5K5E8_REG_DGAINR,
						S5K5E8_REG_VALUE_16BIT,
						dgain);
			ret |= s5k5e8_write_reg(s5k5e8->client,
						S5K5E8_REG_DGAINB,
						S5K5E8_REG_VALUE_16BIT,
						dgain);
			ret |= s5k5e8_write_reg(s5k5e8->client,
						S5K5E8_REG_DGAINGB,
						S5K5E8_REG_VALUE_16BIT,
						dgain);
		}
		break;
	case V4L2_CID_VBLANK:
		ret = s5k5e8_write_reg(s5k5e8->client, S5K5E8_REG_VTS,
					 S5K5E8_REG_VALUE_16BIT,
					 ctrl->val + s5k5e8->cur_mode->height);
		break;
	case V4L2_CID_TEST_PATTERN:
		ret = s5k5e8_enable_test_pattern(s5k5e8, ctrl->val);
		break;
	case V4L2_CID_HFLIP:
		ret = s5k5e8_read_reg(client,
					S5K5E8_REG_ORIENTATION_MODE,
					S5K5E8_REG_VALUE_08BIT,
					&val);
		if (ctrl->val)
			val |= MIRROR_BIT_MASK;
		else
			val &= ~MIRROR_BIT_MASK;
		ret |= s5k5e8_write_reg(client,
					S5K5E8_REG_ORIENTATION_MODE,
					S5K5E8_REG_VALUE_08BIT,
					val);
		if (ret == 0)
			s5k5e8->flip = val;
		break;
	case V4L2_CID_VFLIP:
		ret = s5k5e8_read_reg(client,
					S5K5E8_REG_ORIENTATION_MODE,
					S5K5E8_REG_VALUE_08BIT,
					&val);
		if (ctrl->val)
			val |= FLIP_BIT_MASK;
		else
			val &= ~FLIP_BIT_MASK;
		ret |= s5k5e8_write_reg(client,
					S5K5E8_REG_ORIENTATION_MODE,
					S5K5E8_REG_VALUE_08BIT,
					val);
		if (ret == 0)
			s5k5e8->flip = val;
		break;
	default:
		dev_warn(&client->dev, "%s Unhandled id:0x%x, val:0x%x\n",
			 __func__, ctrl->id, ctrl->val);
		break;
	}

	pm_runtime_put(&client->dev);

	return ret;
}

static const struct v4l2_ctrl_ops s5k5e8_ctrl_ops = {
	.s_ctrl = s5k5e8_set_ctrl,
};

static int s5k5e8_initialize_controls(struct s5k5e8 *s5k5e8)
{
	const struct s5k5e8_mode *mode;
	struct v4l2_ctrl_handler *handler;
	u32 dst_link_freq;
	u64 dst_pixel_rate;
	s64 exposure_max, vblank_def;
	u32 h_blank;
	int ret;

	handler = &s5k5e8->ctrl_handler;
	mode = s5k5e8->cur_mode;
	ret = v4l2_ctrl_handler_init(handler, 9);
	if (ret)
		return ret;
	handler->lock = &s5k5e8->mutex;

	dst_link_freq = mode->link_freq_idx;
	dst_pixel_rate = S5K5E8_PIXEL_RATE(
		link_freq_menu_items[mode->link_freq_idx]);

	s5k5e8->link_freq = v4l2_ctrl_new_int_menu(handler, NULL,
						    V4L2_CID_LINK_FREQ,
						    ARRAY_SIZE(link_freq_menu_items) - 1,
						    dst_link_freq,
						    link_freq_menu_items);
	if (s5k5e8->link_freq)
		s5k5e8->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	s5k5e8->pixel_rate = v4l2_ctrl_new_std(handler, NULL,
					       V4L2_CID_PIXEL_RATE,
					       0,
					       S5K5E8_PIXEL_RATE(S5K5E8_LINK_FREQ_384MHZ),
					       1,
					       dst_pixel_rate);

	h_blank = mode->hts_def - mode->width;
	s5k5e8->hblank = v4l2_ctrl_new_std(handler, NULL, V4L2_CID_HBLANK,
					   h_blank, h_blank, 1, h_blank);
	if (s5k5e8->hblank)
		s5k5e8->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	vblank_def = mode->vts_def - mode->height;
	s5k5e8->vblank = v4l2_ctrl_new_std(handler, &s5k5e8_ctrl_ops,
					   V4L2_CID_VBLANK, vblank_def,
					   S5K5E8_VTS_MAX - mode->height,
					    1, vblank_def);

	exposure_max = mode->vts_def - 4;
	s5k5e8->exposure = v4l2_ctrl_new_std(handler, &s5k5e8_ctrl_ops,
					     V4L2_CID_EXPOSURE,
					     S5K5E8_EXPOSURE_MIN,
					     exposure_max,
					     S5K5E8_EXPOSURE_STEP,
					     mode->exp_def);

	s5k5e8->anal_gain = v4l2_ctrl_new_std(handler, &s5k5e8_ctrl_ops,
					      V4L2_CID_ANALOGUE_GAIN,
					      S5K5E8_GAIN_MIN,
					      S5K5E8_GAIN_MAX,
					      S5K5E8_GAIN_STEP,
					      S5K5E8_GAIN_DEFAULT);

	s5k5e8->test_pattern =
		v4l2_ctrl_new_std_menu_items(handler,
					     &s5k5e8_ctrl_ops,
				V4L2_CID_TEST_PATTERN,
				ARRAY_SIZE(s5k5e8_test_pattern_menu) - 1,
				0, 0, s5k5e8_test_pattern_menu);

	s5k5e8->h_flip = v4l2_ctrl_new_std(handler, &s5k5e8_ctrl_ops,
				V4L2_CID_HFLIP, 0, 1, 1, 0);

	s5k5e8->v_flip = v4l2_ctrl_new_std(handler, &s5k5e8_ctrl_ops,
				V4L2_CID_VFLIP, 0, 1, 1, 0);
	s5k5e8->flip = 0;

	if (handler->error) {
		ret = handler->error;
		dev_err(&s5k5e8->client->dev,
			"Failed to init controls(%d)\n", ret);
		goto err_free_handler;
	}

	s5k5e8->subdev.ctrl_handler = handler;

	return 0;

err_free_handler:
	v4l2_ctrl_handler_free(handler);

	return ret;
}

static int s5k5e8_check_sensor_id(struct s5k5e8 *s5k5e8,
				  struct i2c_client *client)
{
	struct device *dev = &s5k5e8->client->dev;
	u32 reg = 0;
	int ret;

	ret = s5k5e8_read_reg(client, S5K5E8_REG_CHIP_ID,
			      S5K5E8_REG_VALUE_16BIT, &reg);
	if (reg != CHIP_ID) {
		dev_err(dev, "Unexpected sensor id(%06x), ret(%d)\n", reg, ret);
		return -ENODEV;
	}
	dev_info(dev, "detected s5kgm1%04x sensor\n", reg);
	return 0;
}

static int s5k5e8_configure_regulators(struct s5k5e8 *s5k5e8)
{
	unsigned int i;

	for (i = 0; i < S5K5E8_NUM_SUPPLIES; i++)
		s5k5e8->supplies[i].supply = s5k5e8_supply_names[i];

	return devm_regulator_bulk_get(&s5k5e8->client->dev,
				       S5K5E8_NUM_SUPPLIES,
				       s5k5e8->supplies);
}

static int s5k5e8_probe(struct i2c_client *client,
			const struct i2c_device_id *id)
{
	struct device *dev = &client->dev;
	struct device_node *node = dev->of_node;
	struct s5k5e8 *s5k5e8;
	struct v4l2_subdev *sd;
	char facing[2];
	int ret;
	u32 i, hdr_mode = 0;

	dev_info(dev, "driver version: %02x.%02x.%02x",
		 DRIVER_VERSION >> 16,
		 (DRIVER_VERSION & 0xff00) >> 8,
		 DRIVER_VERSION & 0x00ff);

	s5k5e8 = devm_kzalloc(dev, sizeof(*s5k5e8), GFP_KERNEL);
	if (!s5k5e8)
		return -ENOMEM;

	of_property_read_u32(node, OF_CAMERA_HDR_MODE, &hdr_mode);
	ret = of_property_read_u32(node, RKMODULE_CAMERA_MODULE_INDEX,
				   &s5k5e8->module_index);
	ret |= of_property_read_string(node, RKMODULE_CAMERA_MODULE_FACING,
				       &s5k5e8->module_facing);
	ret |= of_property_read_string(node, RKMODULE_CAMERA_MODULE_NAME,
				       &s5k5e8->module_name);
	ret |= of_property_read_string(node, RKMODULE_CAMERA_LENS_NAME,
				       &s5k5e8->len_name);
	if (ret) {
		dev_err(dev, "could not get module information!\n");
		return -EINVAL;
	}

	s5k5e8->client = client;
	for (i = 0; i < ARRAY_SIZE(supported_modes); i++) {
		if (hdr_mode == supported_modes[i].hdr_mode) {
			s5k5e8->cur_mode = &supported_modes[i];
			break;
		}
	}
	if (i == ARRAY_SIZE(supported_modes))
		s5k5e8->cur_mode = &supported_modes[0];

	s5k5e8->xvclk = devm_clk_get(dev, "xvclk");
	if (IS_ERR(s5k5e8->xvclk)) {
		dev_err(dev, "Failed to get xvclk\n");
		return -EINVAL;
	}

	s5k5e8->pwren_gpio = devm_gpiod_get(dev, "pwren", GPIOD_OUT_LOW);
	if (IS_ERR(s5k5e8->pwren_gpio))
		dev_warn(dev, "Failed to get pwren-gpios\n");

	s5k5e8->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(s5k5e8->reset_gpio))
		dev_warn(dev, "Failed to get reset-gpios\n");

	s5k5e8->pwdn_gpio = devm_gpiod_get(dev, "pwdn", GPIOD_OUT_LOW);
	if (IS_ERR(s5k5e8->pwdn_gpio))
		dev_warn(dev, "Failed to get pwdn-gpios\n");

	s5k5e8->iovdd_gpio = devm_gpiod_get(dev, "iovdd", GPIOD_OUT_LOW);
	if (IS_ERR(s5k5e8->iovdd_gpio))
		dev_warn(dev, "Failed to get iovdd-gpios\n");

	s5k5e8->avdd_gpio = devm_gpiod_get(dev, "avdd", GPIOD_OUT_LOW);
	if (IS_ERR(s5k5e8->avdd_gpio))
		dev_warn(dev, "Failed to get avdd-gpios\n");

	s5k5e8->dvdd_gpio = devm_gpiod_get(dev, "dvdd", GPIOD_OUT_LOW);
	if (IS_ERR(s5k5e8->dvdd_gpio))
		dev_warn(dev, "Failed to get dvdd-gpios\n");

	s5k5e8->pinctrl = devm_pinctrl_get(dev);
	if (!IS_ERR(s5k5e8->pinctrl)) {
		s5k5e8->pins_default =
			pinctrl_lookup_state(s5k5e8->pinctrl,
					     OF_CAMERA_PINCTRL_STATE_DEFAULT);
		if (IS_ERR(s5k5e8->pins_default))
			dev_err(dev, "could not get default pinstate\n");

		s5k5e8->pins_sleep =
			pinctrl_lookup_state(s5k5e8->pinctrl,
					     OF_CAMERA_PINCTRL_STATE_SLEEP);
		if (IS_ERR(s5k5e8->pins_sleep))
			dev_err(dev, "could not get sleep pinstate\n");
	} else {
		dev_err(dev, "no pinctrl\n");
	}

	ret = s5k5e8_configure_regulators(s5k5e8);
	if (ret) {
		dev_err(dev, "Failed to get power regulators\n");
		return ret;
	}

	mutex_init(&s5k5e8->mutex);

	sd = &s5k5e8->subdev;
	v4l2_i2c_subdev_init(sd, client, &s5k5e8_subdev_ops);
	ret = s5k5e8_initialize_controls(s5k5e8);
	if (ret)
		goto err_destroy_mutex;

	ret = __s5k5e8_power_on(s5k5e8);
	if (ret)
		goto err_free_handler;

	ret = s5k5e8_check_sensor_id(s5k5e8, client);
	if (ret)
		goto err_power_off;

#ifdef CONFIG_VIDEO_V4L2_SUBDEV_API
	sd->internal_ops = &s5k5e8_internal_ops;
	sd->flags |= V4L2_SUBDEV_FL_HAS_DEVNODE |
		     V4L2_SUBDEV_FL_HAS_EVENTS;
#endif
#if defined(CONFIG_MEDIA_CONTROLLER)
	s5k5e8->pad.flags = MEDIA_PAD_FL_SOURCE;
	sd->entity.function = MEDIA_ENT_F_CAM_SENSOR;
	ret = media_entity_pads_init(&sd->entity, 1, &s5k5e8->pad);
	if (ret < 0)
		goto err_power_off;
#endif

	memset(facing, 0, sizeof(facing));
	if (strcmp(s5k5e8->module_facing, "back") == 0)
		facing[0] = 'b';
	else
		facing[0] = 'f';

	snprintf(sd->name, sizeof(sd->name), "m%02d_%s_%s %s",
		 s5k5e8->module_index, facing,
		 S5K5E8_NAME, dev_name(sd->dev));
	ret = v4l2_async_register_subdev_sensor(sd);
	if (ret) {
		dev_err(dev, "v4l2 async register subdev failed\n");
		goto err_clean_entity;
	}

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);
	pm_runtime_idle(dev);

	return 0;

err_clean_entity:
#if defined(CONFIG_MEDIA_CONTROLLER)
	media_entity_cleanup(&sd->entity);
#endif
err_power_off:
	__s5k5e8_power_off(s5k5e8);
err_free_handler:
	v4l2_ctrl_handler_free(&s5k5e8->ctrl_handler);
err_destroy_mutex:
	mutex_destroy(&s5k5e8->mutex);

	return ret;
}

static void s5k5e8_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct s5k5e8 *s5k5e8 = to_s5k5e8(sd);

	v4l2_async_unregister_subdev(sd);
#if defined(CONFIG_MEDIA_CONTROLLER)
	media_entity_cleanup(&sd->entity);
#endif
	v4l2_ctrl_handler_free(&s5k5e8->ctrl_handler);
	mutex_destroy(&s5k5e8->mutex);

	pm_runtime_disable(&client->dev);
	if (!pm_runtime_status_suspended(&client->dev))
		__s5k5e8_power_off(s5k5e8);
	pm_runtime_set_suspended(&client->dev);
}

#if IS_ENABLED(CONFIG_OF)
static const struct of_device_id s5k5e8_of_match[] = {
	{ .compatible = "samsung,s5k5e8" },
	{},
};
MODULE_DEVICE_TABLE(of, s5k5e8_of_match);
#endif

static const struct i2c_device_id s5k5e8_match_id[] = {
	{ "samsung,s5k5e8", 0 },
	{ },
};

static struct i2c_driver s5k5e8_i2c_driver = {
	.driver = {
		.name = S5K5E8_NAME,
		.pm = &s5k5e8_pm_ops,
		.of_match_table = of_match_ptr(s5k5e8_of_match),
	},
	.probe		= &s5k5e8_probe,
	.remove		= &s5k5e8_remove,
	.id_table	= s5k5e8_match_id,
};

static int __init sensor_mod_init(void)
{
	return i2c_add_driver(&s5k5e8_i2c_driver);
}

static void __exit sensor_mod_exit(void)
{
	i2c_del_driver(&s5k5e8_i2c_driver);
}

device_initcall_sync(sensor_mod_init);
module_exit(sensor_mod_exit);

MODULE_DESCRIPTION("samsung s5k5e8 sensor driver");
MODULE_LICENSE("GPL v2");
