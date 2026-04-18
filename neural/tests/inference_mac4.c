#include <stdint.h>
#include "../data/model_weights.h"

// GCC emits calls to memset for array = {0} initialization
void *memset(void *s, int c, unsigned int n)
{
	char *p = s;
	while (n--)
		*p++ = (char)c;
	return s;
}

// GCC emits calls to memcpy for struct/array copies
void *memcpy(void *dest, const void *src, unsigned int n)
{
	char *d = dest;
	const char *s = src;
	while (n--)
		*d++ = *s++;
	return dest;
}

// I/O port for character output (directly to testbench console)
#define OUTPORT 0x10000000

static void print_chr(char ch)
{
	*((volatile uint32_t*)OUTPORT) = ch;
}

static void print_str(const char *p)
{
	while (*p != 0)
		*((volatile uint32_t*)OUTPORT) = *(p++);
}

static void print_dec(unsigned int val)
{
	char buffer[10];
	char *p = buffer;
	while (val || p == buffer) {
		*(p++) = val % 10;
		val = val / 10;
	}
	while (p != buffer)
		*((volatile uint32_t*)OUTPORT) = '0' + *(--p);
}

static void print_signed(int32_t val)
{
	if (val < 0) {
		print_chr('-');
		print_dec((unsigned int)(-val));
	} else {
		print_dec((unsigned int)val);
	}
}

// Read PicoRV32 cycle counter (rdcycle CSR)
static inline uint32_t rdcycle(void)
{
	uint32_t c;
	__asm__ volatile ("rdcycle %0" : "=r"(c));
	return c;
}

// ===========================================================================
// MAC4 Custom Instruction (PCPI coprocessor)
//
// Encodes as a custom1 R-type instruction (opcode 0x2B):
//   .insn r 0x2B, funct3=0, funct7=0, rd, rs1, rs2
//
// Semantics (implemented in picorv32_pcpi_mac.v):
//   rs1 = packed 4x int8 activations  {a3, a2, a1, a0}
//   rs2 = packed 4x int8 weights      {w3, w2, w1, w0}
//   rd  = a0*w0 + a1*w1 + a2*w2 + a3*w3   (int32 result)
//
// This replaces 4 loads + 4 multiplies + 3 adds with a single instruction.
//
// Conv2D acceleration strategy:
//   Pad each 3-element kernel row to 4 with a zero weight.
//   Read 4 consecutive image bytes per row (4th pixel × 0 = harmless).
//   3 MAC4 calls replace 9 scalar multiply-adds per output pixel.
//   Conv2D: 4×26×26×3 = 8,112 MAC4 ops  (was 24,336 scalar MACs)
//   FC:     10×169     = 1,690 MAC4 ops  (was  6,760 scalar MACs)
// ===========================================================================
#define MAC4(rd, rs1, rs2) \
    __asm__ volatile (".insn r 0x2B, 0, 0, %0, %1, %2" \
                      : "=r"(rd) : "r"(rs1), "r"(rs2))

// Helper: pack 4 consecutive int8 values into a uint32_t for MAC4
static inline uint32_t pack4(const int8_t *p)
{
    return (uint32_t)((uint8_t)p[0])
         | ((uint32_t)((uint8_t)p[1]) << 8)
         | ((uint32_t)((uint8_t)p[2]) << 16)
         | ((uint32_t)((uint8_t)p[3]) << 24);
}

