#!/bin/bash
# Run VINS-Fusion test with proper visualization

set -e

IMAGE=$1
CONFIG=$2
OUTPUT_DIR=$3
TEST_NAME=$4
DURATION=${5:-60}

if [ -z "$IMAGE" ] || [ -z "$CONFIG" ] || [ -z "$OUTPUT_DIR" ] || [ -z "$TEST_NAME" ]; then
    echo "Usage: $0 <image> <config> <output_dir> <test_name> [duration]"
    exit 1
fi

echo "========================================="
echo "Running: $TEST_NAME"
echo "Image: $IMAGE"
echo "Config: $CONFIG"
echo "Duration: ${DURATION}s"
echo "========================================="

mkdir -p "$OUTPUT_DIR"

# Run container with VINS and RViz
docker run -d --rm \
    --gpus all \
    --net=host \
    -e DISPLAY=$DISPLAY \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy:/dataset:ro" \
    -v "$OUTPUT_DIR:/root/output" \
    --name "vins_test" \
    $IMAGE \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        # Start roscore
        roscore &
        sleep 3
        
        # Start VINS-Fusion with RViz
        roslaunch vins vins_rviz.launch config:=$CONFIG &
        VINS_PID=\$!
        
        # Wait for VINS to initialize
        sleep 8
        
        # Play dataset
        rosbag play /dataset/*.bag --clock &
        BAG_PID=\$!
        
        # Run for specified duration
        sleep $DURATION
        
        # Stop bag first
        kill \$BAG_PID 2>/dev/null || true
        sleep 2
        
        # Stop VINS
        kill \$VINS_PID 2>/dev/null || true
        sleep 2
        
        # Copy any output files
        cp -r /root/output/* /root/output/ 2>/dev/null || true
        
        echo 'Test completed'
    "

echo "Container started, running for ${DURATION} seconds..."
sleep $DURATION
sleep 10  # Extra time for cleanup

# Check if still running and stop
if docker ps | grep -q "vins_test"; then
    echo "Stopping container..."
    docker stop "vins_test" || true
fi

echo "✓ Test completed: $TEST_NAME"
echo "Results in: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR" || true
