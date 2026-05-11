#!/bin/bash
# 运行SuperPoint版本的完整测试

set -e

VINS_DIR=$(cd "$(dirname "$0")/.." && pwd)
DATASET="${1:-$VINS_DIR/dataset/machine_hall/MH_01_easy}"

echo "========================================="
echo "VINS-Fusion SuperPoint版本测试"
echo "========================================="
echo "Dataset: $DATASET"
echo ""

# 确保X11权限
xhost +local:docker 2>/dev/null || true

if [ -z "$DISPLAY" ]; then
    export DISPLAY=:1
fi

# 启动容器（前台运行以便查看日志）
docker run --rm \
    --net=host \
    --gpus all \
    --privileged \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "$VINS_DIR:/root/catkin_ws/src/VINS-Fusion" \
    -v "$DATASET:/dataset:ro" \
    vins-fusion-tensorrt:latest \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        # 启动roscore
        echo '启动roscore...'
        roscore &
        sleep 3
        
        echo '启动VINS节点（SuperPoint版本）...'
        rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml &
        VINS_PID=\$!
        
        sleep 5
        
        # 检查VINS是否正常运行
        if ! kill -0 \$VINS_PID 2>/dev/null; then
            echo '错误: VINS节点未能启动'
            exit 1
        fi
        
        echo 'VINS节点已启动'
        
        # 启动RViz
        echo '启动RViz...'
        rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz &
        RVIZ_PID=\$!
        
        sleep 3
        
        # 播放数据集
        echo '播放数据集...'
        rosbag play /dataset/*.bag --clock &
        BAG_PID=\$!
        
        echo ''
        echo '所有服务已启动:'
        echo '- VINS: SuperPoint版本'
        echo '- RViz: 显示3D轨迹和点云'
        echo ''
        
        # 等待数据集播放完成
        wait \$BAG_PID
        
        echo '数据集播放完成'
        
        # 等待一段时间让VINS完成处理
        sleep 10
        
        # 停止VINS和RViz
        kill \$VINS_PID 2>/dev/null || true
        kill \$RVIZ_PID 2>/dev/null || true
        
        wait \$VINS_PID 2>/dev/null || true
        wait \$RVIZ_PID 2>/dev/null || true
        
        echo '完成!'
    "
