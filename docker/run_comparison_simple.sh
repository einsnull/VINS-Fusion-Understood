#!/bin/bash
# Simplified comparison test for VINS-Fusion with TensorRT

set -e

DATASET="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="/tmp/vins_comparison_$(date +%Y%m%d_%H%M%S)"
DURATION=30

mkdir -p "$RESULTS_DIR"

echo "========================================="
echo "VINS-Fusion Comparison Test"
echo "========================================="
echo "Dataset: $DATASET"
echo "Results: $RESULTS_DIR"
echo "Duration: ${DURATION}s per version"
echo ""

# Allow X11 access
xhost +local:docker 2>/dev/null || true

# Function to run a test version
run_test() {
    local CONFIG_FILE=$1
    local TEST_NAME=$2
    local OUTPUT_DIR="$RESULTS_DIR/$TEST_NAME"
    
    mkdir -p "$OUTPUT_DIR"
    
    echo ""
    echo "========================================="
    echo "Testing: $TEST_NAME"
    echo "Config: $CONFIG_FILE"
    echo "========================================="
    
    # Run Docker container with the test
    docker run -i --rm \
        --net=host \
        --gpus all \
        -e DISPLAY=$DISPLAY \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
        -v "$DATASET:/dataset:ro" \
        -v "$OUTPUT_DIR:/output" \
        -v "/storage/VINS-Fusion-Understood/config:/config:ro" \
        vins-fusion-tensorrt:latest \
        /bin/bash -c "
            source /opt/ros/noetic/setup.bash
            source /root/catkin_ws/devel/setup.bash
            
            echo 'Starting VINS-Fusion with $TEST_NAME...'
            
            # Start VINS node in background
            roslaunch vins vins_rviz.launch config:=/config/euroc/$CONFIG_FILE &
            VINS_PID=\$!
            
            # Wait for VINS to initialize
            sleep 5
            
            # Play rosbag
            echo 'Playing rosbag...'
            rosbag play /dataset/*.bag --duration=$DURATION &
            BAG_PID=\$!
            
            # Wait for bag to finish
            wait \$BAG_PID
            
            # Give some time for final processing
            sleep 3
            
            # Save trajectory
            if [ -f /tmp/vio.csv ]; then
                cp /tmp/vio.csv /output/trajectory.csv
                echo 'Trajectory saved'
            fi
            
            # Kill VINS
            kill \$VINS_PID 2>/dev/null || true
            sleep 2
            
            echo 'Test completed: $TEST_NAME'
        " || echo "Test failed: $TEST_NAME"
    
    echo "Results saved to: $OUTPUT_DIR"
}

# Check if dataset exists
if [ ! -d "$DATASET" ]; then
    echo "Error: Dataset not found at $DATASET"
    exit 1
fi

# Check for rosbag files
BAG_FILES=$(find "$DATASET" -name "*.bag" 2>/dev/null | head -1)
if [ -z "$BAG_FILES" ]; then
    echo "Warning: No rosbag files found in dataset"
    echo "Looking for rosbag in parent directory..."
    BAG_FILES=$(find "/storage/VINS-Fusion-Understood/dataset" -name "*.bag" 2>/dev/null | head -1)
    if [ -z "$BAG_FILES" ]; then
        echo "Error: No rosbag files found"
        exit 1
    fi
fi

echo "Found rosbag: $BAG_FILES"

# Run tests
echo ""
echo "Starting comparison tests..."

# Test 1: Original VINS-Fusion (traditional features)
run_test "euroc_stereo_imu_config.yaml" "original"

# Test 2: SuperPoint + Optical Flow
run_test "euroc_stereo_imu_config_deep.yaml" "superpoint_flow"

# Test 3: SuperPoint + LightGlue (if supported)
# run_test "euroc_stereo_imu_config_deep.yaml" "superpoint_lightglue"

echo ""
echo "========================================="
echo "All tests completed!"
echo "Results: $RESULTS_DIR"
echo "========================================="

# List results
ls -la "$RESULTS_DIR"
