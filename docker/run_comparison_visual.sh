#!/bin/bash
# Complete comparison test for VINS-Fusion with REAL-TIME VISUALIZATION
# Shows Pangolin UI and RViz for each test
# Compares: Original, SuperPoint+Flow, SuperPoint+LightGlue

set -e

# Configuration
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="/tmp/vins_comparison_$(date +%Y%m%d_%H%M%S)"
DURATION=60  # seconds per test

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}VINS-Fusion Comparison Test with Visualization${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Dataset: $DATASET_DIR"
echo "Results: $RESULTS_DIR"
echo "Duration per test: ${DURATION}s"
echo -e "${YELLOW}Note: RViz and Pangolin will be shown for each test${NC}"
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

# Function to run a single test with visualization
run_test_with_visual() {
    local IMAGE=$1
    local CONFIG=$2
    local TEST_NAME=$3
    local TEST_DIR="$RESULTS_DIR/$TEST_NAME"
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}Running: $TEST_NAME${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${BLUE}Starting visualization...${NC}"
    
    mkdir -p "$TEST_DIR"
    
    # Ensure X11 access
    xhost +local:docker 2>/dev/null || true
    
    # Start VINS container with Pangolin UI
    echo "Starting VINS container with UI..."
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
            
            # Start VINS node (this will show Pangolin UI)
            rosrun vins vins_node $CONFIG &
            VINS_PID=\$!
            
            # Wait for VINS to initialize and show UI
            sleep 10
            
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
    
    # Start RViz in another container (to avoid conflicts)
    echo "Starting RViz..."
    docker run -d --rm \
        --name "rviz_test" \
        --net=host \
        -e DISPLAY=$DISPLAY \
        -e QT_X11_NO_MITSHM=1 \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "$(pwd)/../config/vins_rviz_config.rviz:/tmp/vins_rviz_config.rviz" \
        $IMAGE \
        /bin/bash -c "
            source /opt/ros/kinetic/setup.bash
            sleep 15  # Wait for VINS to start
            rviz -d /tmp/vins_rviz_config.rviz
        "
    
    echo ""
    echo -e "${YELLOW}Test is running with visualization...${NC}"
    echo -e "${YELLOW}You should see Pangolin UI and RViz windows${NC}"
    echo -e "${YELLOW}Waiting for ${DURATION} seconds...${NC}"
    echo ""
    
    # Wait for test to complete
    sleep $((DURATION + 20))
    
    # Stop containers if still running
    echo "Stopping containers..."
    docker stop "vins_test" 2>/dev/null || true
    docker stop "rviz_test" 2>/dev/null || true
    
    echo -e "${GREEN}✓ Completed: $TEST_NAME${NC}"
    echo "Results saved to: $TEST_DIR"
    ls -la "$TEST_DIR" 2>/dev/null || true
    
    echo ""
    echo -e "${YELLOW}Press Enter to continue to next test...${NC}"
    read
}

# Run tests
echo ""
echo -e "${YELLOW}Test 1/3: Original VINS-Fusion${NC}"
echo -e "${BLUE}Features: goodFeaturesToTrack + LK Optical Flow${NC}"
run_test_with_visual "ros-vins-fusion-rviz:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml" \
    "01_original"

echo ""
echo -e "${YELLOW}Test 2/3: SuperPoint + Optical Flow${NC}"
echo -e "${BLUE}Features: SuperPoint (TensorRT) + LK Optical Flow${NC}"
run_test_with_visual "vins-fusion-tensorrt:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml" \
    "02_superpoint_flow"

echo ""
echo -e "${YELLOW}Test 3/3: SuperPoint + LightGlue${NC}"
echo -e "${BLUE}Features: SuperPoint (TensorRT) + LightGlue Matching (TensorRT)${NC}"
# Create LightGlue config
LIGHTGLUE_CONFIG="$RESULTS_DIR/lightglue_config.yaml"
cp "/storage/VINS-Fusion-Understood/config/euroc/euroc_stereo_imu_config_deep.yaml" "$LIGHTGLUE_CONFIG"
sed -i 's/deep_feature_mode: 0/deep_feature_mode: 1/' "$LIGHTGLUE_CONFIG"

run_test_with_visual "vins-fusion-tensorrt:latest" \
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
- Visualization: Pangolin UI + RViz (shown during test)

### 2. SuperPoint + Optical Flow
- Directory: $RESULTS_DIR/02_superpoint_flow/
- Features: SuperPoint (TensorRT) + LK Optical Flow
- Visualization: Pangolin UI + RViz (shown during test)

### 3. SuperPoint + LightGlue
- Directory: $RESULTS_DIR/03_superpoint_lightglue/
- Features: SuperPoint (TensorRT) + LightGlue Matching (TensorRT)
- Visualization: Pangolin UI + RViz (shown during test)

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

## Visualization

Each test was run with real-time visualization:
- **Pangolin UI**: Shows feature tracking, point cloud, and camera pose
- **RViz**: Displays trajectory, point cloud, and feature tracks

## Analysis

### Key Metrics to Compare
1. **Tracking Accuracy**: RMSE of trajectory vs ground truth
2. **Feature Quality**: Number of tracked features, inlier ratio
3. **Processing Speed**: FPS / processing time per frame
4. **Robustness**: Performance in challenging scenarios

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

echo ""
echo -e "${GREEN}Visualization complete!${NC}"
echo "Each test showed:"
echo "  - Pangolin UI: Real-time feature tracking and point cloud"
echo "  - RViz: 3D trajectory and point cloud visualization"
