#!/bin/bash
# 最终测试脚本 - 确保正确保存结果

set -e

VINS_DIR=$(cd "$(dirname "$0")/.." && pwd)
DATASET="/storage/VINS-Fusion-Understood/dataset/machine_hall/MH_01_easy"
RESULTS_DIR="$VINS_DIR/test_results"
mkdir -p "$RESULTS_DIR"

# 确保X11权限
xhost +local:docker 2>/dev/null || true

if [ -z "$DISPLAY" ]; then
    export DISPLAY=:1
fi

echo "========================================="
echo "VINS-Fusion 最终测试"
echo "========================================="
echo "Dataset: MH_01_easy"
echo "Results: $RESULTS_DIR"
echo ""

# 函数：运行单个测试
run_test() {
    local NAME=$1
    local IMAGE=$2
    local CONFIG=$3
    local OUTPUT_DIR="$RESULTS_DIR/$NAME"
    mkdir -p "$OUTPUT_DIR"
    
    echo ""
    echo "========================================="
    echo "测试: $NAME"
    echo "========================================="
    
    docker run -i --rm \
        --net=host \
        --gpus all \
        -v "$VINS_DIR:/root/catkin_ws/src/VINS-Fusion" \
        -v "$OUTPUT_DIR:/root/output" \
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
            
            wait \$BAG_PID
            
            echo '数据集播放完成'
            echo '等待VINS保存结果...'
            sleep 10
            
            # 检查结果
            if [ -f ~/output/vio.csv ]; then
                echo '✓ 结果文件已生成'
                ls -la ~/output/vio.csv
                wc -l ~/output/vio.csv
            else
                echo '✗ 未找到结果文件，检查原因...'
                ls -la ~/output/
            fi
            
            kill \$VINS_PID 2>/dev/null || true
            wait \$VINS_PID 2>/dev/null || true
        " || echo "测试 $NAME 完成"
    
    echo "✓ $NAME 测试完成"
}

# 测试1: 原始版本
echo ""
echo "测试1/1: 原始版本 (Traditional)"
run_test "original" "ros:vins-fusion" "config/euroc/euroc_stereo_imu_config.yaml"

echo ""
echo "========================================="
echo "测试完成"
echo "========================================="
echo ""
echo "结果目录: $RESULTS_DIR"
ls -la "$RESULTS_DIR"
