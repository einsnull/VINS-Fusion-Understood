#!/bin/bash
# VINS-Fusion Comparison Test: Original vs SuperPoint+Optical Flow
set -e
set +H

IMAGE="vins-fusion-superpoint:latest"
DATASET_DIR="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="/tmp/vins_comparison_$(date +%Y%m%d_%H%M%S)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONTAINER_ORIG="vins_orig_${TIMESTAMP}"
CONTAINER_SP="vins_sp_${TIMESTAMP}"

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

DOCKER_OPTS="--net=host --gpus all -e DISPLAY=$DISPLAY -e QT_X11_NO_MITSHM=1 -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all -v /tmp/.X11-unix:/tmp/.X11-unix -v $DATASET_DIR:/dataset:ro"

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}VINS-Fusion Comparison Test${NC}"
echo -e "${GREEN}  Original vs SuperPoint+Optical Flow${NC}"
echo -e "${GREEN}=========================================${NC}"
echo "Results: $RESULTS_DIR"
echo ""

run_test_in_container() {
    local CONTAINER_NAME="$1"
    local CONFIG_FILE="$2"
    local OUTPUT_DIR="$3"
    local TEST_NAME="$4"

    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}  TEST: ${TEST_NAME}${NC}"
    echo -e "${BLUE}=========================================${NC}"

    echo -e "${BLUE}[1] Starting container...${NC}"
    docker run -d --rm --name "$CONTAINER_NAME" $DOCKER_OPTS -v "${OUTPUT_DIR}:/root/output" "$IMAGE" /bin/bash -c "while true; do sleep 3600; done"
    echo -e "${GREEN}Container started: $CONTAINER_NAME${NC}"

    echo -e "${BLUE}[2] Starting roscore...${NC}"
    docker exec -d "$CONTAINER_NAME" bash -c 'source /opt/ros/noetic/setup.bash && roscore > /tmp/roscore.log 2>&1'
    sleep 3

    echo -e "${BLUE}[3] Starting VINS node...${NC}"
    docker exec -d "$CONTAINER_NAME" bash -c "source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && mkdir -p /root/output && rosrun vins vins_node ${CONFIG_FILE} 1 > /tmp/vins.log 2>&1"
    sleep 8

    echo -e "${BLUE}[4] Starting RViz...${NC}"
    docker exec -d "$CONTAINER_NAME" bash -c 'source /opt/ros/noetic/setup.bash && sleep 3 && rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz > /tmp/rviz.log 2>&1'
    sleep 5

    echo -e "${BLUE}[5] Playing rosbag...${NC}"
    echo -e "${YELLOW}Pangolin + RViz should be visible now${NC}"

    docker exec "$CONTAINER_NAME" bash -c '
        source /opt/ros/noetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        rosbag record -O /root/output/trajectory.bag /vins_estimator/odometry /feature_tracker/feature &
        RECORD_PID=$!
        sleep 2
        rosbag play /dataset/MH_01_easy.bag --clock -r 1
        sleep 5
        kill $RECORD_PID 2>/dev/null || true
        sleep 2
    '

    echo -e "${GREEN}${TEST_NAME} completed! Output: ${OUTPUT_DIR}${NC}"
    ls -la "$OUTPUT_DIR" 2>/dev/null || true

    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sleep 3
}

# Test 1: Original VINS-Fusion
run_test_in_container "$CONTAINER_ORIG" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml" \
    "$RESULTS_DIR/original" \
    "Original VINS-Fusion (Shi-Tomasi + LK Flow)"

# Test 2: SuperPoint + Optical Flow
run_test_in_container "$CONTAINER_SP" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config_deep.yaml" \
    "$RESULTS_DIR/superpoint" \
    "SuperPoint + Optical Flow (TensorRT)"

# Summary
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
ls -la "$RESULTS_DIR/original/" 2>/dev/null || echo "  (empty)"
echo ""
ls -la "$RESULTS_DIR/superpoint/" 2>/dev/null || echo "  (empty)"
echo ""

if [ -f "$RESULTS_DIR/original/vio.csv" ] && [ -f "$RESULTS_DIR/superpoint/vio.csv" ]; then
    echo -e "${BLUE}VIO CSV comparison:${NC}"
    echo "  Original lines:   $(wc -l < "$RESULTS_DIR/original/vio.csv")"
    echo "  SuperPoint lines: $(wc -l < "$RESULTS_DIR/superpoint/vio.csv")"
fi

echo ""
echo -e "${GREEN}Done!${NC}"