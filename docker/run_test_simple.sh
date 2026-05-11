#!/bin/bash
# 简化的测试脚本 - 运行VINS-Fusion并播放数据集

set -e

CONFIG=${1:-"config/euroc/euroc_stereo_imu_config.yaml"}
IMAGE=${2:-"ros:vins-fusion"}
DATASET=${3:-"/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"}

echo "========================================="
echo "VINS-Fusion 测试"
echo "========================================="
echo "Config: $CONFIG"
echo "Image: $IMAGE"
echo "Dataset: $DATASET"
echo ""

# 确保X11权限
xhost +local:docker 2>/dev/null || true

# 检查DISPLAY
if [ -z "$DISPLAY" ]; then
    export DISPLAY=:1
fi

VINS_DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$VINS_DIR/output"

# 运行容器
docker run -it --rm \
    --net=host \
    --gpus all \
    --privileged \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "$VINS_DIR:/root/catkin_ws/src/VINS-Fusion" \
    -v "$VINS_DIR/output:/root/output" \
    -v "$DATASET:/dataset:ro" \
    "$IMAGE" \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        roscore &
        sleep 3
        
        echo '启动VINS...'
        rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/$CONFIG &
        VINS_PID=\$!
        
        sleep 5
        
        echo '播放数据集...'
        rosbag play /dataset/*.bag --clock &
        BAG_PID=\$!
        
        echo '等待运行完成...'
        wait \$BAG_PID
        
        echo '数据集播放完成，停止VINS...'
        kill \$VINS_PID 2>/dev/null || true
        wait \$VINS_PID 2>/dev/null || true
        
        echo '完成!'
    "
