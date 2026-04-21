// FPGA Inference Demo for DE2 Board
// ==================================
// Runs MNIST inference with MAC4 coprocessor on PicoRV32.
//
// Controls:
//   SW[0]-SW[9]: select test image (highest switch wins)
//   HEX0:        predicted digit (0-9), blank when no switch active
//   LEDR[9:0]:   confidence bar graph (cumulative, 10% per LED)
//   LEDG[0]:     green = CPU running (hardware-driven)
//   LEDR[17]:    red = CPU reset/trapped (hardware-driven)

#include <stdint.h>
#include "../../../data/model_weights.h"

// -------------------------------------------------------
// Memory-mapped I/O registers
// -------------------------------------------------------
#define CONSOLE_OUT (*(volatile uint32_t *)0x10000000)
#define SEG7_REG    (*(volatile uint32_t *)0x30000004)
#define SW_KEY_REG  (*(volatile uint32_t *)0x30000008)
#define LED_REG     (*(volatile uint32_t *)0x3000000C)

// -------------------------------------------------------
// Minimal runtime support (GCC emits calls to these)
// -------------------------------------------------------
void *memset(void *s, int c, unsigned int n)
{
	char *p = s;
	while (n--) *p++ = (char)c;
	return s;
}

void *memcpy(void *dest, const void *src, unsigned int n)
{
	char *d = dest;
	const char *s = src;
	while (n--) *d++ = *s++;
	return dest;
}

// -------------------------------------------------------
// Console output helpers (for simulation debug)
// -------------------------------------------------------
static void putchar_out(int c) { CONSOLE_OUT = c; }

static void print(const char *s)
{
	while (*s) CONSOLE_OUT = *(s++);
}

static void print_dec(unsigned int val)
{
	char buf[12];
	int i = 0;
	if (val == 0) { putchar_out('0'); return; }
	while (val) { buf[i++] = '0' + (val % 10); val /= 10; }
	while (i--) putchar_out(buf[i]);
}

// -------------------------------------------------------
// MAC4 Custom Instruction (opcode 0x2B, custom1 R-type)
// -------------------------------------------------------
#define MAC4(rd, rs1, rs2) \
	__asm__ volatile (".insn r 0x2B, 0, 0, %0, %1, %2" \
	                  : "=r"(rd) : "r"(rs1), "r"(rs2))

static inline uint32_t pack4(const int8_t *p)
{
	return (uint32_t)((uint8_t)p[0])
	     | ((uint32_t)((uint8_t)p[1]) << 8)
	     | ((uint32_t)((uint8_t)p[2]) << 16)
	     | ((uint32_t)((uint8_t)p[3]) << 24);
}

// -------------------------------------------------------
// Neural network inference (MAC4-accelerated)
// -------------------------------------------------------
static void run_inference(const int8_t *img, int32_t *out)
{
	int8_t conv_out[4][26][26] = {0};
	int8_t pool_out[4][13][13] = {0};
	int8_t flat[676];

	// Pad conv weights: 3x3 -> 3 rows of 4 (zero-padded)
	int8_t conv1_w_pad[4][12];
	for (int c = 0; c < 4; c++) {
		for (int ky = 0; ky < 3; ky++) {
			conv1_w_pad[c][ky*4+0] = conv1_weights[c*9 + ky*3 + 0];
			conv1_w_pad[c][ky*4+1] = conv1_weights[c*9 + ky*3 + 1];
			conv1_w_pad[c][ky*4+2] = conv1_weights[c*9 + ky*3 + 2];
			conv1_w_pad[c][ky*4+3] = 0;
		}
	}

	// Conv2D with MAC4
	for (int c = 0; c < 4; c++) {
		uint32_t w_row0 = pack4(&conv1_w_pad[c][0]);
		uint32_t w_row1 = pack4(&conv1_w_pad[c][4]);
		uint32_t w_row2 = pack4(&conv1_w_pad[c][8]);

		for (int y = 0; y < 26; y++) {
			for (int x = 0; x < 26; x++) {
				int32_t sum = conv1_bias[c];
				int32_t partial;

				uint32_t px0 = pack4(&img[(y+0)*28 + x]);
				MAC4(partial, px0, w_row0);
				sum += partial;

				uint32_t px1 = pack4(&img[(y+1)*28 + x]);
				MAC4(partial, px1, w_row1);
				sum += partial;

				uint32_t px2 = pack4(&img[(y+2)*28 + x]);
				MAC4(partial, px2, w_row2);
				sum += partial;

				if (sum < 0) sum = 0; // ReLU

				int32_t scaled = (sum * M1_NUM) >> M1_SHIFT;
				if (scaled > 127) scaled = 127;

				conv_out[c][y][x] = (int8_t)scaled;
			}
		}
	}

	// MaxPool2D
	for (int c = 0; c < 4; c++) {
		for (int y = 0; y < 13; y++) {
			for (int x = 0; x < 13; x++) {
				int8_t max_val = -128;
				for (int py = 0; py < 2; py++)
					for (int px = 0; px < 2; px++) {
						int8_t val = conv_out[c][y*2+py][x*2+px];
						if (val > max_val) max_val = val;
					}
				pool_out[c][y][x] = max_val;
			}
		}
	}

	// Flatten
	for (int j = 0; j < 676; j++) {
		int c   = j / 169;
		int rem = j % 169;
		flat[j] = pool_out[c][rem/13][rem%13];
	}

	// FC layer with MAC4
	for (int i = 0; i < 10; i++) {
		int32_t sum = fc_bias[i];
		const int8_t *w = &fc_weights[i * 676];
		for (int j = 0; j < 676; j += 4) {
			uint32_t a_packed = pack4(&flat[j]);
			uint32_t w_packed = pack4(&w[j]);
			int32_t partial;
			MAC4(partial, a_packed, w_packed);
			sum += partial;
		}
		out[i] = sum;
	}
}

