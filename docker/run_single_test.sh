#!/bin/bash
# 运行单个测试并修复崩溃问题

set -e

CONFIG=${1:-"config/euroc/euroc_stereo_imu_config.yaml"}
IMAGE=${2:-"ros:vins-fusion"}
DATASET=${3:-"/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"}

echo "========================================="
echo "VINS-Fusion 单测试运行"
echo "========================================="
echo "Config: $CONFIG"
echo "Image: $IMAGE"
echo "Dataset: $DATASET"
echo ""

VINS_DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$VINS_DIR/output"

docker run -i --rm \
    --net=host \
    --gpus all \
    -v "$VINS_DIR:/root/catkin_ws/src/VINS-Fusion" \
    -v "$VINS_DIR/output:/root/output" \
    -v "$DATASET:/dataset:ro" \
    "$IMAGE" \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        # 创建输出目录
        mkdir -p ~/output
        
        roscore &
        sleep 3
        
        echo '启动VINS节点...'
        rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/$CONFIG &
        VINS_PID=\$!
        
        sleep 5
        
        echo '播放数据集...'
        rosbag play /dataset/*.bag --clock &
        BAG_PID=\$!
        
        echo '等待数据集播放完成...'
        wait \$BAG_PID
        
        echo '数据集播放完成'
        sleep 5
        
        # 检查结果
        if [ -f ~/output/vio.csv ]; then
            echo '✓ 结果文件已生成'
            wc -l ~/output/vio.csv
        else
            echo '✗ 未找到结果文件'
        fi
        
        kill \$VINS_PID 2>/dev/null || true
        wait \$VINS_PID 2>/dev/null || true
        
        echo '完成!'
    "
