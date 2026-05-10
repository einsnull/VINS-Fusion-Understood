#!/bin/bash
# Complete comparison test for VINS-Fusion
# Compares: Original, SuperPoint+Flow, SuperPoint+LightGlue
# Also compares with ground truth if available

set -e

# Configuration
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="/tmp/vins_comparison_$(date +%Y%m%d_%H%M%S)"
DURATION=60  # seconds per test

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}VINS-Fusion Complete Comparison Test${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Dataset: $DATASET_DIR"
echo "Results: $RESULTS_DIR"
echo "Duration per test: ${DURATION}s"
echo ""

# Check dataset exists
if [ ! -d "$DATASET_DIR" ]; then
    echo -e "${RED}Error: Dataset not found at $DATASET_DIR${NC}"
    exit 1
fi

# Check for ground truth
GROUND_TRUTH=""
if [ -f "$DATASET_DIR/mav0/state_groundtruth_estimate0/data.csv" ]; then
    GROUND_TRUTH="$DATASET_DIR/mav0/state_groundtruth_estimate0/data.csv"
    echo -e "${GREEN}Ground truth found: $GROUND_TRUTH${NC}"
else
    echo -e "${YELLOW}Warning: Ground truth not found${NC}"
fi

mkdir -p "$RESULTS_DIR"

# Function to run a single test
run_test() {
    local IMAGE=$1
    local CONFIG=$2
    local TEST_NAME=$3
    local TEST_DIR="$RESULTS_DIR/$TEST_NAME"
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}Running: $TEST_NAME${NC}"
    echo -e "${GREEN}=========================================${NC}"
    
    mkdir -p "$TEST_DIR"
    
    # Ensure X11 access
    xhost +local:docker 2>/dev/null || true
    
    # Start container with VINS
    echo "Starting VINS container..."
    docker run -d --rm \
        --name "vins_test" \
        --net=host \
        --gpus all \
        -e DISPLAY=$DISPLAY \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "$(pwd)/..:/root/catkin_ws/src/VINS-Fusion" \
        -v "$DATASET_DIR:/dataset:ro" \
        -v "$TEST_DIR:/root/output" \
        $IMAGE \
        /bin/bash -c "
            source /opt/ros/kinetic/setup.bash
            source /root/catkin_ws/devel/setup.bash
            
            # Start roscore
            roscore &
            sleep 3
            
            # Start VINS node
            rosrun vins vins_node $CONFIG &
            VINS_PID=\$!
            
            # Wait for initialization
            sleep 8
            
            # Record trajectory topic
            rosbag record -O /root/output/trajectory.bag /vins_estimator/odometry &
            RECORD_PID=\$!
            
            # Play dataset
            rosbag play /dataset/*.bag --clock &
            BAG_PID=\$!
            
            # Wait for duration
            sleep $DURATION
            
            # Stop recording
            kill \$RECORD_PID 2>/dev/null || true
            sleep 2
            
            # Stop bag
            kill \$BAG_PID 2>/dev/null || true
            sleep 2
            
            # Stop VINS
            kill \$VINS_PID 2>/dev/null || true
            sleep 2
            
            echo 'Test completed'
        "
    
    # Wait for test to complete
    echo "Running test for ${DURATION} seconds..."
    sleep $((DURATION + 15))
    
    # Stop container if still running
    if docker ps | grep -q "vins_test"; then
        echo "Stopping container..."
        docker stop "vins_test" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✓ Completed: $TEST_NAME${NC}"
    echo "Results saved to: $TEST_DIR"
    ls -la "$TEST_DIR" 2>/dev/null || true
}

# Run tests
echo ""
echo -e "${YELLOW}Test 1/3: Original VINS-Fusion${NC}"
run_test "ros-vins-fusion-rviz:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml" \
    "01_original"

echo ""
echo -e "${YELLOW}Test 2/3: SuperPoint + Optical Flow${NC}"
run_test "vins-fusion-tensorrt:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml" \
    "02_superpoint_flow"

echo ""
echo -e "${YELLOW}Test 3/3: SuperPoint + LightGlue${NC}"
# Create LightGlue config
LIGHTGLUE_CONFIG="$RESULTS_DIR/lightglue_config.yaml"
cp "/storage/VINS-Fusion-Understood/config/euroc/euroc_stereo_imu_config_deep.yaml" "$LIGHTGLUE_CONFIG"
sed -i 's/deep_feature_mode: 0/deep_feature_mode: 1/' "$LIGHTGLUE_CONFIG"

run_test "vins-fusion-tensorrt:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml" \
    "03_superpoint_lightglue"

# Compare with ground truth if available
if [ -n "$GROUND_TRUTH" ]; then
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}Comparing with Ground Truth${NC}"
    echo -e "${GREEN}=========================================${NC}"
    
    for test_dir in "$RESULTS_DIR"/0*/; do
        test_name=$(basename "$test_dir")
        bag_file="$test_dir/trajectory.bag"
        
        if [ -f "$bag_file" ]; then
            echo ""
            echo "Comparing $test_name..."
            
            # Run comparison script in Docker
            docker run --rm \
                -v "$GROUND_TRUTH:/ground_truth.csv:ro" \
                -v "$bag_file:/trajectory.bag:ro" \
                -v "$(pwd)/compare_with_groundtruth.py:/compare.py:ro" \
                ros:kinetic \
                /bin/bash -c "
                    source /opt/ros/kinetic/setup.bash
                    python3 /compare.py /ground_truth.csv /trajectory.bag > /tmp/comparison_result.txt 2>&1 || true
                    cat /tmp/comparison_result.txt
                " > "$test_dir/comparison.txt" 2>&1 || true
            
            if [ -f "$test_dir/comparison.txt" ]; then
                cat "$test_dir/comparison.txt"
            fi
        fi
    done
fi

# Generate report
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}Generating comparison report...${NC}"
echo -e "${GREEN}=========================================${NC}"

