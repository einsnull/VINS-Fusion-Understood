#!/bin/bash
# Run VINS-Fusion comparison test inside Docker containers
# This script launches containers and runs the full test pipeline

set -e

# Configuration
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
CONFIG_ORIGINAL="/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml"
CONFIG_DEEP="/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml"
RESULTS_BASE="/root/output/comparison_$(date +%Y%m%d_%H%M%S)"

# Function to run test inside container
run_test_in_container() {
    local IMAGE=$1
    local CONFIG=$2
    local OUTPUT_DIR=$3
    local TEST_NAME=$4
    local DURATION=${5:-60}
    
    echo "========================================="
    echo "Running: $TEST_NAME"
    echo "Image: $IMAGE"
    echo "Config: $CONFIG"
    echo "Output: $OUTPUT_DIR"
    echo "Duration: ${DURATION}s"
    echo "========================================="
    
    # Create output directory on host
    mkdir -p "$OUTPUT_DIR"
    
    # Run test inside container
    docker run --rm \
        --gpus all \
        --net=host \
        -e DISPLAY=$DISPLAY \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "$DATASET_DIR:/dataset:ro" \
        -v "$OUTPUT_DIR:/root/output" \
        --name "vins_${TEST_NAME}" \
        $IMAGE \
        /bin/bash -c "
            source /opt/ros/kinetic/setup.bash
            source /root/catkin_ws/devel/setup.bash
            
            # Create output directory
            mkdir -p /root/output
            
            # Start VINS-Fusion
            roslaunch vins vins_rviz.launch config:=$CONFIG &
            VINS_PID=\$!
            
            # Wait for initialization
            sleep 5
            
            # Play dataset
            rosbag play /dataset/*.bag --clock &
            BAG_PID=\$!
            
            # Run for specified duration
            sleep $DURATION
            
            # Stop processes
            kill \$BAG_PID 2>/dev/null || true
            kill \$VINS_PID 2>/dev/null || true
            
            # Wait for cleanup
            sleep 3
            
            echo 'Test completed'
            ls -la /root/output/
        "
    
    echo "✓ Test completed: $TEST_NAME"
}

# Main execution
main() {
    echo "========================================="
    echo "VINS-Fusion Docker Comparison Test"
    echo "========================================="
    echo "Dataset: $DATASET_DIR"
    echo "Results will be saved to host directory"
    echo "========================================="
    
    # Check if dataset exists
    if [ ! -d "$DATASET_DIR" ]; then
        echo "Error: Dataset not found at $DATASET_DIR"
        exit 1
    fi
    
    # Create results directory on host
    HOST_RESULTS="/tmp/vins_comparison_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$HOST_RESULTS"
    
    echo ""
    echo "Step 1/2: Running original VINS-Fusion..."
    echo "This will open RViz for visualization"
    echo "Press Ctrl+C to stop early"
    echo ""
    
    run_test_in_container \
        "ros-vins-fusion-rviz:latest" \
        "$CONFIG_ORIGINAL" \
        "$HOST_RESULTS/original" \
        "original" \
        60
    
    echo ""
    echo "Waiting 10 seconds before next test..."
    sleep 10
    
    echo ""
    echo "Step 2/2: Running TensorRT-enhanced VINS-Fusion..."
    echo "This will open RViz for visualization"
    echo "Press Ctrl+C to stop early"
    echo ""
    
    run_test_in_container \
        "vins-fusion-tensorrt:latest" \
        "$CONFIG_DEEP" \
        "$HOST_RESULTS/tensorrt" \
        "tensorrt" \
        60
    
    # Generate report
    echo ""
    echo "========================================="
    echo "Generating comparison report..."
    echo "========================================="
    
    cat > "$HOST_RESULTS/report.md" << EOF
# VINS-Fusion Performance Comparison Report

Generated: $(date)
Dataset: $DATASET_DIR

## Test Configuration

- Original Version: ros-vins-fusion-rviz:latest
- TensorRT Version: vins-fusion-tensorrt:latest
- Test Duration: 60 seconds per test

## Results Location

- Original results: $HOST_RESULTS/original/
- TensorRT results: $HOST_RESULTS/tensorrt/

## Files Generated

### Original VINS-Fusion
EOF
    
    ls -la "$HOST_RESULTS/original/" >> "$HOST_RESULTS/report.md" 2>/dev/null || echo "No files generated" >> "$HOST_RESULTS/report.md"
    
    cat >> "$HOST_RESULTS/report.md" << EOF

### TensorRT-Enhanced VINS-Fusion
EOF
    
    ls -la "$HOST_RESULTS/tensorrt/" >> "$HOST_RESULTS/report.md" 2>/dev/null || echo "No files generated" >> "$HOST_RESULTS/report.md"
    
    cat >> "$HOST_RESULTS/report.md" << EOF

## Next Steps

To analyze the results:
1. Compare trajectory files (vio.csv, pose_graph.csv)
2. Check feature tracking statistics
3. Evaluate loop closure performance
4. Compare processing speed and accuracy

EOF
    
    echo ""
    echo "========================================="
    echo "Comparison Test Complete!"
    echo "========================================="
    echo "Results saved to: $HOST_RESULTS"
    echo ""
    echo "Directory structure:"
    echo "  $HOST_RESULTS/original/   - Original VINS-Fusion results"
    echo "  $HOST_RESULTS/tensorrt/   - TensorRT VINS-Fusion results"
    echo "  $HOST_RESULTS/report.md   - Comparison report"
    echo ""
    echo "To view results:"
    echo "  cat $HOST_RESULTS/report.md"
    echo "  ls -la $HOST_RESULTS/original/"
    echo "  ls -la $HOST_RESULTS/tensorrt/"
}

# Handle Ctrl+C
trap 'echo ""; echo "Test interrupted by user"; exit 1' INT

# Run main function
main "$@"
