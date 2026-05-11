#!/bin/bash
# 运行VINS-Fusion并确保可视化正常工作

set -e

# 获取配置参数
CONFIG=${1:-"config/euroc/euroc_stereo_imu_config.yaml"}
IMAGE=${2:-"ros:vins-fusion"}
TEST_NAME=${3:-"vins_vis"}

echo "========================================="
echo "运行VINS-Fusion with Visualization"
echo "========================================="
echo "Config: $CONFIG"
echo "Image: $IMAGE"
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

# 运行Docker容器，包含所有可视化支持
docker run -it --rm \
    --name "$TEST_NAME" \
    --net=host \
    --gpus all \
    --privileged \
    -e DISPLAY=$DISPLAY \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e LIBGL_ALWAYS_SOFTWARE=1 \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "$VINS_DIR:/root/catkin_ws/src/VINS-Fusion" \
    -v "$VINS_DIR/output:/root/output" \
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
        
        echo '启动VINS节点（带UI）...'
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
        echo '按Ctrl+C停止'
        
        # 保持运行
        wait \$VINS_PID
    "

echo "容器已停止"
