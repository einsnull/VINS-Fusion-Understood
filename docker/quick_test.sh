#!/bin/bash
# 快速测试脚本 - 验证所有三个版本是否能正常运行

set -e

DATASET="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="/storage/VINS-Fusion-Understood/docker/test_results"
mkdir -p "$RESULTS_DIR"

# 允许Docker访问X11
xhost +local:docker 2>/dev/null || true

echo "========================================="
echo "快速测试 - VINS-Fusion 三个版本"
echo "========================================="

# 测试1: 原始版本
echo ""
echo "测试1/3: 原始版本 (Traditional Features)"
echo "-----------------------------------------"
docker run -i --rm \
    --net=host \
    -v "$DATASET:/dataset:ro" \
    ros:vins-fusion \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        # 启动roscore
        roscore &
        sleep 3
        
        # 启动VINS节点（后台运行，只检查是否能初始化）
        timeout 15 rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml 2>&1 | head -50 &
        VINS_PID=\$!
        
        sleep 10
        
        # 检查进程是否还在运行
        if kill -0 \$VINS_PID 2>/dev/null; then
            echo '✓ 原始版本: 正常启动'
            kill \$VINS_PID 2>/dev/null || true
        else
            echo '✗ 原始版本: 启动失败'
        fi
        
        wait \$VINS_PID 2>/dev/null || true
    " || echo "原始版本测试完成"

# 测试2: SuperPoint + 光流
echo ""
echo "测试2/3: SuperPoint + Optical Flow"
echo "-----------------------------------------"
docker run -i --rm \
    --net=host \
    --gpus all \
    -v "$DATASET:/dataset:ro" \
    -v "$(pwd)/..:/root/catkin_ws/src/VINS-Fusion" \
    vins-fusion-tensorrt:latest \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        # 启动roscore
        roscore &
        sleep 3
        
        # 启动VINS节点（使用deep config，但TensorRT未安装时会自动fallback）
        timeout 15 rosrun vins vins_node /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml 2>&1 | head -80 &
        VINS_PID=\$!
        
        sleep 10
        
        # 检查进程是否还在运行
        if kill -0 \$VINS_PID 2>/dev/null; then
            echo '✓ SuperPoint+Flow: 正常启动（可能使用fallback模式）'
            kill \$VINS_PID 2>/dev/null || true
        else
            echo '✗ SuperPoint+Flow: 启动失败'
        fi
        
        wait \$VINS_PID 2>/dev/null || true
    " || echo "SuperPoint+Flow测试完成"

# 测试3: SuperPoint + LightGlue
echo ""
echo "测试3/3: SuperPoint + LightGlue"
echo "-----------------------------------------"
docker run -i --rm \
    --net=host \
    --gpus all \
    -v "$DATASET:/dataset:ro" \
    -v "$(pwd)/..:/root/catkin_ws/src/VINS-Fusion" \
    vins-fusion-tensorrt:latest \
    /bin/bash -c "
        source /opt/ros/kinetic/setup.bash
        source /root/catkin_ws/devel/setup.bash
        
        # 创建LightGlue模式的临时配置
        sed 's/deep_feature_mode: 0/deep_feature_mode: 1/' /root/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config_deep.yaml > /tmp/euroc_stereo_imu_config_lg.yaml
        
        # 启动roscore
        roscore &
        sleep 3
        
        # 启动VINS节点
        timeout 15 rosrun vins vins_node /tmp/euroc_stereo_imu_config_lg.yaml 2>&1 | head -80 &
        VINS_PID=\$!
        
        sleep 10
        
        # 检查进程是否还在运行
        if kill -0 \$VINS_PID 2>/dev/null; then
            echo '✓ SuperPoint+LightGlue: 正常启动（可能使用fallback模式）'
            kill \$VINS_PID 2>/dev/null || true
        else
            echo '✗ SuperPoint+LightGlue: 启动失败'
        fi
        
        wait \$VINS_PID 2>/dev/null || true
    " || echo "SuperPoint+LightGlue测试完成"

echo ""
echo "========================================="
echo "快速测试完成"
echo "========================================="
echo ""
echo "说明:"
echo "- 如果TensorRT未正确安装，深度学习版本会自动回退到传统特征点模式"
echo "- 要启用真正的SuperPoint+LightGlue，需要在Docker中安装TensorRT"
echo "- 详细对比测试请使用 run_full_test.sh"
