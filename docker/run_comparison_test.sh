#!/bin/bash
# Compare original VINS-Fusion with TensorRT-enhanced version

set -e

DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
CONFIG_ORIGINAL="/storage/VINS-Fusion-Understood/config/euroc/euroc_stereo_imu_config.yaml"
CONFIG_DEEP="/storage/VINS-Fusion-Understood/config/euroc/euroc_stereo_imu_config_deep.yaml"

# Function to run VINS with specific image and config
run_vins() {
    local IMAGE=$1
    local CONFIG=$2
    local OUTPUT_DIR=$3
    local TEST_NAME=$4
    
    echo "========================================="
    echo "Running: $TEST_NAME"
    echo "Image: $IMAGE"
    echo "Config: $CONFIG"
    echo "Output: $OUTPUT_DIR"
    echo "========================================="
    
    mkdir -p "$OUTPUT_DIR"
    
    # Run container with dataset and config
    docker run -d --rm \
        --gpus all \
        --net=host \
        -e DISPLAY=$DISPLAY \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "$DATASET_DIR:/dataset" \
        -v "$OUTPUT_DIR:/root/output" \
        -v "$(dirname $CONFIG):/config" \
        --name "vins_test_${TEST_NAME}" \
        $IMAGE \
        /bin/bash -c "source /opt/ros/kinetic/setup.bash && \
                      source /root/catkin_ws/devel/setup.bash && \
                      roslaunch vins vins_rviz.launch config:=/config/$(basename $CONFIG) &
                      sleep 5 && \
                      rosbag play /dataset/*.bag --clock"
    
    # Wait for completion
    echo "Waiting for test to complete..."
    sleep 30
    
    # Stop container
    docker stop "vins_test_${TEST_NAME}" || true
    
    echo "Test completed. Results saved to: $OUTPUT_DIR"
}

# Create output directories
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="/tmp/vins_comparison_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"

echo "========================================="
echo "VINS-Fusion Performance Comparison"
echo "========================================="
echo "Dataset: $DATASET_DIR"
echo "Results: $RESULTS_DIR"
echo "========================================="

# Run original version
echo ""
echo "Starting Test 1: Original VINS-Fusion"
run_vins "ros-vins-fusion-rviz:latest" "$CONFIG_ORIGINAL" "$RESULTS_DIR/original" "original"

# Wait between tests
sleep 10

# Run TensorRT version
echo ""
echo "Starting Test 2: TensorRT-enhanced VINS-Fusion"
run_vins "vins-fusion-tensorrt:latest" "$CONFIG_DEEP" "$RESULTS_DIR/tensorrt" "tensorrt"

# Generate comparison report
echo ""
echo "========================================="
echo "Comparison Complete"
echo "========================================="
echo "Results saved to: $RESULTS_DIR"
echo ""
echo "To analyze results:"
echo "  ls -la $RESULTS_DIR/original/"
echo "  ls -la $RESULTS_DIR/tensorrt/"
