# VINS-Fusion-Understood

Welcome to **VINS-Fusion-Understood**: A fully understandable version of VINS-Fusion, codes refactored in Google style, reliable comments on almost every line, necessary modification on confusing member names, ROS code decoupled, glog embedded.

欢迎来到 **VINS-Fusion-Understood**，一个人人可懂的VINS-Fusion版本。

---

## SuperPoint + TensorRT 集成 (NEW)

本分支在 VINS-Fusion-Understood 基础上集成了 **SuperPoint 深度学习特征提取**，使用 TensorRT 进行 GPU 加速推理。

### 特性
- **SuperPoint 特征提取**: 使用官方 SuperPoint 模型，通过 TensorRT 加速，替代原有的 Shi-Tomasi 角点
- **光流追踪**: SuperPoint 特征点 + LK 光流追踪（与原版流程一致，仅替换特征提取器）
- **Docker 一键运行**: 完整的 Docker 环境，包含 CUDA 12.4 + TensorRT 8.6 + ROS Noetic
- **可视化**: Pangolin UI + RViz 实时显示

### 快速开始

```bash
# 1. 构建 Docker 镜像
cd docker
docker build -t vins-fusion-superpoint:latest .

# 2. 运行可视化测试（SuperPoint + 光流）
./run_visual_test.sh

# 3. 或使用原始特征运行
./run_comparison_visual.sh
```

### 配置说明

在 config yaml 中启用深度学习特征:
```yaml
use_deep_features: 1      # 1: 启用 SuperPoint
deep_feature_mode: 0      # 0: SuperPoint + 光流
deep_engine_path: "/models/superpoint_official.trt"
```

### 文件结构
```
vins_estimator/src/deep_net/     # TensorRT 推理封装
  ├── trt_engine.h/cpp           # TensorRT 引擎封装
  ├── superpoint_lightglue.h/cpp # SuperPoint 特征提取
config/euroc/
  └── euroc_mono_imu_config_deep.yaml  # 深度学习配置文件
docker/
  ├── Dockerfile                 # 合并后的 Dockerfile
  ├── run_visual_test.sh         # 可视化测试脚本
  ├── run_comparison_test.sh     # 对比测试脚本（原始 vs SuperPoint）
  └── TensorRT-8.6.1.6...tar.gz  # TensorRT 安装包
models/
  └── superpoint_official.trt    # SuperPoint TensorRT 引擎
scripts/
  ├── export_official_models.py  # ONNX 导出脚本
  ├── convert_onnx_to_trt.py     # ONNX -> TensorRT 转换
  └── compare_trajectories.py    # 轨迹对比分析（ATE/RPE/3D可视化）
```

### 对比测试：原始版 vs SuperPoint

一键运行对比测试，自动完成编译、运行、轨迹分析，结果输出到宿主机目录：

```bash
# 前置条件：已构建 Docker 镜像
cd docker
docker build -t vins-fusion-superpoint:latest .

# 运行对比测试（需要 X11 显示，约 6 分钟）
./run_comparison_test.sh
```

测试流程：
1. 在容器内编译最新代码
2. 运行**原始版**（Shi-Tomasi + LK 光流）→ 输出 vio.csv + trajectory.bag
3. 运行 **SuperPoint 版**（SuperPoint + LK 光流）→ 输出 vio.csv + trajectory.bag
4. 自动计算 ATE / RPE，生成 3D 轨迹对比图和误差柱状图

结果输出到：`/storage/VINS-Fusion-Understood/comparison_results/<时间戳>/`

```
comparison_results/<时间戳>/
├── original/
│   ├── vio.csv           # 原始版轨迹（含纳秒时间戳）
│   └── trajectory.bag    # ROS bag
├── superpoint/
│   ├── vio.csv           # SuperPoint 版轨迹（含纳秒时间戳）
│   └── trajectory.bag    # ROS bag
├── trajectory_3d.png     # 3D 轨迹对比图
└── ate_comparison.png    # ATE 指标对比柱状图
```

### 评测指标说明

| 指标 | 含义 |
|------|------|
| ATE (Absolute Trajectory Error) | 绝对轨迹误差，Umeyama 对齐后计算 RMSE |
| RPE (Relative Pose Error) | 相对位姿误差，固定时间间隔（默认 1s）的位移误差 |

### 测试结果（MH_01_easy）

| 指标 | Original (Shi-Tomasi) | SuperPoint + Optical Flow |
|------|----------------------|--------------------------|
| ATE RMSE | 4.1284 m | 4.1221 m |
| ATE Mean | 3.7709 m | 3.7605 m |
| RPE RMSE | 0.8709 m | 0.8721 m |
| 匹配帧数 | 1819 | 1819 |

---

