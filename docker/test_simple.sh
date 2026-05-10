#!/bin/bash
# Simple test to verify VINS-Fusion with TensorRT builds and runs correctly

set -e

echo "========================================="
echo "Testing VINS-Fusion with TensorRT"
echo "========================================="

# Test 1: Check if Docker image exists
echo ""
echo "Test 1: Checking Docker image..."
if docker images | grep -q "vins-fusion-tensorrt"; then
    echo "✓ Docker image found"
else
    echo "✗ Docker image not found"
    exit 1
fi

# Test 2: Test container can start
echo ""
echo "Test 2: Testing container startup..."
docker run --rm vins-fusion-tensorrt:latest /bin/bash -c "echo 'Container started successfully'"
echo "✓ Container starts successfully"

# Test 3: Check ROS environment
echo ""
echo "Test 3: Checking ROS environment..."
docker run --rm vins-fusion-tensorrt:latest /bin/bash -c "
    source /opt/ros/kinetic/setup.bash && \
    source /root/catkin_ws/devel/setup.bash && \
    rospack find vins > /dev/null && \
    echo 'VINS package found'
"
echo "✓ ROS environment OK"

# Test 4: Check if binaries exist
echo ""
echo "Test 4: Checking VINS binaries..."
docker run --rm vins-fusion-tensorrt:latest /bin/bash -c "
    ls -la /root/catkin_ws/devel/lib/vins/vins_node && \
    ls -la /root/catkin_ws/devel/lib/vins/kitti_odom_test
"
echo "✓ Binaries exist"

# Test 5: Check configuration files
echo ""
echo "Test 5: Checking configuration files..."
docker run --rm vins-fusion-tensorrt:latest /bin/bash -c "
    ls -la /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml && \
    ls -la /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml
"
echo "✓ Configuration files exist"

# Test 6: Check model files
echo ""
echo "Test 6: Checking model files..."
docker run --rm vins-fusion-tensorrt:latest /bin/bash -c "
    ls -la /tmp/models/superpoint_lightglue_fused.onnx
"
echo "✓ Model files exist"

echo ""
echo "========================================="
echo "All tests passed!"
echo "========================================="
echo ""
echo "To run VINS-Fusion with dataset:"
echo "  ./docker/run_tensorrt.sh --config config/euroc/euroc_stereo_imu_config_deep.yaml --dataset /path/to/dataset"
