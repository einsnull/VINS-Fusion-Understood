#!/bin/bash
# VINS-Fusion 对比测试脚本
# 对比原始版本 vs SuperPoint+光流版本
# 基于 run_visual_test.sh 的模式
set -e

IMAGE="vins-fusion-superpoint:latest"
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="/tmp/vins_comparison_$(date +%Y%m%d_%H%M%S)"
CONTAINER_ORIG="vins_orig_$(date +%Y%m%d_%H%M%S)"
CONTAINER_SP="vins_sp_$(date +%Y%m%d_%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker stop "$CONTAINER_ORIG" 2>/dev/null || true
    docker stop "$CONTAINER_SP" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$RESULTS_DIR/original" "$RESULTS_DIR/superpoint"
xhost +local:docker 2>/dev/null || true

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}VINS-Fusion Comparison Test${NC}"
echo -e "${GREEN}  Original vs SuperPoint+Optical Flow${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Original container: $CONTAINER_ORIG"
echo "SuperPoint container: $CONTAINER_SP"
echo "Results: $RESULTS_DIR"
echo ""

# ============================================================
# Test 1: Original VINS-Fusion
# ============================================================
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  TEST 1/2: Original VINS-Fusion${NC}"
echo -e "${BLUE}  Features: Shi-Tomasi + LK Optical Flow${NC}"
echo -e "${BLUE}=========================================${NC}"

echo -e "${BLUE}[1.1] Starting container...${NC}"
docker run -d --rm \
    --name "$CONTAINER_ORIG" \
    --net=host \
    --gpus all \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$DATASET_DIR:/dataset:ro" \
    -v "$RESULTS_DIR/original:/root/output" \
    $IMAGE \
    /bin/bash -c "while true; do sleep 3600; done"
echo -e "${GREEN}Container started${NC}"

echo -e "${BLUE}[1.2] Starting roscore...${NC}"
docker exec -d "$CONTAINER_ORIG" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    roscore > /tmp/roscore.log 2>&1
"
sleep 3

echo -e "${BLUE}[1.3] Starting VINS node (Original, Pangolin UI)...${NC}"
docker exec -d "$CONTAINER_ORIG" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    source /root/catkin_ws/devel/setup.bash
    mkdir -p /root/output
    rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml 1 > /tmp/vins_original.log 2>&1
"
sleep 8

echo -e "${BLUE}[1.4] Starting RViz...${NC}"
docker exec -d "$CONTAINER_ORIG" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    sleep 3
    rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz > /tmp/rviz.log 2>&1
"
sleep 5

echo -e "${BLUE}[1.5] Playing rosbag...${NC}"
echo -e "${YELLOW}Pangolin + RViz should be visible now${NC}"

docker exec "$CONTAINER_ORIG" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    source /root/catkin_ws/devel/setup.bash
    
    rosbag record -O /root/output/trajectory.bag /vins_estimator/odometry /feature_tracker/feature &
    RECORD_PID=\$!
    sleep 2
    
    rosbag play /dataset/MH_01_easy.bag --clock -r 1
    
    sleep 5
    kill \$RECORD_PID 2>/dev/null || true
    sleep 2
    echo 'BAG_PLAY_DONE'
"

echo -e "${GREEN}Original test completed!${NC}"
ls -la "$RESULTS_DIR/original" 2>/dev/null

# Stop container
docker stop "$CONTAINER_ORIG" 2>/dev/null || true
sleep 3

# ============================================================
# Test 2: SuperPoint + Optical Flow
# ============================================================
echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  TEST 2/2: SuperPoint + Optical Flow${NC}"
echo -e "${BLUE}  Features: SuperPoint (TensorRT) + LK Optical Flow${NC}"
echo -e "${BLUE}=========================================${NC}"

echo -e "${BLUE}[2.1] Starting container...${NC}"
docker run -d --rm \
    --name "$CONTAINER_SP" \
    --net=host \
    --gpus all \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$DATASET_DIR:/dataset:ro" \
    -v "$RESULTS_DIR/superpoint:/root/output" \
    $IMAGE \
    /bin/bash -c "while true; do sleep 3600; done"
echo -e "${GREEN}Container started${NC}"

echo -e "${BLUE}[2.2] Starting roscore...${NC}"
docker exec -d "$CONTAINER_SP" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    roscore > /tmp/roscore.log 2>&1
"
sleep 3

echo -e "${BLUE}[2.3] Starting VINS node (SuperPoint, Pangolin UI)...${NC}"
docker exec -d "$CONTAINER_SP" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    source /root/catkin_ws/devel/setup.bash
    mkdir -p /root/output
    rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config_deep.yaml 1 > /tmp/vins_superpoint.log 2>&1
"
sleep 8

echo -e "${BLUE}[2.4] Starting RViz...${NC}"
docker exec -d "$CONTAINER_SP" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    sleep 3
    rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz > /tmp/rviz.log 2>&1
"
sleep 5

echo -e "${BLUE}[2.5] Playing rosbag...${NC}"
echo -e "${YELLOW}Pangolin + RViz should be visible now${NC}"

docker exec "$CONTAINER_SP" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    source /root/catkin_ws/devel/setup.bash
    
    rosbag record -O /root/output/trajectory.bag /vins_estimator/odometry /feature_tracker/feature &
    RECORD_PID=\$!
    sleep 2
    
    rosbag play /dataset/MH_01_easy.bag --clock -r 1
    
    sleep 5
    kill \$RECORD_PID 2>/dev/null || true
    sleep 2
    echo 'BAG_PLAY_DONE'
"

echo -e "${GREEN}SuperPoint test completed!${NC}"
ls -la "$RESULTS_DIR/superpoint" 2>/dev/null

# Stop container
docker stop "$CONTAINER_SP" 2>/dev/null || true

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Comparison Test Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Results:"
echo "  Original:    $RESULTS_DIR/original/"
echo "  SuperPoint:  $RESULTS_DIR/superpoint/"
echo ""
echo "Files:"
ls -la "$RESULTS_DIR/original/" 2>/dev/null
echo ""
ls -la "$RESULTS_DIR/superpoint/" 2>/dev/null
echo ""

# Compare VIO CSV if available
if [ -f "$RESULTS_DIR/original/vio.csv" ] && [ -f "$RESULTS_DIR/superpoint/vio.csv" ]; then
    echo -e "${BLUE}VIO CSV comparison:${NC}"
    echo "  Original lines:   $(wc -l < "$RESULTS_DIR/original/vio.csv")"
    echo "  SuperPoint lines: $(wc -l < "$RESULTS_DIR/superpoint/vio.csv")"
fi

echo ""
echo -e "${GREEN}Done!${NC}"