// -------------------------------------------------------
// Compute LED bar pattern from confidence percentage
//   0-10%  -> LEDR[0]
//   11-20% -> LEDR[1]
//   ...
//   91-100% -> LEDR[9]
//   Cumulative: e.g. 80% lights LEDR[0] through LEDR[7]
// -------------------------------------------------------
static uint32_t confidence_to_leds(int confidence)
{
	int idx;
	if (confidence <= 0)
		idx = 0;
	else if (confidence > 100)
		idx = 9;
	else
		idx = (confidence - 1) / 10;

	// Light all LEDs from 0 to idx (inclusive)
	return (1u << (idx + 1)) - 1;
}

// -------------------------------------------------------
// Main: switch-driven inference demo loop
// -------------------------------------------------------
void main(void)
{
	const int8_t *test_images[10] = {
		sample_img_0, sample_img_1, sample_img_2, sample_img_3, sample_img_4,
		sample_img_5, sample_img_6, sample_img_7, sample_img_8, sample_img_9
	};

	print("PicoRV32 DE2 Inference Demo\n");
	print("Flip SW[0]-SW[9] to classify MNIST images\n");

	// ---- Startup diagnostic: visible proof that firmware runs ----
	// Show 'F' (0xF) on HEX0 and light all confidence LEDs briefly.
	// If you see this on the board, the firmware is alive.
	SEG7_REG = 0xF;
	LED_REG  = 0x3FF;   // all 10 red confidence LEDs on
	for (volatile int i = 0; i < 2000000; i++) {}  // ~40 ms at 50 MHz
	// ---- End startup diagnostic ----

	// Blank display and LEDs at start
	SEG7_REG = 0xFFFFFFFF;
	LED_REG  = 0;

	int last_selected = -1;

	while (1) {
		unsigned int raw = SW_KEY_REG;
		unsigned int sw = (raw >> 4) & 0x3FFFF;  // SW[17:0]

		// Find highest active switch among SW[0]-SW[9]
		int highest = -1;
		for (int i = 9; i >= 0; i--) {
			if (sw & (1 << i)) {
				highest = i;
				break;
			}
		}

		if (highest >= 0 && highest != last_selected) {
			// New image selected - run inference
			print("Image ");
			print_dec(highest);
			print(": classifying... ");

			int32_t predictions[10] = {0};
			run_inference(test_images[highest], predictions);

			// Argmax
			int best_class = 0;
			int32_t max_score = predictions[0];
			for (int i = 1; i < 10; i++) {
				if (predictions[i] > max_score) {
					max_score = predictions[i];
					best_class = i;
				}
			}

			// Confidence: winner's share of total positive scores (%)
			int32_t pos_sum = 0;
			for (int i = 0; i < 10; i++)
				if (predictions[i] > 0)
					pos_sum += predictions[i];
			int confidence = (pos_sum > 0)
				? (int)((100 * (int64_t)max_score) / pos_sum)
				: 0;

			// Update 7-segment display with predicted digit
			SEG7_REG = (uint32_t)best_class;

			// Update confidence LED bar
			LED_REG = confidence_to_leds(confidence);

			print("predicted ");
			print_dec(best_class);
			print(" (conf ");
			print_dec(confidence);
			print("%)\n");

			last_selected = highest;
		}
		else if (highest < 0 && last_selected != -1) {
			// All switches off - blank display and LEDs
			SEG7_REG = 0xFFFFFFFF;
			LED_REG  = 0;
			print("All switches off - display blanked\n");
			last_selected = -1;
		}
	}
}
