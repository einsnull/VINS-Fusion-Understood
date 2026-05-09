# VINS-Fusion 视觉惯性对齐（Visual-Inertial Alignment）完整流程

本文档详细梳理 VINS-Fusion 中视觉与惯性数据对齐的完整流程，包括单目初始化、外参标定、陀螺仪 bias 估计、重力与尺度恢复等关键步骤。

---

## 一、整体流程概述

视觉惯性对齐是 VIO 系统初始化的核心环节，其目标是将视觉 SfM 恢复的**无尺度轨迹**与 IMU 预积分的**有尺度但无全局位姿**的测量进行对齐，估计出：

1. 陀螺仪 bias `Bg`
2. 重力方向 `g`
3. 尺度因子 `s`
4. 各帧速度 `V`
5. 相机-IMU 旋转外参 `Ric`

**参考**：对应崔华坤大佬文章中的同名部分，以及 VIO 课程第七讲。

---

## 二、旋转外参在线标定（CalibrationExRotation）

**核心文件**：
- `vins_estimator/src/initial/initial_ex_rotation.cpp`
- `vins_estimator/src/initial/initial_ex_rotation.h`

### 2.1 触发条件

当 `ESTIMATE_EXTRINSIC == 2`（无先验外参）时，系统进入在线标定模式：

```cpp
if(ESTIMATE_EXTRINSIC == 2) {
    if (frame_count != 0) {
        vector<pair<Vector3d, Vector3d>> corres = 
            f_manager_.getCorresponding(frame_count - 1, frame_count);
        if (init_extrin_rot_.CalibrationExRotation(
            corres, pre_integrations_[frame_count]->delta_q, calibed_Rot_IC)) {
            R_IC_[0] = calibed_Rot_IC;
            ESTIMATE_EXTRINSIC = 1; // 标定完成，后续优化围绕先验
        }
    }
}
```

### 2.2 标定原理

利用**手眼标定**思想：

$$R_c^{k,k+1} \cdot R_{ic} = R_{ic} \cdot R_{imu}^{k,k+1}$$

其中：
- $R_c^{k,k+1}$：通过视觉本质矩阵分解得到的相机相对旋转
- $R_{imu}^{k,k+1}$：IMU 预积分得到的相对旋转
- $R_{ic}$：待求的相机-IMU 旋转外参

### 2.3 求解过程

1. **视觉相对旋转**：通过 8-point 算法求本质矩阵 E，SVD 分解得到 4 组 (R,t)，通过三角化测试选择正确解
2. **构建约束方程**：将四元数形式的旋转约束转化为线性方程 `A x = 0`
3. **SVD 求解**：对 A 做 SVD，取最小奇异值对应的右奇异向量作为四元数解
4. **收敛判断**：当 frame_count >= WINDOW_SIZE 且次小奇异值 > 0.25 时，认为标定成功

---

## 三、单目视觉初始化（initialStructure）

**核心文件**：`vins_estimator/src/estimator/estimator.cpp`

### 3.1 IMU 可观测性检查

计算相邻帧之间 IMU 预积分的加速度方差，判断是否有足够运动激励：

```cpp
// 计算平均加速度
Vector3d aver_g = sum_g * 1.0 / (num_frames - 1);
// 计算方差
var = sqrt(var / (num_frames - 1));
if(var < 0.25) {
    LOG(INFO) << "IMU excitation not enough!";
}
```

### 3.2 全局 SfM（GlobalSFM）

**核心文件**：`vins_estimator/src/initial/initial_sfm.cpp`

1. **选择参考帧对**：在滑窗中搜索与最新帧具有足够视差（>30 像素）且共视特征点 >20 的帧
2. **5-point 算法求相对位姿**：`MotionEstimator::solveRelativeRT()` 通过 5-point 算法求解相对旋转和平移
3. **三角化初始点**：利用参考帧对三角化共视特征点
4. **PnP 扩展**：逐帧进行 PnP，扩展已恢复的结构
5. **BA 优化**：对所有帧位姿和 3D 点进行 Bundle Adjustment

### 3.3 非关键帧 PnP

对于滑窗中不在关键帧集合中的帧，使用 SfM 恢复的 3D 点进行 PnP，得到其在世界坐标系下的位姿。

---

## 四、视觉惯性对齐（visualInitialAlign）

**核心文件**：
- `vins_estimator/src/estimator/estimator.cpp`
- `vins_estimator/src/initial/initial_alignment.cpp`
- `vins_estimator/src/initial/initial_alignment.h`

### 4.1 整体步骤

根据 VIO 课程第七讲，分为 5 步：

1. 估计旋转外参（已完成，见第二节）
2. 估计陀螺仪 bias
3. 估计重力方向、速度、尺度初始值
4. 对重力加速度进一步优化
5. 将轨迹对齐到世界坐标系

### 4.2 陀螺仪 Bias 估计（solveGyroscopeBias）

**原理**：视觉 SfM 得到的帧间旋转 $q_{ij}^{vis}$ 应该与 IMU 预积分旋转 $q_{ij}^{imu}$ 一致，差异来源于陀螺仪 bias。

**优化目标**：

