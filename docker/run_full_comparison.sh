#!/bin/bash
# Full comparison test between original and TensorRT-enhanced VINS-Fusion
# Runs both versions with visualization and saves results

set -e

# Configuration
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
CONFIG_ORIGINAL="/storage/VINS-Fusion-Understood/config/euroc/euroc_stereo_imu_config.yaml"
CONFIG_DEEP="/storage/VINS-Fusion-Understood/config/euroc/euroc_stereo_imu_config_deep.yaml"
RESULTS_BASE="/tmp/vins_comparison_$(date +%Y%m%d_%H%M%S)"

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    if [ ! -d "$DATASET_DIR" ]; then
        echo "Error: Dataset not found at $DATASET_DIR"
        exit 1
    fi
    
    if [ ! -f "$CONFIG_ORIGINAL" ]; then
        echo "Error: Original config not found at $CONFIG_ORIGINAL"
        exit 1
    fi
    
    if [ ! -f "$CONFIG_DEEP" ]; then
        echo "Error: Deep config not found at $CONFIG_DEEP"
        exit 1
    fi
    
    # Check Docker images
    if ! docker images | grep -q "ros-vins-fusion-rviz"; then
        echo "Error: Original VINS image not found"
        exit 1
    fi
    
    if ! docker images | grep -q "vins-fusion-tensorrt"; then
        echo "Error: TensorRT VINS image not found"
        exit 1
    fi
    
    echo "✓ All prerequisites met"
}

# Run a single test
run_test() {
    local IMAGE=$1
    local CONFIG=$2
    local OUTPUT_DIR=$3
    local TEST_NAME=$4
    local DURATION=${5:-60}  # Default 60 seconds
    
    echo ""
    echo "========================================="
    echo "Running: $TEST_NAME"
    echo "Image: $IMAGE"
    echo "Config: $CONFIG"
    echo "Output: $OUTPUT_DIR"
    echo "Duration: ${DURATION}s"
    echo "========================================="
    
    mkdir -p "$OUTPUT_DIR"
    
    # Create launch script
    cat > /tmp/launch_${TEST_NAME}.sh << EOF
#!/bin/bash
source /opt/ros/kinetic/setup.bash
source /root/catkin_ws/devel/setup.bash

# Start VINS-Fusion in background
roslaunch vins vins_rviz.launch config:=/config/$(basename $CONFIG) &
VINS_PID=\$!

# Wait for VINS to initialize
sleep 5

# Play dataset
rosbag play /dataset/*.bag --clock &
BAG_PID=\$!

# Run for specified duration
sleep $DURATION

# Stop processes
kill \$BAG_PID 2>/dev/null || true
kill \$VINS_PID 2>/dev/null || true

echo "Test completed"
EOF
    chmod +x /tmp/launch_${TEST_NAME}.sh
    
    # Run container
    docker run -d --rm \
        --gpus all \
        --net=host \
        -e DISPLAY=$DISPLAY \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "$DATASET_DIR:/dataset" \
        -v "$OUTPUT_DIR:/root/output" \
        -v "$(dirname $CONFIG):/config" \
        -v "/tmp/launch_${TEST_NAME}.sh:/launch.sh" \
        --name "vins_${TEST_NAME}" \
        $IMAGE \
        /bin/bash /launch.sh
    
    echo "Container started: vins_${TEST_NAME}"
    echo "Running for ${DURATION} seconds..."
    
    # Wait for test to complete
    sleep $DURATION
    sleep 5  # Extra time for cleanup
    
    # Check if container is still running and stop it
    if docker ps | grep -q "vins_${TEST_NAME}"; then
        echo "Stopping container..."
        docker stop "vins_${TEST_NAME}" || true
    fi
    
    echo "✓ Test completed: $TEST_NAME"
}

# Generate comparison report
generate_report() {
    local ORIGINAL_DIR=$1
    local TENSORRT_DIR=$2
    local REPORT_FILE=$3
    
    echo ""
    echo "Generating comparison report..."
    
    cat > "$REPORT_FILE" << EOF
# VINS-Fusion Performance Comparison Report

Generated: $(date)
Dataset: $DATASET_DIR

## Test Configuration

- Original Version: ros-vins-fusion-rviz:latest
- TensorRT Version: vins-fusion-tensorrt:latest
- Test Duration: 60 seconds per test

## Results

### Original VINS-Fusion
- Output Directory: $ORIGINAL_DIR
- Files Generated:
EOF
    
    ls -la "$ORIGINAL_DIR" >> "$REPORT_FILE" 2>/dev/null || echo "  (No files generated)" >> "$REPORT_FILE"
    
    cat >> "$REPORT_FILE" << EOF

### TensorRT-Enhanced VINS-Fusion
- Output Directory: $TENSORRT_DIR
- Files Generated:
EOF
    
    ls -la "$TENSORRT_DIR" >> "$REPORT_FILE" 2>/dev/null || echo "  (No files generated)" >> "$REPORT_FILE"
    
    cat >> "$REPORT_FILE" << EOF

## Analysis

To analyze the trajectory results, compare the generated files in both directories.
Typical output files include:
- vio.csv: Visual-inertial odometry trajectory
- pose_graph.csv: Pose graph optimization results
- loop_result.csv: Loop closure results

## Notes

- The TensorRT version includes SuperPoint feature extraction and LightGlue matching
- Performance comparison should focus on:
  1. Tracking accuracy (RMSE against ground truth)
  2. Processing speed (FPS)
  3. Feature tracking robustness
  4. Loop closure detection rate

EOF
    
    echo "✓ Report generated: $REPORT_FILE"
}

# Main execution
main() {
    echo "========================================="
    echo "VINS-Fusion Full Comparison Test"
    echo "========================================="
    echo "Dataset: $DATASET_DIR"
    echo "Results: $RESULTS_BASE"
    echo "========================================="
    
    # Check prerequisites
    check_prerequisites
    
    # Create results directory
    mkdir -p "$RESULTS_BASE"
    
    # Run original version
    echo ""
    echo "Step 1/3: Running original VINS-Fusion..."
    run_test "ros-vins-fusion-rviz:latest" "$CONFIG_ORIGINAL" "$RESULTS_BASE/original" "original" 60
    
    # Wait between tests
    echo ""
    echo "Waiting 10 seconds between tests..."
    sleep 10
    
    # Run TensorRT version
    echo ""
    echo "Step 2/3: Running TensorRT-enhanced VINS-Fusion..."
    run_test "vins-fusion-tensorrt:latest" "$CONFIG_DEEP" "$RESULTS_BASE/tensorrt" "tensorrt" 60
    
    # Generate report
    echo ""
    echo "Step 3/3: Generating comparison report..."
    generate_report "$RESULTS_BASE/original" "$RESULTS_BASE/tensorrt" "$RESULTS_BASE/report.md"
    
    # Summary
    echo ""
    echo "========================================="
    echo "Comparison Test Complete!"
    echo "========================================="
    echo "Results saved to: $RESULTS_BASE"
    echo ""
    echo "Directory structure:"
    echo "  $RESULTS_BASE/original/   - Original VINS-Fusion results"
    echo "  $RESULTS_BASE/tensorrt/   - TensorRT VINS-Fusion results"
    echo "  $RESULTS_BASE/report.md   - Comparison report"
    echo ""
    echo "To view results:"
    echo "  cat $RESULTS_BASE/report.md"
    echo "  ls -la $RESULTS_BASE/original/"
    echo "  ls -la $RESULTS_BASE/tensorrt/"
}

# Run main function
main "$@"