// Forward pass using MAC4 coprocessor for BOTH Conv2D and FC layers
void run_inference(const int8_t* img, int32_t* out) {
    int8_t conv_out[4][26][26] = {0};
    int8_t pool_out[4][13][13] = {0};

    // Flattened pooling output for FC layer (packed access)
    int8_t flat[676];

    // Pre-pad conv weights: 3x3 kernel -> 3 rows of 4 (zero-padded 4th element)
    // This lets us issue 3 MAC4 instructions per output pixel instead of 9 scalar MACs.
    // Layout per filter: {w0,w1,w2,0, w3,w4,w5,0, w6,w7,w8,0}
    int8_t conv1_w_pad[4][12];
    for (int c = 0; c < 4; c++) {
        for (int ky = 0; ky < 3; ky++) {
            conv1_w_pad[c][ky * 4 + 0] = conv1_weights[c * 9 + ky * 3 + 0];
            conv1_w_pad[c][ky * 4 + 1] = conv1_weights[c * 9 + ky * 3 + 1];
            conv1_w_pad[c][ky * 4 + 2] = conv1_weights[c * 9 + ky * 3 + 2];
            conv1_w_pad[c][ky * 4 + 3] = 0; // zero-pad
        }
    }

    // 1. Conv2D Layer - accelerated with MAC4
    //    For each kernel row, read 4 consecutive image bytes (the 4th is a
    //    don't-care pixel that gets multiplied by the zero-padded weight).
    //    3 MAC4 calls replace 9 scalar multiply-adds per output pixel.
    for (int c = 0; c < 4; c++) {
        // Pre-pack the 3 padded weight rows for this filter (constant per filter)
        uint32_t w_row0 = pack4(&conv1_w_pad[c][0]);
        uint32_t w_row1 = pack4(&conv1_w_pad[c][4]);
        uint32_t w_row2 = pack4(&conv1_w_pad[c][8]);

        for (int y = 0; y < 26; y++) {
            for (int x = 0; x < 26; x++) {
                int32_t sum = conv1_bias[c];
                int32_t partial;

                // Row 0: read 4 consecutive pixels starting at (y+0, x)
                uint32_t px0 = pack4(&img[(y + 0) * 28 + x]);
                MAC4(partial, px0, w_row0);
                sum += partial;

                // Row 1: read 4 consecutive pixels starting at (y+1, x)
                uint32_t px1 = pack4(&img[(y + 1) * 28 + x]);
                MAC4(partial, px1, w_row1);
                sum += partial;

                // Row 2: read 4 consecutive pixels starting at (y+2, x)
                uint32_t px2 = pack4(&img[(y + 2) * 28 + x]);
                MAC4(partial, px2, w_row2);
                sum += partial;

                if (sum < 0) sum = 0; // ReLU

                int32_t scaled = (sum * M1_NUM) >> M1_SHIFT; // Requantize
                if (scaled > 127) scaled = 127;

                conv_out[c][y][x] = (int8_t)scaled;
            }
        }
    }

    // 2. MaxPool2D (scalar, same as baseline)
    for (int c = 0; c < 4; c++) {
        for (int y = 0; y < 13; y++) {
            for (int x = 0; x < 13; x++) {
                int8_t max_val = -128;
                for (int py = 0; py < 2; py++) {
                    for (int px = 0; px < 2; px++) {
                        int8_t val = conv_out[c][y * 2 + py][x * 2 + px];
                        if (val > max_val) max_val = val;
                    }
                }
                pool_out[c][y][x] = max_val;
            }
        }
    }

    // 3. Flatten pool_out into contiguous array for packed MAC4 access
    //    Layout: channel-major, matching fc_weights ordering
    for (int j = 0; j < 676; j++) {
        int c   = j / 169;
        int rem = j % 169;
        int y   = rem / 13;
        int x   = rem % 13;
        flat[j] = pool_out[c][y][x];
    }

    // 4. Fully Connected Layer - accelerated with MAC4
    //    676 = 169 * 4  ->  exactly divisible by 4, no remainder loop needed
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

int main() {
    const int8_t* test_images[10] = {
        sample_img_0, sample_img_1, sample_img_2, sample_img_3, sample_img_4,
        sample_img_5, sample_img_6, sample_img_7, sample_img_8, sample_img_9
    };

    print_str("Running MAC4-ACCELERATED Inference on MNIST...\n");
    print_str("-----------------------------------------------\n");

    int correct_count = 0;
    uint32_t total_cycles = 0;

    for (int target = 0; target < 10; target++) {
        int32_t predictions[10] = {0};

        uint32_t cyc_start = rdcycle();
        run_inference(test_images[target], predictions);
        uint32_t cyc_end = rdcycle();
        uint32_t cyc_elapsed = cyc_end - cyc_start;
        total_cycles += cyc_elapsed;

        // Argmax
        int best_class = 0;
        int32_t max_score = predictions[0];
        for (int i = 1; i < 10; i++) {
            if (predictions[i] > max_score) {
                max_score = predictions[i];
                best_class = i;
            }
        }

        // Confidence: winner's share of total positive scores (integer %)
        int32_t pos_sum = 0;
        for (int i = 0; i < 10; i++)
            if (predictions[i] > 0)
                pos_sum += predictions[i];
        int confidence = (pos_sum > 0) ? (int)((100 * (int64_t)max_score) / pos_sum) : 0;

        print_str("Actual: ");
        print_dec(target);
        print_str(" | Predicted: ");
        print_dec(best_class);
        print_str(" (confidence: ");
        print_dec(confidence);
        print_str("%) [cycles: ");
        print_dec(cyc_elapsed);
        print_str("]\n");
        if (best_class == target) {
            correct_count++;
        }
    }

    print_str("-----------------------------------------------\n");
    print_str("Accuracy: ");
    print_dec(correct_count);
    print_str("/10\n");
    print_str("Total cycles (10 images): ");
    print_dec(total_cycles);
    print_str("\n");
    print_str("Avg cycles per image: ");
    print_dec(total_cycles / 10);
    print_str("\n");

    return 0;
}