在这里，我们对[原版VINS-Fusion](https://github.com/HKUST-Aerial-Robotics/VINS-Fusion)的代码风格进行了重构，不仅包括【1】一些必要的Google风格变量重命名/缩进/大括号位置调整，更重要的是，【2】我们按照含义聚类和逻辑顺序重新排列了几乎所有的成员函数和数据成员，【3】并添加了详尽的、经得起推敲的注释，尤其是**三个主要类、以及滑窗优化、边缘化**等部分。由此，我们希望VINS-Fusion-Understood能够做到代码即文档——让读代码就像读文档一样轻松。此外，【4】我们还在VINS算法中剥离了所有的ROS代码，【5】并引入了glog作为日志工具，以方便调试和保存日志文件。这些改动都有助于您将VINS方便地移植到其它通信框架或计算平台上。【6】为了便于理解VINS，我们还引入了ui窗口以绘制VINS系统内部的状态信息，使VINS可视化。以上所有重构工作，您都可以从本仓库的代码中看到。您也可以从下方的动图中对VINS-Fusion-Understood的代码风格和注释内容窥见一二。

更详细的介绍，您可以前往中文博客查看：[【知乎】VINS-Fusion-Understood：完全可理解的VINS-Fusion，靠谱注释+工程重构版](https://zhuanlan.zhihu.com/p/674861674)

尽管做了以上重构，但**VINS-Fusion-Understood的代码内容严格忠实于原版，在精度和运行性能上也绝无二致**，下图是原版和本版本的运行结果对比。如果您对VINS-Fusion的源码尚不了解，这将是您上手VINS最合适的版本或参考。

> *注1：为了和VINS-Fusion原版不至于差异太大，大部分函数并没有做重命名，除非原版函数的命名让人费解 —— 比如我们把原版 `Estimator::relativePose()` 重命名为了 `VinsEstimator::searchRelativePose()`，把原版`Estimator::vector2double()`重命名为了`VinsEstimator::StateToCeresParam()`，把原版`FeatureManager::getCount()`重命名为了`FeatureManager::getRobustFeatureCount()`。*   
> *注2：目前，我们仅对VINS-Fusion中精华的vins_estimator模块完成了重构，其它部分留作将来TODO（若有需要）。*   


<img src="support_files/understood_version/left_official_vs_right.jpg" style="width:90%;height:auto;" /><br>
*图1：运行结果对比，左为官方版，右为本仓库版*

<img src="support_files/understood_version/Peek_vins_estimator.gif" style="width:90%;height:auto;" /><br>
*图2：VINS顶层类（class VinsEstimator）重构版预览*

<img src="support_files/understood_version/Peek_vins_f_tracker.gif" style="width:90%;height:auto;" /><br>
*图3：特征点光流追踪类（class FeatureTracker）重构版预览*

<img src="support_files/understood_version/Peek_vins_f_manager.gif" style="width:90%;height:auto;" /><br>
*图4：特征点管理类（class FeatureManager）重构版预览*

<img src="support_files/understood_version/with_pangolin_01.jpg" style="width:60%;height:auto;" /><br>
*图5：Vins-Fusion-Understood运行界面*


<br>
<br>
<br>
<br>
<br>
<br>


# VINS-Fusion

## An optimization-based multi-sensor state estimator

<img src="https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/support_files/image/vins_logo.png" width = 55% height = 55% div align=left />
<img src="https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/support_files/image/kitti.png" width = 34% height = 34% div align=center />

VINS-Fusion is an optimization-based multi-sensor state estimator, which achieves accurate self-localization for autonomous applications (drones, cars, and AR/VR). VINS-Fusion is an extension of [VINS-Mono](https://github.com/HKUST-Aerial-Robotics/VINS-Mono), which supports multiple visual-inertial sensor types (mono camera + IMU, stereo cameras + IMU, even stereo cameras only). We also show a toy example of fusing VINS with GPS. 
**Features:**
- multiple sensors support (stereo cameras / mono camera+IMU / stereo cameras+IMU)
- online spatial calibration (transformation between camera and IMU)
- online temporal calibration (time offset between camera and IMU)
- visual loop closure

<img src="https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/support_files/image/kitti_rank.png" width = 80% height = 80% />

We are the **top** open-sourced stereo algorithm on [KITTI Odometry Benchmark](http://www.cvlibs.net/datasets/kitti/eval_odometry.php) (12.Jan.2019).

**Authors:** [Tong Qin](http://www.qintonguav.com), Shaozu Cao, Jie Pan, [Peiliang Li](https://peiliangli.github.io/), and [Shaojie Shen](http://www.ece.ust.hk/ece.php/profile/facultydetail/eeshaojie) from the [Aerial Robotics Group](http://uav.ust.hk/), [HKUST](https://www.ust.hk/)

**Videos:**

<a href="https://www.youtube.com/embed/1qye82aW7nI" target="_blank"><img src="http://img.youtube.com/vi/1qye82aW7nI/0.jpg" 
alt="VINS" width="320" height="240" border="10" /></a>


**Related Paper:** (paper is not exactly same with code)

* **Online Temporal Calibration for Monocular Visual-Inertial Systems**, Tong Qin, Shaojie Shen, IEEE/RSJ International Conference on Intelligent Robots and Systems (IROS, 2018), **best student paper award** [pdf](https://ieeexplore.ieee.org/abstract/document/8593603)

* **VINS-Mono: A Robust and Versatile Monocular Visual-Inertial State Estimator**, Tong Qin, Peiliang Li, Shaojie Shen, IEEE Transactions on Robotics [pdf](https://ieeexplore.ieee.org/document/8421746/?arnumber=8421746&source=authoralert) 


*If you use VINS-Fusion for your academic research, please cite our related papers. [bib](https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/support_files/paper_bib.txt)*

## 1. Prerequisites
### 1.1 **Ubuntu** and **ROS**
Ubuntu 64-bit 16.04 or 18.04.
ROS Kinetic or Melodic. [ROS Installation](http://wiki.ros.org/ROS/Installation)


### 1.2. **Ceres Solver**
Follow [Ceres Installation](http://ceres-solver.org/installation.html).


## 2. Build VINS-Fusion
Clone the repository and catkin_make:
```
    cd ~/catkin_ws/src
    git clone https://github.com/HKUST-Aerial-Robotics/VINS-Fusion.git
    cd ../
    catkin_make
    source ~/catkin_ws/devel/setup.bash
```
(if you fail in this step, try to find another computer with clean system or reinstall Ubuntu and ROS)

## 3. EuRoC Example
Download [EuRoC MAV Dataset](http://projects.asl.ethz.ch/datasets/doku.php?id=kmavvisualinertialdatasets) to YOUR_DATASET_FOLDER. Take MH_01 for example, you can run VINS-Fusion with three sensor types (monocular camera + IMU, stereo cameras + IMU and stereo cameras). 
Open four terminals, run vins odometry, visual loop closure(optional), rviz and play the bag file respectively. 
Green path is VIO odometry; red path is odometry under visual loop closure.

### 3.1 Monocualr camera + IMU

```
    roslaunch vins vins_rviz.launch
    rosrun vins vins_node ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml 
    (optional) rosrun loop_fusion loop_fusion_node ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml 
    rosbag play YOUR_DATASET_FOLDER/MH_01_easy.bag
```

### 3.2 Stereo cameras + IMU

```
    roslaunch vins vins_rviz.launch
    rosrun vins vins_node ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml 
    (optional) rosrun loop_fusion loop_fusion_node ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_imu_config.yaml 
    rosbag play YOUR_DATASET_FOLDER/MH_01_easy.bag
```

### 3.3 Stereo cameras

```
    roslaunch vins vins_rviz.launch
    rosrun vins vins_node ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_config.yaml 
    (optional) rosrun loop_fusion loop_fusion_node ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_stereo_config.yaml 
    rosbag play YOUR_DATASET_FOLDER/MH_01_easy.bag
```

<img src="https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/support_files/image/euroc.gif" width = 430 height = 240 />


## 4. KITTI Example
### 4.1 KITTI Odometry (Stereo)
Download [KITTI Odometry dataset](http://www.cvlibs.net/datasets/kitti/eval_odometry.php) to YOUR_DATASET_FOLDER. Take sequences 00 for example,
Open two terminals, run vins and rviz respectively. 
(We evaluated odometry on KITTI benchmark without loop closure funtion)
```
    roslaunch vins vins_rviz.launch
    (optional) rosrun loop_fusion loop_fusion_node ~/catkin_ws/src/VINS-Fusion/config/kitti_odom/kitti_config00-02.yaml
    rosrun vins kitti_odom_test ~/catkin_ws/src/VINS-Fusion/config/kitti_odom/kitti_config00-02.yaml YOUR_DATASET_FOLDER/sequences/00/ 
```
### 4.2 KITTI GPS Fusion (Stereo + GPS)
Download [KITTI raw dataset](http://www.cvlibs.net/datasets/kitti/raw_data.php) to YOUR_DATASET_FOLDER. Take [2011_10_03_drive_0027_synced](https://s3.eu-central-1.amazonaws.com/avg-kitti/raw_data/2011_10_03_drive_0027/2011_10_03_drive_0027_sync.zip) for example.
Open three terminals, run vins, global fusion and rviz respectively. 
Green path is VIO odometry; blue path is odometry under GPS global fusion.
```
    roslaunch vins vins_rviz.launch
    rosrun vins kitti_gps_test ~/catkin_ws/src/VINS-Fusion/config/kitti_raw/kitti_10_03_config.yaml YOUR_DATASET_FOLDER/2011_10_03_drive_0027_sync/ 
    rosrun global_fusion global_fusion_node
```

<img src="https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/support_files/image/kitti.gif" width = 430 height = 240 />

## 5. VINS-Fusion on car demonstration
Download [car bag](https://drive.google.com/open?id=10t9H1u8pMGDOI6Q2w2uezEq5Ib-Z8tLz) to YOUR_DATASET_FOLDER.
Open four terminals, run vins odometry, visual loop closure(optional), rviz and play the bag file respectively. 
Green path is VIO odometry; red path is odometry under visual loop closure.
```
    roslaunch vins vins_rviz.launch
    rosrun vins vins_node ~/catkin_ws/src/VINS-Fusion/config/vi_car/vi_car.yaml 
    (optional) rosrun loop_fusion loop_fusion_node ~/catkin_ws/src/VINS-Fusion/config/vi_car/vi_car.yaml 
    rosbag play YOUR_DATASET_FOLDER/car.bag
```

<img src="https://github.com/HKUST-Aerial-Robotics/VINS-Fusion/blob/master/support_files/image/car_gif.gif" width = 430 height = 240  />


## 6. Run with your devices 
VIO is not only a software algorithm, it heavily relies on hardware quality. For beginners, we recommend you to run VIO with professional equipment, which contains global shutter cameras and hardware synchronization.

### 6.1 Configuration file
Write a config file for your device. You can take config files of EuRoC and KITTI as the example. 

### 6.2 Camera calibration
VINS-Fusion support several camera models (pinhole, mei, equidistant). You can use [camera model](https://github.com/hengli/camodocal) to calibrate your cameras. We put some example data under /camera_models/calibrationdata to tell you how to calibrate.
```
cd ~/catkin_ws/src/VINS-Fusion/camera_models/camera_calib_example/
rosrun camera_models Calibrations -w 12 -h 8 -s 80 -i calibrationdata --camera-model pinhole
```

## 7. Docker Support
To further facilitate the building process, we add docker in our code. Docker environment is like a sandbox, thus makes our code environment-independent. To run with docker, first make sure [ros](http://wiki.ros.org/ROS/Installation) and [docker](https://docs.docker.com/install/linux/docker-ce/ubuntu/) are installed on your machine. Then add your account to `docker` group by `sudo usermod -aG docker $YOUR_USER_NAME`. **Relaunch the terminal or logout and re-login if you get `Permission denied` error**, type:
```
cd ~/catkin_ws/src/VINS-Fusion/docker
make build
```
Note that the docker building process may take a while depends on your network and machine. After VINS-Fusion successfully built, you can run vins estimator with script `run.sh`.
Script `run.sh` can take several flags and arguments. Flag `-k` means KITTI, `-l` represents loop fusion, and `-g` stands for global fusion. You can get the usage details by `./run.sh -h`. Here are some examples with this script:
```
# Euroc Monocualr camera + IMU
./run.sh ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml

# Euroc Stereo cameras + IMU with loop fusion
./run.sh -l ~/catkin_ws/src/VINS-Fusion/config/euroc/euroc_mono_imu_config.yaml

# KITTI Odometry (Stereo)
./run.sh -k ~/catkin_ws/src/VINS-Fusion/config/kitti_odom/kitti_config00-02.yaml YOUR_DATASET_FOLDER/sequences/00/

# KITTI Odometry (Stereo) with loop fusion
./run.sh -kl ~/catkin_ws/src/VINS-Fusion/config/kitti_odom/kitti_config00-02.yaml YOUR_DATASET_FOLDER/sequences/00/

#  KITTI GPS Fusion (Stereo + GPS)
./run.sh -kg ~/catkin_ws/src/VINS-Fusion/config/kitti_raw/kitti_10_03_config.yaml YOUR_DATASET_FOLDER/2011_10_03_drive_0027_sync/

```
In Euroc cases, you need open another terminal and play your bag file. If you need modify the code, simply re-run `./run.sh` with proper auguments after your changes.


## 8. Acknowledgements
We use [ceres solver](http://ceres-solver.org/) for non-linear optimization and [DBoW2](https://github.com/dorian3d/DBoW2) for loop detection, a generic [camera model](https://github.com/hengli/camodocal) and [GeographicLib](https://geographiclib.sourceforge.io/).

## 9. License
The source code is released under [GPLv3](http://www.gnu.org/licenses/) license.

We are still working on improving the code reliability. For any technical issues, please contact Tong Qin <qintonguavATgmail.com>.

For commercial inquiries, please contact Shaojie Shen <eeshaojieATust.hk>.
