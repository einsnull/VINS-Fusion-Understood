# VINS-Fusion 系统架构与模块概述

本文档从系统层面梳理 VINS-Fusion 的整体架构、各模块职责、数据流以及关键设计决策。

---

## 一、系统整体架构

VINS-Fusion 是一个紧耦合的视觉惯性里程计（VIO）系统，支持单目/双目与 IMU 的融合，并可选配回环检测和全局位姿图优化。

```
┌─────────────────────────────────────────────────────────────────┐
│                         VINS-Fusion 系统                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   图像输入    │  │   IMU 输入   │  │   GPS 输入   │          │
│  │ (Mono/Stereo)│  │   (200Hz)    │  │   (1Hz)      │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                  │
│  ┌──────▼───────┐  ┌──────▼───────┐         │                  │
│  │ FeatureTracker│  │  IMU Preintegration    │                  │
│  │   (前端)      │  │   (预积分器)            │                  │
│  └──────┬───────┘  └──────┬───────┘         │                  │
│         │                 │                 │                  │
│  ┌──────▼─────────────────▼───────┐         │                  │
│  │      VinsEstimator (后端)       │         │                  │
│  │  ┌─────────────────────────┐   │         │                  │
│  │  │   FeatureManager        │   │         │                  │
│  │  │   (特征点管理/三角化)    │   │         │                  │
│  │  └─────────────────────────┘   │         │                  │
│  │  ┌─────────────────────────┐   │         │                  │
│  │  │   Sliding Window BA     │   │         │                  │
│  │  │   (Ceres 优化)          │   │         │                  │
│  │  └─────────────────────────┘   │         │                  │
│  │  ┌─────────────────────────┐   │         │                  │
│  │  │   Marginalization       │   │         │                  │
│  │  │   (边缘化)              │   │         │                  │
│  │  └─────────────────────────┘   │         │                  │
│  └──────┬────────────────────────┘         │                  │
│         │                                   │                  │
│  ┌──────▼───────┐  ┌───────────────────────▼───────┐          │
│  │ Loop Fusion  │  │      Global Fusion            │          │
│  │ (回环检测)    │  │      (GPS/VIO 融合)           │          │
│  │  - DBoW2     │  │      - 全局位姿图优化          │          │
│  │  - 4DoF/6DoF │  │      - GPS 坐标转换            │          │
│  │    位姿图优化 │  │                               │          │
│  └──────┬───────┘  └───────────────┬───────────────┘          │
│         │                          │                          │
│  ┌──────▼──────────────────────────▼───────┐                  │
│  │           最终输出：位姿/轨迹/地图         │                  │
│  └─────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 二、核心模块详解

### 2.1 vins_estimator（核心估计器）

**位置**：`vins_estimator/`

**职责**：接收图像和 IMU 数据，执行特征追踪、IMU 预积分、滑窗 BA 优化，输出高频位姿估计。

#### 子模块：

| 子模块 | 文件位置 | 职责 |
|-------|---------|------|
| FeatureTracker | `src/featureTracker/` | 前端特征点追踪（光流+角点提取） |
| FeatureManager | `src/estimator/feature_manager.*` | 特征点管理、三角化、深度恢复 |
| VinsEstimator | `src/estimator/estimator.*` | 主估计器，滑窗优化、边缘化 |
| IMU Preintegration | `src/factor/integration_base.h` | IMU 预积分实现 |
| Optimization Factors | `src/factor/` | Ceres 优化因子定义 |
| Initialization | `src/initial/` | 视觉/惯性初始化模块 |

### 2.2 loop_fusion（回环检测与位姿图优化）

**位置**：`loop_fusion/`

**职责**：接收关键帧，进行回环检测，执行位姿图优化消除累积误差。

#### 核心组件：

| 组件 | 文件 | 职责 |
|-----|------|------|
| PoseGraph | `src/pose_graph.h/.cpp` | 位姿图管理、优化 |
| KeyFrame | `src/keyframe.h/.cpp` | 关键帧定义、BRIEF 描述子 |
| DBoW2 | `src/ThirdParty/DBoW/` | 词袋模型，用于回环检测 |
| DVision | `src/ThirdParty/DVision/` | BRIEF 描述子计算 |

#### 工作流程：

1. **关键帧接收**：从 vins_estimator 接收关键帧图像和位姿
2. **回环检测**：使用 DBoW2 词袋模型检测历史相似关键帧
3. **几何验证**：通过 BRIEF 描述子匹配进行几何验证
4. **位姿图优化**：
   - 4DoF 优化（x, y, z, yaw）：用于 IMU 模式（roll/pitch 由重力确定）
   - 6DoF 优化（x, y, z, roll, pitch, yaw）：用于纯视觉模式
5. **漂移校正**：计算并应用全局漂移修正

### 2.3 global_fusion（全局位姿图优化）

**位置**：`global_fusion/`

**职责**：融合 GPS 观测与 VIO 轨迹，进行全局位姿图优化。

#### 核心组件：

| 组件 | 文件 | 职责 |
|-----|------|------|
| GlobalOptimization | `src/globalOpt.h/.cpp` | 全局优化器 |
| GeographicLib | `src/ThirdParty/GeographicLib/` | GPS 坐标转换（WGS84 -> ENU） |

#### 工作流程：

1. **VIO 输入**：接收 VIO 输出的局部位姿
2. **GPS 输入**：接收 GPS 经纬度高程数据
3. **坐标转换**：使用 GeographicLib 将 GPS 转换为局部 ENU 坐标
4. **外参标定**：在线估计 VIO 坐标系到 GPS 坐标系的变换
5. **全局优化**：融合 VIO 和 GPS 约束进行位姿图优化

---

## 三、数据流详解

### 3.1 图像数据流

```
ROS Image Msg
    │
    ▼
