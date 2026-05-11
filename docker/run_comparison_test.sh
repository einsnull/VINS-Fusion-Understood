#!/bin/bash
# VINS-Fusion Comparison Test: Original vs SuperPoint+Optical Flow vs SuperPoint+LightGlue
# Compiles code inside container, outputs results directly to host directory
set -e
set +H

IMAGE="vins-fusion-superpoint:latest"
PROJECT_DIR="/storage/VINS-Fusion-Understood"
DATASET_DIR="${PROJECT_DIR}/dataset/machine_hall/MH_01_easy"
HOST_OUTPUT_DIR="${PROJECT_DIR}/comparison_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="${HOST_OUTPUT_DIR}/${TIMESTAMP}"
CONTAINER_ORIG="vins_orig_${TIMESTAMP}"
CONTAINER_SP_FLOW="vins_spflow_${TIMESTAMP}"
CONTAINER_SP_LG="vins_splg_${TIMESTAMP}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
    echo -e "${YELLOW}Cleaning up containers...${NC}"
    docker stop "$CONTAINER_ORIG" 2>/dev/null || true
    docker stop "$CONTAINER_SP_FLOW" 2>/dev/null || true
    docker stop "$CONTAINER_SP_LG" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$RESULTS_DIR/original" "$RESULTS_DIR/superpoint_flow" "$RESULTS_DIR/superpoint_lightglue"
xhost +local:docker 2>/dev/null || true

DOCKER_OPTS="--net=host --gpus all -e DISPLAY=$DISPLAY -e QT_X11_NO_MITSHM=1 -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all -v /tmp/.X11-unix:/tmp/.X11-unix -v $DATASET_DIR:/dataset:ro -v ${PROJECT_DIR}:/root/catkin_ws/src/VINS-Fusion"

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}VINS-Fusion Comparison Test${NC}"
echo -e "${GREEN}  Original vs SuperPoint+Flow vs SuperPoint+LightGlue${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "Host output: ${RESULTS_DIR}"
echo ""

run_test_in_container() {
    local CONTAINER_NAME="$1"
    local CONFIG_FILE="$2"
    local HOST_OUTPUT_SUBDIR="$3"
    local TEST_NAME="$4"

    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}  TEST: ${TEST_NAME}${NC}"
    echo -e "${BLUE}=========================================${NC}"

    echo -e "${BLUE}[1] Starting container...${NC}"
    docker run -d --rm --name "$CONTAINER_NAME" $DOCKER_OPTS \
        -v "${HOST_OUTPUT_SUBDIR}:/root/output" \
        "$IMAGE" /bin/bash -c "while true; do sleep 3600; done"
    echo -e "${GREEN}Container started: $CONTAINER_NAME${NC}"

    echo -e "${BLUE}[2] Compiling VINS-Fusion...${NC}"
    docker exec "$CONTAINER_NAME" bash -c "
        source /opt/ros/noetic/setup.bash
        cd /root/catkin_ws
        catkin build --no-status -DCMAKE_BUILD_TYPE=Release -DUSE_TENSORRT=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    "
    echo -e "${GREEN}Compilation done${NC}"

    echo -e "${BLUE}[3] Starting roscore...${NC}"
    docker exec -d "$CONTAINER_NAME" bash -c 'source /opt/ros/noetic/setup.bash && roscore > /tmp/roscore.log 2>&1'
    sleep 3

    echo -e "${BLUE}[4] Starting VINS node...${NC}"
    docker exec -d "$CONTAINER_NAME" bash -c "source /opt/ros/noetic/setup.bash && source /root/catkin_ws/devel/setup.bash && mkdir -p /root/output && rosrun vins vins_node ${CONFIG_FILE} 1 > /tmp/vins.log 2>&1"
    sleep 8

    echo -e "${BLUE}[5] Starting RViz...${NC}"
    docker exec -d "$CONTAINER_NAME" bash -c 'source /opt/ros/noetic/setup.bash && sleep 3 && rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz > /tmp/rviz.log 2>&1'
    sleep 5

    echo -e "${BLUE}[6] Playing rosbag...${NC}"
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

    echo -e "${GREEN}${TEST_NAME} completed!${NC}"
    echo -e "Output files in: ${HOST_OUTPUT_SUBDIR}"
    ls -la "$HOST_OUTPUT_SUBDIR" 2>/dev/null || true

    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    sleep 3
}

