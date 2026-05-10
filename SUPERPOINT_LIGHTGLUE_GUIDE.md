# VINS-Fusion with SuperPoint + LightGlue 完整使用指南

## 概述

本项目在VINS-Fusion中集成了SuperPoint特征提取和LightGlue特征匹配，使用TensorRT进行加速。支持三种运行模式：

1. **原始VINS-Fusion**: 传统特征点 + LK光流
2. **SuperPoint + 光流**: 深度学习特征点 + LK光流
3. **SuperPoint + LightGlue**: 深度学习特征点 + 神经网络匹配

## 环境要求

- NVIDIA GPU (RTX 2060 Super或更高)
- NVIDIA驱动程序
- Docker with NVIDIA runtime
- ROS Kinetic

## 快速开始

### 1. 构建Docker镜像

```bash
cd VINS-Fusion/docker
docker build -f Dockerfile.tensorrt -t vins-fusion-tensorrt:latest .
```

### 2. 运行对比测试

我们提供了完整的对比测试脚本，可以运行所有三个版本并生成对比报告：

```bash
cd VINS-Fusion/docker
./run_comparison.sh
```

这个脚本会：
- 运行原始VINS-Fusion
- 运行SuperPoint + 光流版本
- 运行SuperPoint + LightGlue版本
- 如果有ground truth数据，自动计算ATE误差
- 生成对比报告

### 3. 带可视化的对比测试

如果需要实时查看RViz和Pangolin可视化：

```bash
cd VINS-Fusion/docker
./run_comparison_visual.sh
```

**注意**: 每个版本运行时都会显示：
- **Pangolin UI**: 实时显示特征跟踪、点云和相机位姿
- **RViz**: 显示3D轨迹和点云可视化

## 详细使用说明

### 运行单个版本

#### 原始VINS-Fusion

```bash
cd VINS-Fusion/docker
xhost +local:docker
./run.sh ../config/euroc/euroc_stereo_imu_config.yaml
```

#### SuperPoint + 光流

```bash
cd VINS-Fusion/docker
xhost +local:docker
./run.sh ../config/euroc/euroc_stereo_imu_config_deep.yaml
```

#### SuperPoint + LightGlue

```bash
# 先创建LightGlue配置文件
cp ../config/euroc/euroc_stereo_imu_config_deep.yaml /tmp/lightglue_config.yaml
sed -i 's/deep_feature_mode: 0/deep_feature_mode: 1/' /tmp/lightglue_config.yaml

# 运行
cd VINS-Fusion/docker
xhost +local:docker
./run.sh /tmp/lightglue_config.yaml
```

### 播放数据集

在另一个终端执行：

```bash
# 获取容器名称
CONTAINER=$(docker ps | grep vins-fusion | awk '{print $NF}')

# 播放数据集
docker exec $CONTAINER bash -c "source /opt/ros/kinetic/setup.bash && cd /root/catkin_ws && source devel/setup.bash && rosbag play /root/catkin_ws/src/VINS-Fusion/dataset/machine_hall/MH_01_easy/MH_01_easy.bag --clock"
```

### 启动RViz可视化

```bash
# 获取容器名称
CONTAINER=$(docker ps | grep vins-fusion | awk '{print $NF}')

# 启动RViz
docker exec -e DISPLAY=:1 $CONTAINER bash -c "source /opt/ros/kinetic/setup.bash && rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz"
```

## 配置文件说明

### 深度特征配置参数

在 `config/euroc/euroc_stereo_imu_config_deep.yaml` 中：

```yaml
# 深度特征设置
deep_features: 1              # 是否使用深度学习特征
deep_feature_mode: 0         # 0: SuperPoint+光流, 1: SuperPoint+LightGlue
sp_engine_path: "/root/catkin_ws/src/VINS-Fusion/models/superpoint_lightglue_fused.onnx.engine"  # TensorRT引擎路径
lg_engine_path: ""           # LightGlue引擎路径（如果与SuperPoint融合则留空）
```

## 性能对比

### 预期结果

| 版本 | 处理速度 | 特征质量 | 匹配精度 | 适用场景 |
|------|---------|---------|---------|---------|
| 原始VINS | 最快 | 一般 | 一般 | 资源受限，实时性要求高 |
| SuperPoint+光流 | 中等 | 好 | 好 | 平衡性能和精度 |
| SuperPoint+LightGlue | 较慢 | 最好 | 最好 | 精度要求高，特征稀疏场景 |

### 与Ground Truth对比

如果有EuRoC数据集的ground truth，可以计算ATE（绝对轨迹误差）：

```bash
# 使用evo工具
pip install evo

# 对比轨迹
evo_ape euroc ground_truth.csv trajectory.txt --save_results results.zip

# 绘制对比图
evo_ape euroc ground_truth.csv trajectory.txt --plot --save_plot plot.pdf
```

## 项目结构

```
VINS-Fusion/
├── vins_estimator/
│   ├── src/
│   │   ├── deep_net/              # TensorRT推理代码
│   │   │   ├── trt_engine.h/cpp   # TensorRT引擎封装
│   │   │   ├── superpoint_lightglue.h/cpp  # SuperPoint+LightGlue推理
│   │   │   └── trt_logger.h       # TensorRT日志
│   │   └── featureTracker/
│   │       ├── feature_tracker.h  # 特征跟踪器（添加深度特征支持）
│   │       └── feature_tracker.cpp
│   └── CMakeLists.txt             # 添加TensorRT支持
├── config/
│   └── euroc/
│       └── euroc_stereo_imu_config_deep.yaml  # 深度特征配置
├── docker/
│   ├── Dockerfile.tensorrt        # TensorRT Docker镜像
│   ├── run_comparison.sh          # 完整对比测试
│   ├── run_comparison_visual.sh   # 带可视化的对比测试
│   └── compare_with_groundtruth.py  # Ground truth对比脚本
└── models/                        # TensorRT引擎文件
```

## 故障排除

### RViz无法显示

1. 确保X11转发正确：
```bash
xhost +local:docker
```

2. 检查DISPLAY环境变量：
```bash
echo $DISPLAY
```

3. 如果使用NVIDIA GPU，确保nvidia-docker2已安装：
```bash
docker run --gpus all nvidia/cuda:11.0-base nvidia-smi
```

### TensorRT引擎加载失败

1. 检查引擎文件是否存在：
```bash
ls -la models/superpoint_lightglue_fused.onnx.engine
```

2. 如果引擎文件不存在，需要从ONNX转换：
```bash
python3 scripts/convert_onnx_to_trt.py
```

### 内存不足

如果运行时报内存错误，可以尝试：
1. 减少特征点数量
2. 使用FP16模式（如果GPU支持）
3. 关闭RViz可视化

## 提交代码

```bash
# 添加所有更改
git add -A

# 提交
git commit -m "Add SuperPoint + LightGlue support with TensorRT"

# 推送到GitHub
git push origin master
```

## 参考文献

- VINS-Fusion: https://github.com/HKUST-Aerial-Robotics/VINS-Fusion
- SuperPoint: https://github.com/magicleap/SuperPointPretrainedNetwork
- LightGlue: https://github.com/cvg/LightGlue
- TensorRT: https://developer.nvidia.com/tensorrt

## 许可证

本项目遵循MIT许可证。原始VINS-Fusion代码遵循GPL许可证。
