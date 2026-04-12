#include <stdio.h>
#include <stdint.h>
#include "../data/model_data.h"

// Forward pass using 100% Integer Math
void run_inference(const int8_t* img, int32_t* out) {
    int8_t conv_out[4][26][26] = {0};
    int8_t pool_out[4][13][13] = {0};

    // 1. Conv2D Layer
    for (int c = 0; c < 4; c++) {
        for (int y = 0; y < 26; y++) {
            for (int x = 0; x < 26; x++) {
                // Initialize accumulator with the INT32 Bias
                int32_t sum = conv1_bias[c]; 
                
                for (int ky = 0; ky < 3; ky++) {
                    for (int kx = 0; kx < 3; kx++) {
                        int8_t pixel = img[(y + ky) * 28 + (x + kx)];
                        int8_t weight = conv1_weights[c * 9 + ky * 3 + kx];
                        
                        // Multiply int8 * int8, add to int32
                        sum += pixel * weight; 
                    }
                }
                
                // 2. ReLU Activation (Clamps negative sums to 0)
                if (sum < 0) sum = 0;

                // 3. Requantization: scale the INT32 down to INT8 safely
                // using the fixed-point multiplier exported from Python
                int32_t scaled = (sum * M1_NUM) >> M1_SHIFT;
                
                // Clamp to INT8 Max
                if (scaled > 127) scaled = 127; 
                
                conv_out[c][y][x] = (int8_t)scaled;
            }
        }
    }

    // 4. MaxPool2D (Operating entirely on INT8 values)
    for (int c = 0; c < 4; c++) {
        for (int y = 0; y < 13; y++) {
            for (int x = 0; x < 13; x++) {
                int8_t max_val = -128; // Minimum possible INT8 value
                for (int py = 0; py < 2; py++) {
                    for (int px = 0; px < 2; px++) {
                        int8_t val = conv_out[c][y * 2 + py][x * 2 + px];
                        if (val > max_val) {
                            max_val = val;
                        }
                    }
                }
                pool_out[c][y][x] = max_val;
            }
        }
    }

    // 5. Fully Connected Layer
    for (int i = 0; i < 10; i++) {
        // Initialize accumulator with INT32 bias
        int32_t sum = fc_bias[i];
        
        for (int j = 0; j < 676; j++) {
            int c = j / 169;
            int rem = j % 169;
            int y = rem / 13;
            int x = rem % 13;
            
            int8_t activation = pool_out[c][y][x];
            int8_t weight = fc_weights[i * 676 + j];
            
            sum += activation * weight;
        }
        
        // Final Trick: Leave outputs as INT32. We don't need to requantize
        // back to INT8 because we only care about finding the highest number!
        out[i] = sum; 
    }
}

int main() {
    const int8_t* test_images[10] = {
        sample_img_0, sample_img_1, sample_img_2, sample_img_3, sample_img_4, 
        sample_img_5, sample_img_6, sample_img_7, sample_img_8, sample_img_9
    };

    printf("Running PURE INTEGER C Inference on MNIST...\n");
    printf("--------------------------------------------\n");

    int correct_count = 0;

    for (int target = 0; target < 10; target++) {
        int32_t predictions[10] = {0}; // Store raw INT32 logits
        
        run_inference(test_images[target], predictions);
        
        // Argmax: Find the index with the highest INT32 score
        int best_class = 0;
        int32_t max_score = predictions[0];
        for (int i = 1; i < 10; i++) {
            if (predictions[i] > max_score) {
                max_score = predictions[i];
                best_class = i;
            }
        }
        
        printf("Actual: %d | Predicted: %d (Raw INT32 Score: %d)\n", target, best_class, max_score);
        if (best_class == target) {
            correct_count++;
        }
    }

    printf("--------------------------------------------\n");
    printf("Accuracy: %d/10\n", correct_count);

    return 0;
}