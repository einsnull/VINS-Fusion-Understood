#!/bin/bash
# 完整的可视化测试脚本 - 启动VINS-Fusion、RViz和Pangolin

set -e

# 参数
CONFIG=${1:-"config/euroc/euroc_stereo_imu_config.yaml"}
IMAGE=${2:-"ros:vins-fusion"}
TEST_NAME=${3:-"vins_visual"}
DATASET=${4:-"/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"}

echo "========================================="
echo "VINS-Fusion 可视化测试"
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
echo "Using DISPLAY=$DISPLAY"

# 获取绝对路径
VINS_DIR=$(cd "$(dirname "$0")/.." && pwd)

# 创建结果目录
mkdir -p "$VINS_DIR/output"

# 停止已有的容器
docker stop vins_original vins_rviz 2>/dev/null || true

echo "启动VINS-Fusion容器..."
docker run -d --rm \
    --name vins_original \
    --net=host \
    --gpus all \
    --privileged \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "$VINS_DIR:/root/catkin_ws/src/VINS-Fusion" \
    -v "$VINS_DIR/output:/root/output" \
    -v "$DATASET:/dataset:ro" \
    "$IMAGE" \
    /bin/bash -c "
        # 设置NVIDIA GL库
        mv /usr/lib/x86_64-linux-gnu/mesa /usr/lib/x86_64-linux-gnu/mesa.bak 2>/dev/null || true
        ln -sf /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libGL.so 2>/dev/null || true
        ln -sf /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libGL.so.1 2>/dev/null || true
        ldconfig 2>/dev/null || true
        
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        # 启动roscore
        roscore &
        sleep 3
        
        echo '启动VINS节点（带Pangolin UI）...'
        # 使用UI选项1启用Pangolin
        rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/$CONFIG 1 &
        VINS_PID=\$!
        
        sleep 5
        
        # 检查VINS是否运行
        if ! kill -0 \$VINS_PID 2>/dev/null; then
            echo '错误: VINS节点未能启动'
            exit 1
        fi
        
        echo 'VINS节点已启动，PID: '\$VINS_PID
        echo 'Pangolin应该正在显示...'
        
        # 等待数据集播放结束
        wait \$VINS_PID
    "

echo ""
echo "启动RViz..."
docker run -d --rm \
    --name vins_rviz \
    --net=host \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "$VINS_DIR/config/vins_rviz_config.rviz:/tmp/vins_rviz_config.rviz:ro" \
    ros:vins-fusion \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        sleep 10
        rviz -d /tmp/vins_rviz_config.rviz
    "

echo ""
echo "========================================="
echo "所有服务已启动"
echo "========================================="
echo "Pangolin窗口: 显示VINS内部状态"
echo "RViz窗口: 显示3D轨迹和点云"
echo ""
echo "正在播放数据集..."
docker exec vins_original bash -c "source /opt/ros/kinetic/setup.bash && rosbag play /dataset/*.bag --clock" &

echo ""
echo "按Enter键停止所有服务"
read

echo "停止所有容器..."
docker stop vins_original vins_rviz 2>/dev/null || true

echo "完成!"
