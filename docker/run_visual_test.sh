#!/bin/bash
# VINS-Fusion 可视化测试 - 单容器方案
# Pangolin + RViz 都在同一个容器中，共享 ROS master
set -e

IMAGE="vins-fusion-superpoint:latest"
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="/tmp/vins_visual_$(date +%Y%m%d_%H%M%S)"
CONTAINER_NAME="vins_visual_$(date +%Y%m%d_%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$RESULTS_DIR"
xhost +local:docker 2>/dev/null || true

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}VINS-Fusion Visual Test${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Container: $CONTAINER_NAME"
echo "Results: $RESULTS_DIR"
echo ""

# Step 1: Start persistent container
echo -e "${BLUE}[1/5] Starting persistent container...${NC}"
docker run -d --rm \
    --name "$CONTAINER_NAME" \
    --net=host \
    --gpus all \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$DATASET_DIR:/dataset:ro" \
    -v "$RESULTS_DIR:/root/output" \
    $IMAGE \
    /bin/bash -c "while true; do sleep 3600; done"

echo -e "${GREEN}Container started: $CONTAINER_NAME${NC}"

# Step 2: Start roscore
echo -e "${BLUE}[2/5] Starting roscore...${NC}"
docker exec -d "$CONTAINER_NAME" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    roscore > /tmp/roscore.log 2>&1
"
sleep 3
echo -e "${GREEN}roscore started${NC}"

# Step 3: Start VINS node (with Pangolin UI)
echo -e "${BLUE}[3/5] Starting VINS node (Pangolin UI)...${NC}"
docker exec -d "$CONTAINER_NAME" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    source /root/catkin_ws/devel/setup.bash
    mkdir -p /root/output
    rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config_deep.yaml 1 > /tmp/vins.log 2>&1
"
sleep 8
echo -e "${GREEN}VINS node started (Pangolin window should appear)${NC}"

# Step 4: Start RViz
echo -e "${BLUE}[4/5] Starting RViz...${NC}"
docker exec -d "$CONTAINER_NAME" /bin/bash -c "
    source /opt/ros/noetic/setup.bash
    sleep 3
    rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz > /tmp/rviz.log 2>&1
"
sleep 5
echo -e "${GREEN}RViz started${NC}"

# Step 5: Play rosbag
echo -e "${BLUE}[5/5] Playing rosbag...${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}Visualization is now running!${NC}"
echo -e "${YELLOW}  Pangolin: VINS feature tracks + pose${NC}"
echo -e "${YELLOW}  RViz: trajectory path + feature image${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""

docker exec "$CONTAINER_NAME" /bin/bash -c "
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

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}Test completed!${NC}"
echo -e "${GREEN}Results: $RESULTS_DIR${NC}"
echo -e "${GREEN}=========================================${NC}"
ls -la "$RESULTS_DIR" 2>/dev/null

echo ""
echo -e "${YELLOW}Container will be cleaned up automatically.${NC}"