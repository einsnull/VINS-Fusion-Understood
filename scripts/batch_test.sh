#!/bin/bash
# Batch test: Original + SuperPoint+Flow (1x) + SuperPoint+LightGlue (0.5x)
# for MH_02_easy, MH_03_medium, MH_04_difficult, MH_05_difficult
set +H

IMAGE="vins-fusion-superpoint:latest"
PROJECT_DIR="/storage/VINS-Fusion-Understood"
DATASET_BASE="${PROJECT_DIR}/dataset/machine_hall"
RESULTS_BASE="${PROJECT_DIR}/comparison_results"

ORIG_CONFIG="/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml"
SP_CONFIG="/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config_deep.yaml"
SPLG_CONFIG="/root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config_lightglue.yaml"

SEQUENCES=("MH_02_easy" "MH_03_medium" "MH_04_difficult" "MH_05_difficult")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

run_single_test() {
    local seq=$1
    local method=$2
    local config=$3
    local rate=$4
    local container_name="vins_${seq}_${method}"

    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}  Running: ${seq} / ${method} (rate=${rate}x)${NC}"
    echo -e "${BLUE}============================================================${NC}"

    local result_dir="${RESULTS_BASE}/${seq}/${method}"
    mkdir -p "$result_dir"

    docker stop "$container_name" 2>/dev/null || true

    echo -e "${YELLOW}[1/5] Starting container...${NC}"
    docker run -d --rm --name "$container_name" \
        --net=host --gpus all \
        -e DISPLAY=$DISPLAY -e QT_X11_NO_MITSHM=1 \
        -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        -v "${DATASET_BASE}":/dataset:ro \
        -v "${PROJECT_DIR}":/root/catkin_ws/src/VINS-Fusion \
        -v "${result_dir}:/root/output" \
        "$IMAGE" /bin/bash -c "while true; do sleep 3600; done"
    sleep 2

    echo -e "${YELLOW}[2/5] Building...${NC}"
    docker exec "$container_name" bash -c '
        source /opt/ros/noetic/setup.bash
        cd /root/catkin_ws
        catkin build --no-status -DCMAKE_BUILD_TYPE=Release -DUSE_TENSORRT=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 2>&1 | tail -3
    '

    echo -e "${YELLOW}[3/5] Starting roscore + vins_node...${NC}"
    docker exec -d "$container_name" bash -c 'source /opt/ros/noetic/setup.bash && roscore > /tmp/roscore.log 2>&1'
    sleep 4

    docker exec -d "$container_name" bash -c "
        source /opt/ros/noetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        mkdir -p /root/output
        rosrun vins vins_node ${config} 1 > /tmp/vins.log 2>&1
    "
    sleep 10

    echo -e "${YELLOW}[4/5] Playing rosbag at ${rate}x ...${NC}"
    docker exec "$container_name" bash -c "
        source /opt/ros/noetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        rosbag record -O /root/output/trajectory.bag /vins_estimator/odometry /feature_tracker/feature &
        RECORD_PID=\$!
        sleep 2
        rosbag play /dataset/${seq}/${seq}.bag --clock -r ${rate} -q
        sleep 8
        kill \$RECORD_PID 2>/dev/null || true
        sleep 2
    "

    echo -e "${YELLOW}[5/5] Collecting results...${NC}"
    local vio_csv="${result_dir}/vio.csv"
    local traj_bag="${result_dir}/trajectory.bag"

    if [ -f "$vio_csv" ]; then
        local vio_lines=$(wc -l < "$vio_csv")
        echo -e "  ${GREEN}vio.csv: ${vio_lines} poses${NC}"
    else
        echo -e "  ${RED}vio.csv: MISSING${NC}"
        docker exec "$container_name" cat /tmp/vins.log 2>/dev/null | tail -10
    fi

    if [ -f "$traj_bag" ]; then
        local bag_size=$(du -h "$traj_bag" | cut -f1)
        echo -e "  trajectory.bag: ${bag_size}"
    else
        echo -e "  ${RED}trajectory.bag: MISSING${NC}"
    fi

    docker stop "$container_name" 2>/dev/null || true
    sleep 2
}

xhost +local:docker 2>/dev/null || true

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  BATCH TEST: Machine Hall Sequences${NC}"
echo -e "${GREEN}  Original (1x) | SP+Flow (1x) | SP+LightGlue (0.5x)${NC}"
echo -e "${GREEN}============================================================${NC}"

for seq in "${SEQUENCES[@]}"; do
    echo ""
    echo -e "${GREEN}############################################################${NC}"
    echo -e "${GREEN}  SEQUENCE: ${seq}${NC}"
    echo -e "${GREEN}############################################################${NC}"

    run_single_test "$seq" "original" "$ORIG_CONFIG" "1.0"
    run_single_test "$seq" "superpoint_flow" "$SP_CONFIG" "1.0"
    run_single_test "$seq" "superpoint_lightglue" "$SPLG_CONFIG" "0.5"
done

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ALL EXPERIMENTS COMPLETE${NC}"
echo -e "${GREEN}============================================================${NC}"

echo ""
echo -e "${BLUE}Summary:${NC}"
for seq in "${SEQUENCES[@]}"; do
    echo ""
    echo -e "  ${YELLOW}--- ${seq} ---${NC}"
    for method in original superpoint_flow superpoint_lightglue; do
        local f="${RESULTS_BASE}/${seq}/${method}/vio.csv"
        if [ -f "$f" ]; then
            echo -e "    ${method}: ${GREEN}$(wc -l < "$f") poses${NC}"
        else
            echo -e "    ${method}: ${RED}MISSING${NC}"
        fi
    done
done