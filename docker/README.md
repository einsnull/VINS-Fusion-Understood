# VINS-Fusion Docker 运行指南

## 概述

本指南说明如何在 Docker 中运行 VINS-Fusion，实现相机-IMU 融合定位，并显示点云和轨迹可视化。

## 环境要求

- NVIDIA GPU + NVIDIA 驱动
- Docker with NVIDIA runtime
- ROS Kinetic
- EuRoC MAV 数据集

## 快速开始

### 1. 构建 Docker 镜像

```bash
cd VINS-Fusion/docker
docker build -t ros:vins-fusion .
```

### 2. 运行 VINS（带 Pangolin UI）

```bash
cd VINS-Fusion/docker
xhost +local:docker
./run.sh ../config/euroc/euroc_stereo_imu_config.yaml
```

这将启动：
- roscore
- VINS 节点（Pangolin UI）
- 容器保持运行

### 3. 播放数据集

在另一个终端执行：

```bash
docker exec <container_name> bash -c "source /opt/ros/kinetic/setup.bash && cd /root/catkin_ws && source devel/setup.bash && rosbag play /root/catkin_ws/src/VINS-Fusion/dataset/machine_hall/MH_01_easy/MH_01_easy.bag --clock"
```

### 4. 查看 RViz 可视化

```bash
# 安装 RViz（首次）
docker exec <container_name> bash -c "apt-get update && apt-get install -y ros-kinetic-rviz"

# 启动 RViz
docker exec -e DISPLAY=:1 <container_name> bash -c "source /opt/ros/kinetic/setup.bash && rviz -d /root/catkin_ws/src/VINS-Fusion/config/vins_rviz_config.rviz"
```

## 命令说明

### run.sh 选项

```bash
./run.sh <config_file>          # 带 UI 运行（默认）
./run.sh <config_file> 0        # 不带 UI 运行
```

### 主要话题

| 话题名 | 类型 | 说明 |
|--------|------|------|
| `/cam0/image_raw` | Image | 左相机图像 |
| `/cam1/image_raw` | Image | 右相机图像 |
| `/imu0` | Imu | IMU 数据 |
| `/feature_tracker/feature` | Feature | 跟踪的特征 |
| `/vins_estimator/point_cloud` | PointCloud | 点云地图 |
| `/vins_estimator/image_track` | Image | 特征点可视化 |
| `/vins_estimator/trajectory` | Pose | 轨迹输出 |

## 数据集

### EuRoC MAV 数据集

下载链接：https://projects.asl.ethz.ch/datasets/gscam/eurocmavdata

数据应放置在：
```
VINS-Fusion/dataset/machine_hall/MH_01_easy/MH_01_easy.bag
```

## 常见问题

### 1. OpenGL 错误

```
libGL error: failed to create dri screen
libGL error: failed to load driver: nouveau
```

解决：容器内的 mesa 库已被移除，强制使用 NVIDIA OpenGL。

### 2. X11 显示权限错误

```
Authorization required, but no authorization protocol specified
```

解决：运行 `xhost +local:docker`

### 3. 找不到 roscore

确保使用 `--net=host` 网络模式。

## 容器管理

```bash
# 查看运行中的容器
docker ps

# 查看容器日志
docker logs <container_name>

# 进入容器 bash
docker exec -it <container_name> bash

# 停止容器
docker stop <container_name>
```

## 文件说明

- `Dockerfile` - Docker 镜像构建文件
- `run.sh` - 启动脚本
- `start_vins.sh` - 容器内启动脚本（自动挂载到容器）
