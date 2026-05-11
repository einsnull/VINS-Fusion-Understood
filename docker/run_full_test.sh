#!/bin/bash
# Run complete VINS-Fusion comparison test with visualization and ground truth

set -e

DATASET="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
GROUND_TRUTH="$DATASET/mav0/state_groundtruth_estimate0/data.csv"
RESULTS_DIR="/tmp/vins_full_test_$(date +%Y%m%d_%H%M%S)"
DURATION=60

mkdir -p "$RESULTS_DIR"

echo "========================================="
echo "VINS-Fusion Full Comparison Test"
echo "========================================="
echo "Results: $RESULTS_DIR"
echo ""

# Ensure X11 access
xhost +local:docker 2>/dev/null || true

# Function to run single test
run_version() {
    local IMAGE=$1
    local CONFIG=$2
    local NAME=$3
    local OUTPUT="$RESULTS_DIR/$NAME"
    
    mkdir -p "$OUTPUT"
    
    echo ""
    echo "========================================="
    echo "Running: $NAME"
    echo "========================================="
    
    # Run container with everything
    docker run -i --rm \
        --name "vins_test_$NAME" \
        --net=host \
        --gpus all \
        -e DISPLAY=$DISPLAY \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
        -v "$(pwd)/..:/root/catkin_ws/src/VINS-Fusion" \
        -v "$DATASET:/dataset:ro" \
        -v "$OUTPUT:/root/output" \
        $IMAGE \
        /bin/bash -c "
            source /opt/ros/noetic/setup.bash
            source /root/catkin_ws/devel/setup.bash
            
            # Start roscore
            roscore &
            sleep 3
            
            # Start RViz
            rosrun rviz rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz &
            RVIZ_PID=\$!
            
            # Start VINS
            rosrun vins vins_node $CONFIG &
            VINS_PID=\$!
            
            # Wait for initialization
            sleep 8
            
            # Record odometry
            rosbag record -O /root/output/trajectory.bag /vins_estimator/odometry &
            RECORD_PID=\$!
            
            # Play dataset
            rosbag play /dataset/*.bag --clock &
            BAG_PID=\$!
            
            # Run for duration
            sleep $DURATION
            
            # Stop
            kill \$RECORD_PID 2>/dev/null || true
            sleep 2
            kill \$BAG_PID 2>/dev/null || true
            sleep 2
            kill \$VINS_PID 2>/dev/null || true
            kill \$RVIZ_PID 2>/dev/null || true
            
            echo 'Done'
        " || true
    
    # Extract trajectory from bag
    if [ -f "$OUTPUT/trajectory.bag" ]; then
        echo "Extracting trajectory..."
        docker run --rm \
            -v "$OUTPUT:/output" \
            vins-fusion-tensorrt:latest \
            /bin/bash -c "
                source /opt/ros/noetic/setup.bash
                rostopic echo -b /output/trajectory.bag -p /vins_estimator/odometry > /output/trajectory.csv 2>/dev/null || true
            " 2>/dev/null || true
    fi
    
    echo "✓ $NAME completed"
}

# Test 1: Original
echo "Test 1/3: Original VINS-Fusion"
run_version "vins-fusion-tensorrt:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml" \
    "01_original"

# Test 2: SuperPoint + Flow
echo "Test 2/3: SuperPoint + Optical Flow"
run_version "vins-fusion-tensorrt:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml" \
    "02_superpoint_flow"

# Test 3: SuperPoint + LightGlue
echo "Test 3/3: SuperPoint + LightGlue"
# Create config with mode 1
LIGHTGLUE_CONFIG="$RESULTS_DIR/lightglue_config.yaml"
cp "/storage/VINS-Fusion-Understood/config/euroc/euroc_stereo_imu_config_deep.yaml" "$LIGHTGLUE_CONFIG"
sed -i 's/deep_feature_mode: 0/deep_feature_mode: 1/' "$LIGHTGLUE_CONFIG"

run_version "vins-fusion-tensorrt:latest" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml" \
    "03_superpoint_lightglue"

# Generate report
echo ""
echo "========================================="
echo "Generating Report"
echo "========================================="

cat > "$RESULTS_DIR/report.txt" << EOF
VINS-Fusion Comparison Report
Generated: $(date)
Dataset: $DATASET
Duration: ${DURATION}s per test

Results:
EOF

for dir in "$RESULTS_DIR"/0*/; do
    name=$(basename "$dir")
    echo "" >> "$RESULTS_DIR/report.txt"
    echo "=== $name ===" >> "$RESULTS_DIR/report.txt"
    ls -la "$dir" >> "$RESULTS_DIR/report.txt" 2>/dev/null || true
done

echo ""
echo "========================================="
echo "Test Complete!"
echo "========================================="
echo "Results: $RESULTS_DIR"
echo ""
echo "Files:"
ls -la "$RESULTS_DIR"
