#!/bin/bash
# Run VINS-Fusion with visualization - interactive mode

set -e

IMAGE=$1
CONFIG=$2
TEST_NAME=$3

if [ -z "$IMAGE" ] || [ -z "$CONFIG" ] || [ -z "$TEST_NAME" ]; then
    echo "Usage: $0 <image> <config> <test_name>"
    echo "Example:"
    echo "  $0 ros-vins-fusion-rviz:latest /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml original"
    exit 1
fi

echo "========================================="
echo "Running: $TEST_NAME"
echo "Image: $IMAGE"
echo "Config: $CONFIG"
echo "========================================="

# Ensure X11 access
xhost +local:docker 2>/dev/null || true

echo ""
echo "Starting VINS-Fusion with RViz..."
echo "This will open RViz window for visualization"
echo "Press Ctrl+C to stop"
echo ""

# Run container interactively
docker run -it --rm \
    --gpus all \
    --net=host \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy:/dataset:ro" \
    --name "vins_${TEST_NAME}" \
    $IMAGE \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        echo 'Starting roscore...'
        roscore &
        sleep 3
        
        echo 'Starting VINS-Fusion and RViz...'
        roslaunch vins vins_rviz.launch config:=$CONFIG &
        VINS_PID=\$!
        
        echo 'Waiting for VINS to initialize...'
        sleep 10
        
        echo 'Playing dataset...'
        rosbag play /dataset/*.bag --clock &
        BAG_PID=\$!
        
        echo ''
        echo 'VINS-Fusion is running with visualization'
        echo 'RViz should be visible now'
        echo ''
        
        # Wait for user interrupt
        wait \$BAG_PID
        
        echo 'Dataset playback completed'
        echo 'Press Enter to exit or wait 10 seconds...'
        read -t 10 || true
        
        # Cleanup
        kill \$VINS_PID 2>/dev/null || true
    "

echo ""
echo "✓ Test completed: $TEST_NAME"