┌─────────────┐
│ rosNodeTest │  (ROS 节点入口)
└──────┬──────┘
       │
       ▼
┌──────────────┐
│ inputImage() │  (图像入队)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ processMeasurements() │  (测量处理线程)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ FeatureTracker::trackImage() │  (光流追踪)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ processImage() │  (后端处理)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ runOptimization() │  (滑窗 BA)
└──────┬───────┘
       │
       ▼
   输出位姿
```

### 3.2 IMU 数据流

```
ROS IMU Msg
    │
    ▼
┌─────────────┐
│ rosNodeTest │  (ROS 节点入口)
└──────┬──────┘
       │
       ▼
┌──────────────┐
│ inputIMU() │  (IMU 入队 + 快速预测)
└──────┬───────┘
       │
       ├───▶ fastPredictIMU() ──▶ 高频里程计输出 (200Hz)
       │
       ▼
┌──────────────┐
│ processMeasurements() │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ processIMU() │  (预积分)
└──────┬───────┘
       │
       ▼
┌──────────────────┐
│ IntegrationBase │  (预积分器累积)
└──────┬───────────┘
       │
       ▼
┌──────────────┐
│ IMUFactor │  (Ceres 优化因子)
└──────────────┘
```

---

## 四、关键设计决策

### 4.1 紧耦合 vs 松耦合

VINS-Fusion 采用**紧耦合**设计：
- 视觉和 IMU 测量在同一个优化问题中联合优化
- 相比松耦合，精度更高，但计算量更大

### 4.2 滑动窗口 vs 全局地图

采用**滑动窗口**策略：
- 仅维护最近 N 帧（默认 WINDOW_SIZE=10）
- 旧帧通过边缘化转化为先验约束
- 平衡了计算效率和精度

### 4.3 逆深度参数化

特征点深度使用**逆深度**参数化：
- 更好的数值稳定性（远处点深度趋于无穷）
- 更适合高斯分布假设

### 4.4 中值积分 vs 欧拉积分

IMU 预积分采用**中值积分**：
- 比欧拉积分精度更高
- 计算量适中，适合实时系统

### 4.5 4DoF vs 6DoF 位姿图优化

回环检测使用 **4DoF 优化**（IMU 模式）：
- roll 和 pitch 由重力方向确定，无需优化
- 减少优化自由度，提高稳定性

---

## 五、系统参数配置

**核心文件**：`vins_estimator/src/estimator/parameters.h`

### 5.1 关键参数

| 参数 | 默认值 | 说明 |
|-----|-------|------|
| WINDOW_SIZE | 10 | 滑窗大小 |
| MAX_CNT | 150 | 最大追踪特征点数 |
| MIN_PARALLAX | 10 | 关键帧判定最小视差（像素） |
| SOLVER_TIME | 0.04 | 优化最大求解时间（秒） |
| NUM_ITERATIONS | 8 | 优化最大迭代次数 |
| ACC_N | 0.1 | 加速度计噪声 |
| GYR_N | 0.01 | 陀螺仪噪声 |
| ACC_W | 0.001 | 加速度计 bias 随机游走 |
| GYR_W | 0.0001 | 陀螺仪 bias 随机游走 |

### 5.2 运行模式配置

| 参数 | 取值 | 模式 |
|-----|------|------|
| STEREO | 0/1 | 单目/双目 |
| USE_IMU | 0/1 | 纯视觉/VIO |
| ESTIMATE_EXTRINSIC | 0/1/2 | 外参固定/微调/在线标定 |
| ESTIMATE_TD | 0/1 | 时间偏移固定/在线估计 |

---

## 六、线程模型

### 6.1 vins_estimator 线程

```
主线程 (ROS Spinner)
    ├── IMU 回调线程 ──▶ inputIMU() ──▶ 快速预测
    └── 图像回调线程 ──▶ inputImage() ──▶ 特征追踪