# Test 1: Original VINS-Fusion
run_test_in_container "$CONTAINER_ORIG" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml" \
    "$RESULTS_DIR/original" \
    "Original VINS-Fusion (Shi-Tomasi + LK Flow)"

# Test 2: SuperPoint + Optical Flow
run_test_in_container "$CONTAINER_SP_FLOW" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config_deep.yaml" \
    "$RESULTS_DIR/superpoint_flow" \
    "SuperPoint + Optical Flow (TensorRT)"

# Test 3: SuperPoint + LightGlue
run_test_in_container "$CONTAINER_SP_LG" \
    "/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config_lightglue.yaml" \
    "$RESULTS_DIR/superpoint_lightglue" \
    "SuperPoint + LightGlue (TensorRT Pipeline)"

# Run comparison analysis
echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  Running Trajectory Comparison Analysis${NC}"
echo -e "${BLUE}=========================================${NC}"

docker run --rm \
    --net=host --gpus all \
    -v "$RESULTS_DIR/original:/orig:ro" \
    -v "$RESULTS_DIR/superpoint_flow:/sp:ro" \
    -v "$RESULTS_DIR/superpoint_lightglue:/splg:ro" \
    -v "$DATASET_DIR:/dataset:ro" \
    -v "${PROJECT_DIR}/scripts:/scripts:ro" \
    -v "$RESULTS_DIR:/output" \
    "$IMAGE" \
    bash -c 'source /opt/ros/noetic/setup.bash && python3 /scripts/compare_trajectories.py \
        --gt /dataset/mav0/state_groundtruth_estimate0/data.csv \
        --orig-bag /orig/trajectory.bag \
        --orig-csv /orig/vio.csv \
        --sp-bag /sp/trajectory.bag \
        --sp-csv /sp/vio.csv \
        --splg-bag /splg/trajectory.bag \
        --splg-csv /splg/vio.csv \
        --output-dir /output \
        --rpe-delta 1.0'

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Comparison Test Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "All results saved to host directory:"
echo -e "  ${RESULTS_DIR}/"
echo ""
echo -e "Contents:"
ls -la "$RESULTS_DIR/" 2>/dev/null || true
echo ""
echo -e "${BLUE}Original:${NC}"
ls -la "$RESULTS_DIR/original/" 2>/dev/null || true
echo ""
echo -e "${BLUE}SuperPoint+Flow:${NC}"
ls -la "$RESULTS_DIR/superpoint_flow/" 2>/dev/null || true
echo ""
echo -e "${BLUE}SuperPoint+LightGlue:${NC}"
ls -la "$RESULTS_DIR/superpoint_lightglue/" 2>/dev/null || true
echo ""

if [ -f "$RESULTS_DIR/original/vio.csv" ] && [ -f "$RESULTS_DIR/superpoint_flow/vio.csv" ] && [ -f "$RESULTS_DIR/superpoint_lightglue/vio.csv" ]; then
    echo -e "${BLUE}VIO CSV comparison:${NC}"
    echo "  Original lines:            $(wc -l < "$RESULTS_DIR/original/vio.csv")"
    echo "  SuperPoint+Flow lines:     $(wc -l < "$RESULTS_DIR/superpoint_flow/vio.csv")"
    echo "  SuperPoint+LightGlue lines: $(wc -l < "$RESULTS_DIR/superpoint_lightglue/vio.csv")"
fi

echo ""
echo -e "${GREEN}Done!${NC}"