$$\min_{\delta B_g} \sum_{i} \| 2 \left[ (q_{ij}^{imu} \otimes \delta q)^{-1} \otimes q_{ij}^{vis} \right]_{vec} \|^2$$

其中 $\delta q$ 由 bias 修正得到：

$$\delta q \approx \begin{bmatrix} 1 \\ \frac{1}{2} J_{bg} \cdot \delta B_g \end{bmatrix}$$

**实现**：

```cpp
// 构建正规方程 A * delta_bg = b
A += tmp_A.transpose() * tmp_A;
b += tmp_A.transpose() * tmp_b;
delta_bg = A.ldlt().solve(b);

// 更新 bias
for (int i = 0; i <= WINDOW_SIZE; i++) {
    _Bgs[i] += delta_bg;
}

// 用新 bias 重新传播预积分
for (...) {
    frame_j->second.pre_integration->repropagate(Vector3d::Zero(), _Bgs[0]);
}
```

### 4.3 线性对齐：速度、重力、尺度（LinearAlignment）

**状态量**：

$$X = [v_0, v_1, ..., v_n, g, s]^T$$

其中：
- $v_i$：第 i 帧的速度（3维）
- $g$：重力向量（3维）
- $s$：尺度因子（1维）

**约束方程**（每对相邻帧提供 6 个方程）：

**位置约束**：

$$s \cdot p_j = s \cdot p_i + v_i \cdot \Delta t + \frac{1}{2} g \cdot \Delta t^2 + R_i \cdot \Delta p_{ij}^{imu}$$

**速度约束**：

$$v_j = v_i + g \cdot \Delta t + R_i \cdot \Delta v_{ij}^{imu}$$

**实现**：构建最小二乘问题 `A x = b`，使用 LDLT 求解。

**收敛判断**：
- 估计的重力模长与 G 的差 < 0.5
- 尺度因子 s > 0

### 4.4 重力细化（RefineGravity）

**问题**：直接估计的 3D 重力向量有 3 个自由度，但实际重力方向只有 2 个自由度（模长固定为 G）。

**方法**：在重力方向的切空间上进行优化。

1. 初始化重力方向 $g_0 = \|G\| \cdot \frac{g}{\|g\|}$
2. 构建切空间基底 `TangentBasis(g0)`，得到两个正交方向 $b, c$
3. 参数化重力为：$g = g_0 + [b, c] \cdot \delta g$
4. 迭代 4 次，每次求解 $\delta g$ 并更新 $g_0$

**状态量变为**：

$$X = [v_0, v_1, ..., v_n, \delta g_x, \delta g_y, s]^T$$

### 4.5 轨迹对齐到世界坐标系

**步骤**：

1. **更新滑窗状态**：将 SfM 恢复的位姿赋值给滑窗状态量
2. **尺度变换**：将所有位置乘以尺度因子 s
3. **重新传播预积分**：用估计的 bias 重新计算所有预积分
4. **速度赋值**：从优化结果中提取各帧速度
5. **重力对齐**：
   - 计算将估计重力旋转到 [0,0,G] 的旋转矩阵 $R_0 = g2R(Grav)$
   - 消除 yaw 自由度：$R_0 = ypr2R([-yaw, 0, 0]) \cdot R_0$
   - 将所有位姿、速度旋转到对齐后的世界坐标系
6. **重新三角化**：用对齐后的位姿重新三角化所有特征点深度

```cpp
// 尺度恢复
for (int i = frame_count; i >= 0; i--)
    Ps[i] = s * Ps[i] - Rs[i] * TIC[0] - (s * Ps[0] - Rs[0] * TIC[0]);

// 速度赋值
Vs[kv] = frame_i->second.R * x.segment<3>(kv * 3);

// 重力对齐
Matrix3d R0 = Utility::g2R(Grav_);
double yaw = Utility::R2ypr(R0 * Rs[0]).x();
R0 = Utility::ypr2R(Eigen::Vector3d{-yaw, 0, 0}) * R0;
Grav_ = R0 * Grav_;

// 统一旋转
for (int i = 0; i <= frame_count; i++) {
    Ps[i] = rot_diff * Ps[i];
    Rs[i] = rot_diff * Rs[i];
    Vs[i] = rot_diff * Vs[i];
}
```

---

## 五、双目+IMU 初始化（简化流程）

对于双目方案，初始化流程有所简化：

1. **PnP 初始化帧位姿**：`f_manager_.initFramePoseByPnP()`
2. **双目三角化**：`f_manager_.triangulate()` 利用双目直接恢复深度
3. **陀螺仪 bias 估计**：`solveGyroscopeBias()`
4. **滑窗 BA 优化**：`runOptimization()`

由于双目可以直接恢复尺度，无需像单目那样进行复杂的尺度估计。

---

## 六、关键类说明

### InitializeExtrinRotation
在线标定相机-IMU 旋转外参，基于手眼标定原理。

### MotionEstimator
通过 5-point 算法求解两帧之间的相对位姿。

### GlobalSFM
全局 Structure from Motion，恢复滑窗内所有帧的位姿和特征点 3D 位置。

### ImageFrame
VINS 层的处理单元，包含图像帧特征点、IMU 预积分、位姿等信息。

### IntegrationBase
IMU 预积分器，累积两帧之间的 IMU 测量，输出相对运动约束。