cat > "$RESULTS_DIR/report.md" << EOF
# VINS-Fusion Performance Comparison Report

Generated: $(date)
Dataset: $DATASET_DIR
Duration per test: ${DURATION}s

## Test Results

### 1. Original VINS-Fusion
- Directory: $RESULTS_DIR/01_original/
- Features: goodFeaturesToTrack + LK Optical Flow

### 2. SuperPoint + Optical Flow
- Directory: $RESULTS_DIR/02_superpoint_flow/
- Features: SuperPoint (TensorRT) + LK Optical Flow

### 3. SuperPoint + LightGlue
- Directory: $RESULTS_DIR/03_superpoint_lightglue/
- Features: SuperPoint (TensorRT) + LightGlue Matching (TensorRT)

## Ground Truth Comparison
EOF

if [ -n "$GROUND_TRUTH" ]; then
    echo "Ground truth: $GROUND_TRUTH" >> "$RESULTS_DIR/report.md"
    echo "" >> "$RESULTS_DIR/report.md"
    
    for test_dir in "$RESULTS_DIR"/0*/; do
        test_name=$(basename "$test_dir")
        if [ -f "$test_dir/comparison.txt" ]; then
            echo "### $test_name" >> "$RESULTS_DIR/report.md"
            echo "\`\`\`" >> "$RESULTS_DIR/report.md"
            cat "$test_dir/comparison.txt" >> "$RESULTS_DIR/report.md"
            echo "\`\`\`" >> "$RESULTS_DIR/report.md"
            echo "" >> "$RESULTS_DIR/report.md"
        fi
    done
else
    echo "Ground truth not available for this dataset" >> "$RESULTS_DIR/report.md"
fi

cat >> "$RESULTS_DIR/report.md" << EOF

## Analysis

### Key Metrics to Compare
1. **Tracking Accuracy**: RMSE of trajectory vs ground truth
2. **Feature Quality**: Number of tracked features, inlier ratio
3. **Processing Speed**: FPS / processing time per frame
4. **Robustness**: Performance in challenging scenarios (motion blur, low texture, etc.)

### Expected Results
- **Original**: Fastest processing, may struggle with low texture
- **SuperPoint + Flow**: Better feature quality, slightly slower
- **SuperPoint + LightGlue**: Best matching accuracy, slowest due to neural network

EOF

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}All Tests Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Results directory: $RESULTS_DIR"
echo ""
echo "Structure:"
echo "  01_original/              - Original VINS-Fusion"
echo "  02_superpoint_flow/       - SuperPoint + Optical Flow"
echo "  03_superpoint_lightglue/  - SuperPoint + LightGlue"
echo "  report.md                 - Comparison report"
echo ""

if [ -n "$GROUND_TRUTH" ]; then
    echo -e "${GREEN}Ground truth comparison completed${NC}"
fi