算法线程 (processMeasurements)
    └── 循环处理测量数据
        ├── processIMU() ──▶ 预积分
        └── processImage() ──▶ 滑窗优化
```

### 6.2 loop_fusion 线程

```
主线程
    └── 关键帧处理线程
        ├── 回环检测
        └── 位姿图优化 (独立优化线程)
```

### 6.3 global_fusion 线程

```
主线程
    └── GPS/VIO 融合优化线程
```

---

## 七、坐标系定义

### 7.1 IMU 坐标系

- 原点：IMU 中心
- x 轴：前进方向
- y 轴：左方
- z 轴：上方

### 7.2 相机坐标系

- 原点：相机光心
- x 轴：图像右方
- y 轴：图像下方
- z 轴：前方（光轴方向）

### 7.3 世界坐标系

- 初始化时由第一帧 IMU 姿态和重力方向确定
- z 轴：与重力方向相反（向上）
- x, y 轴：水平面内（yaw 被消除）

---

## 八、文件索引

### 8.1 核心算法文件

| 文件 | 说明 |
|-----|------|
| `vins_estimator/src/estimator/estimator.cpp` | 主估计器实现 |
| `vins_estimator/src/estimator/feature_manager.cpp` | 特征点管理 |
| `vins_estimator/src/featureTracker/feature_tracker.cpp` | 前端追踪 |
| `vins_estimator/src/factor/integration_base.h` | IMU 预积分 |
| `vins_estimator/src/factor/marginalization_factor.cpp` | 边缘化 |

### 8.2 初始化文件

| 文件 | 说明 |
|-----|------|
| `vins_estimator/src/initial/initial_sfm.cpp` | 纯视觉 SFM |
| `vins_estimator/src/initial/initial_alignment.cpp` | 视觉惯性对齐 |
| `vins_estimator/src/initial/initial_ex_rotation.cpp` | 外参标定 |
| `vins_estimator/src/initial/solve_5pts.cpp` | 五点法 |

### 8.3 配置文件

| 文件 | 说明 |
|-----|------|
| `config/euroc/euroc_stereo_imu_config.yaml` | EuRoC 双目+IMU 配置 |
| `config/euroc/euroc_mono_imu_config.yaml` | EuRoC 单目+IMU 配置 |
| `config/euroc/cam0_pinhole.yaml` | 相机内参 |
