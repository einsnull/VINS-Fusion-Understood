#!/bin/bash
# 运行VINS-Fusion并确保UI可视化正常显示

set -e

CONFIG=${1:-"config/euroc/euroc_stereo_imu_config.yaml"}
IMAGE=${2:-"ros:vins-fusion"}
DATASET=${3:-"/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"}

echo "========================================="
echo "VINS-Fusion with UI"
echo "========================================="

# 确保X11权限
xhost +local:docker 2>/dev/null || true

# 检查DISPLAY
if [ -z "$DISPLAY" ]; then
    export DISPLAY=:1
fi
echo "DISPLAY=$DISPLAY"

VINS_DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$VINS_DIR/output"

# 获取当前用户的UID和GID
USER_ID=$(id -u)
GROUP_ID=$(id -g)

echo "启动VINS-Fusion容器（带UI支持）..."
docker run -it --rm \
    --net=host \
    --gpus all \
    --privileged \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e LIBGL_ALWAYS_SOFTWARE=1 \
    -e __GLX_VENDOR_LIBRARY_NAME=nvidia \
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
        
        echo 'VINS节点已启动'
        echo 'Pangolin窗口应该正在显示...'
        
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
        echo '- Pangolin: 显示VINS内部状态'
        echo '- RViz: 显示3D轨迹和点云'
        echo ''
        
        # 等待数据集播放完成
        wait \$BAG_PID
        
        echo '数据集播放完成'
        
        # 停止VINS和RViz
        kill \$VINS_PID 2>/dev/null || true
        kill \$RVIZ_PID 2>/dev/null || true
        
        wait \$VINS_PID 2>/dev/null || true
        wait \$RVIZ_PID 2>/dev/null || true
        
        echo '完成!'
    "
