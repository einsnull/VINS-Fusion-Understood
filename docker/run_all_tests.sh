#!/bin/bash
# Run all VINS-Fusion tests:
# 1. Original VINS-Fusion
# 2. SuperPoint + Optical Flow
# 3. SuperPoint + LightGlue

set -e

# Configuration
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
HOST_RESULTS="/tmp/vins_full_comparison_$(date +%Y%m%d_%H%M%S)"
DURATION=${1:-60}  # Test duration in seconds, default 60

# Function to run test inside container
run_test() {
    local IMAGE=$1
    local CONFIG=$2
    local OUTPUT_DIR=$3
    local TEST_NAME=$4
    local DURATION=$5
    
    echo "========================================="
    echo "Running: $TEST_NAME"
    echo "Image: $IMAGE"
    echo "Config: $CONFIG"
    echo "Duration: ${DURATION}s"
    echo "========================================="
    
    mkdir -p "$OUTPUT_DIR"
    
    docker run --rm \
        --gpus all \
        --net=host \
        -e DISPLAY=$DISPLAY \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "$DATASET_DIR:/dataset:ro" \
        -v "$OUTPUT_DIR:/root/output" \
        --name "vins_${TEST_NAME//[^a-zA-Z0-9]/_}" \
        $IMAGE \
        /bin/bash -c "
            source /opt/ros/kinetic/setup.bash
            source /root/catkin_ws/devel/setup.bash
            
            mkdir -p /root/output
            
            # Start VINS-Fusion with visualization
            roslaunch vins vins_rviz.launch config:=$CONFIG &
            VINS_PID=\$!
            
            sleep 5
            
            # Play dataset
            rosbag play /dataset/*.bag --clock &
            BAG_PID=\$!
            
            sleep $DURATION
            
            # Stop processes
            kill \$BAG_PID 2>/dev/null || true
            kill \$VINS_PID 2>/dev/null || true
            sleep 3
            
            echo 'Test completed'
            ls -la /root/output/
        "
    
    echo "✓ Completed: $TEST_NAME"
}

# Main execution
main() {
    echo "========================================="
    echo "VINS-Fusion Complete Test Suite"
    echo "========================================="
    echo "Dataset: $DATASET_DIR"
    echo "Duration per test: ${DURATION}s"
    echo "Results: $HOST_RESULTS"
    echo "========================================="
    
    if [ ! -d "$DATASET_DIR" ]; then
        echo "Error: Dataset not found at $DATASET_DIR"
        exit 1
    fi
    
    mkdir -p "$HOST_RESULTS"
    
    # Test 1: Original VINS-Fusion
    echo ""
    echo "Test 1/3: Original VINS-Fusion"
    echo "----------------------------------------"
    run_test \
        "ros-vins-fusion-rviz:latest" \
        "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml" \
        "$HOST_RESULTS/01_original" \
        "Original VINS-Fusion" \
        $DURATION
    
    sleep 5
    
    # Test 2: SuperPoint + Optical Flow
    echo ""
    echo "Test 2/3: SuperPoint + Optical Flow"
    echo "----------------------------------------"
    run_test \
        "vins-fusion-tensorrt:latest" \
        "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml" \
        "$HOST_RESULTS/02_superpoint_flow" \
        "SuperPoint + Optical Flow" \
        $DURATION
    
    sleep 5
    
    # Test 3: SuperPoint + LightGlue
    echo ""
    echo "Test 3/3: SuperPoint + LightGlue"
    echo "----------------------------------------"
    # Create a config file for LightGlue mode
    docker run --rm \
        -v "$HOST_RESULTS:/root/output" \
        vins-fusion-tensorrt:latest \
        /bin/bash -c "
            cp /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml /tmp/lightglue_config.yaml
            sed -i 's/deep_feature_mode: 0/deep_feature_mode: 1/' /tmp/lightglue_config.yaml
            cat /tmp/lightglue_config.yaml
        "
    
    run_test \
        "vins-fusion-tensorrt:latest" \
        "/tmp/lightglue_config.yaml" \
        "$HOST_RESULTS/03_superpoint_lightglue" \
        "SuperPoint + LightGlue" \
        $DURATION
    
    # Generate report
    echo ""
    echo "========================================="
    echo "Generating report..."
    echo "========================================="
    
    cat > "$HOST_RESULTS/report.md" << EOF
# VINS-Fusion Complete Comparison Report

Generated: $(date)
Dataset: $DATASET_DIR
Duration per test: ${DURATION}s

## Test Results

### 1. Original VINS-Fusion
- Directory: $HOST_RESULTS/01_original/
- Files:
EOF
    ls -la "$HOST_RESULTS/01_original/" >> "$HOST_RESULTS/report.md" 2>/dev/null || echo "No files" >> "$HOST_RESULTS/report.md"
    
    cat >> "$HOST_RESULTS/report.md" << EOF

### 2. SuperPoint + Optical Flow
- Directory: $HOST_RESULTS/02_superpoint_flow/
- Files:
EOF
    ls -la "$HOST_RESULTS/02_superpoint_flow/" >> "$HOST_RESULTS/report.md" 2>/dev/null || echo "No files" >> "$HOST_RESULTS/report.md"
    
    cat >> "$HOST_RESULTS/report.md" << EOF

### 3. SuperPoint + LightGlue
- Directory: $HOST_RESULTS/03_superpoint_lightglue/
- Files:
EOF
    ls -la "$HOST_RESULTS/03_superpoint_lightglue/" >> "$HOST_RESULTS/report.md" 2>/dev/null || echo "No files" >> "$HOST_RESULTS/report.md"
    
    cat >> "$HOST_RESULTS/report.md" << EOF

## Analysis

Compare the three versions:
1. **Original**: Traditional feature detection (goodFeaturesToTrack) + LK optical flow
2. **SuperPoint + Flow**: Deep learning features + LK optical flow
3. **SuperPoint + LightGlue**: Deep learning features + neural network matching

Key metrics to compare:
- Tracking accuracy (trajectory RMSE)
- Number of tracked features
- Processing speed (FPS)
- Robustness to challenging scenes

EOF
    
    echo ""
    echo "========================================="
    echo "All Tests Complete!"
    echo "========================================="
    echo "Results: $HOST_RESULTS"
    echo ""
    echo "Structure:"
    echo "  01_original/           - Original VINS-Fusion"
    echo "  02_superpoint_flow/    - SuperPoint + Optical Flow"
    echo "  03_superpoint_lightglue/ - SuperPoint + LightGlue"
    echo "  report.md              - Comparison report"
}

# Handle Ctrl+C
trap 'echo ""; echo "Test interrupted"; exit 1' INT

# Run
main "$@"
