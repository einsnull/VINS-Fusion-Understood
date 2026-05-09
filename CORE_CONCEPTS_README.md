# VINS-Fusion 核心重点与技术本质

本文档从算法原理和工程实现两个维度，提炼 VINS-Fusion 最核心的技术要点，帮助理解其设计精髓。

---

## 一、核心公式：VINS 的灵魂

VINS 的全部设计可以归结为一句话：

> **通过 IMU 预积分建立高频运动约束，通过滑窗 BA 联合优化视觉和惯性测量，通过边缘化维持固定计算复杂度，最终解决单目视觉的尺度不可观测问题。**

这三个技术环环相扣，缺一不可：

```
IMU 预积分 ──▶ 提供帧间运动约束（有尺度，但漂移快）
    │
    ▼
滑窗 BA ◀──── 视觉重投影约束（无尺度，但长期稳定）
    │
    ▼
边缘化 ────▶ 维持固定计算量，保留历史信息
```

---

## 二、算法核心一：IMU 预积分（Pre-integration）

### 2.1 为什么需要预积分？

IMU 输出频率通常为 200Hz~1000Hz，而相机只有 10Hz~30Hz。直接将每帧 IMU 数据作为独立约束加入优化问题，会导致：
- 优化变量爆炸
- 计算复杂度不可控
- 数值稳定性差

### 2.2 预积分的核心思想

在两帧图像 $i$ 和 $j$ 之间，将高频 IMU 测量**积分累积**为一个**相对运动约束**：

$$\Delta p_{ij} = \iint_{t_i}^{t_j} R_i^t (a_t - b_a) \, dt^2$$

$$\Delta v_{ij} = \int_{t_i}^{t_j} R_i^t (a_t - b_a) \, dt$$

$$\Delta q_{ij} = \int_{t_i}^{t_j} \frac{1}{2} \Omega(\omega_t - b_\omega) q_i^t \, dt$$

### 2.3 预积分的三大特性

| 特性 | 说明 | 意义 |
|-----|------|------|
| **与初始位姿无关** | 预积分结果仅依赖于 bias，不依赖于第 $i$ 帧的绝对位姿 | 可以在优化中高效复用 |
| **bias 线性修正** | 当 bias 估计变化时，通过雅可比进行一阶修正 | 避免重新积分 |
| **协方差传播** | 同时传播 IMU 噪声的累积效应 | 量化不确定性，指导优化权重 |

### 2.4 中值积分实现

VINS 采用中值积分提高精度：

```cpp
// 角速度中值
Vector3d un_gyr = 0.5 * (gyr_0 + gyr_1) - linearized_bg;
// 旋转更新
result_delta_q = delta_q * Quaterniond(1, un_gyr * dt / 2);
// 加速度中值
Vector3d un_acc = 0.5 * (delta_q * (acc_0 - ba) + result_delta_q * (acc_1 - ba));
// 位置和速度更新
result_delta_p = delta_p + delta_v * dt + 0.5 * un_acc * dt * dt;
result_delta_v = delta_v + un_acc * dt;
```

**文件**：[integration_base.h](vins_estimator/src/factor/integration_base.h)

---

## 三、算法核心二：滑动窗口 Bundle Adjustment

### 3.1 优化变量

$$\mathcal{X} = [x_0, x_1, ..., x_n, \lambda_0, \lambda_1, ..., \lambda_m, x_{ic}, t_d]$$

其中每帧状态：

$$x_k = [p_k, q_k, v_k, b_a, b_g]$$

- $p_k, q_k$：位姿（位置+旋转）
- $v_k$：速度
- $b_a, b_g$：加速度计和陀螺仪 bias
- $\lambda$：特征点逆深度
- $x_{ic}$：相机-IMU 外参
- $t_d$：传感器时间偏移

### 3.2 优化目标

$$\min_{\mathcal{X}} \left\{ \sum_{i} \|r_{IMU}\|_{\Sigma_{IMU}}^2 + \sum_{j} \|r_{VIS}\|_{\Sigma_{VIS}}^2 + \|r_{prior}\|_{\Sigma_{prior}}^2 \right\}$$

### 3.3 三种视觉重投影因子

| 因子类型 | 场景 | 残差维度 | 涉及变量 |
|---------|------|---------|---------|
| `ProjectionTwoFrameOneCamFactor` | 单目：特征点在帧 $i$ 和帧 $j$ 的左目 | 2D | Pose_i, Pose_j, ExPose, 逆深度, Td |
| `ProjectionTwoFrameTwoCamFactor` | 双目：特征点在帧 $i$ 左目和帧 $j$ 右目 | 2D | Pose_i, Pose_j, ExPose_left, ExPose_right, 逆深度, Td |
| `ProjectionOneFrameTwoCamFactor` | 双目：特征点在同一帧的左右目 | 2D | ExPose_left, ExPose_right, 逆深度, Td |

### 3.4 鲁棒核函数

所有视觉因子使用 **Huber Loss**：

$$\rho(e) = \begin{cases} \frac{1}{2}e^2 & |e| \leq \delta \\ \delta(|e| - \frac{1}{2}\delta) & |e| > \delta \end{cases}$$

降低外点对优化的影响。

**文件**：[estimator.cpp](vins_estimator/src/estimator/estimator.cpp) 中的 `runOptimization()`

---

## 四、算法核心三：边缘化（Marginalization）

### 4.1 为什么需要边缘化？

滑动窗口固定了窗口大小（如 10 帧），当新帧到来时必须移除旧帧。直接丢弃会丢失信息，边缘化通过**舒尔补**将旧帧信息压缩为先验约束。

### 4.2 舒尔补的本质

对于高斯分布的联合概率：

$$\begin{bmatrix} x_1 \\ x_2 \end{bmatrix} \sim \mathcal{N}\left( \begin{bmatrix} \mu_1 \\ \mu_2 \end{bmatrix}, \begin{bmatrix} \Sigma_{11} & \Sigma_{12} \\ \Sigma_{21} & \Sigma_{22} \end{bmatrix} \right)$$

边缘化 $x_1$ 后，$x_2$ 的先验为：

$$\Sigma_{2|1} = \Sigma_{22} - \Sigma_{21}\Sigma_{11}^{-1}\Sigma_{12}$$

### 4.3 两种边缘化策略

| 策略 | 触发条件 | 效果 |
|-----|---------|------|
| **边缘化最老帧** | 当前帧为关键帧（视差大） | 保留次新帧，丢弃最老帧，适合新场景探索 |
| **边缘化次新帧** | 当前帧非关键帧（视差小） | 保留最老帧，丢弃次新帧，适合静止或匀速运动 |

### 4.4 边缘化因子的复用

上一轮边缘化产生的先验因子，若与当前被边缘化帧关联，需要被**重新线性化**并纳入本轮边缘化。

**文件**：[marginalization_factor.h](vins_estimator/src/factor/marginalization_factor.h)

---

## 五、系统核心：视觉惯性对齐（初始化）

### 5.1 单目视觉的尺度问题

纯视觉 SfM 恢复的轨迹：$P_{vis} = s \cdot P_{true}$，尺度 $s$ 不可观测。

IMU 测量提供加速度：$a = R(a_{meas} - b_a) + g$，包含真实的尺度信息。

### 5.2 对齐的核心方程

**位置约束**（来自 IMU 预积分）：

$$s \cdot p_j = s \cdot p_i + v_i \Delta t + \frac{1}{2} g \Delta t^2 + R_i \Delta p_{ij}^{imu}$$

**速度约束**：

$$v_j = v_i + g \Delta t + R_i \Delta v_{ij}^{imu}$$

### 5.3 初始化五步法

| 步骤 | 操作 | 解决的问题 |
|-----|------|-----------|
| 1 | 旋转外参标定 | $R_{ic}$（手眼标定） |
| 2 | 陀螺仪 bias 估计 | $b_g$（视觉-IMU 旋转一致性） |
| 3 | 线性对齐 | $v, g, s$（速度、重力、尺度） |
| 4 | 重力细化 | $g$（切空间优化，降维） |
| 5 | 轨迹对齐 | 将视觉坐标系对齐到世界坐标系 |

**文件**：[initial_alignment.cpp](vins_estimator/src/initial/initial_alignment.cpp)

---

## 六、工程核心：鲁棒性与实时性

### 6.1 特征点管理策略

| 策略 | 实现 | 目的 |
|-----|------|------|
| 追踪次数过滤 | 仅使用追踪 ≥4 次的特征 | 保证特征稳定性 |
| 外点剔除 | 重投影误差 > 3 像素剔除 | 降低错误观测影响 |
| 预测加速 | IMU 积分预测下一帧特征位置 | 加速光流收敛 |
| 均匀分布 | MASK 避免特征聚集 | 提高几何约束质量 |

### 6.2 关键帧策略

```cpp
// 快速判定（满足任一即为关键帧）
if (frame_count < 2 || last_track_num < 20 || 
    long_track_num < 40 || new_feature_num > 0.5 * last_track_num) {
    return true; // 关键帧
}

// 视差判定
if (parallax_sum / parallax_num >= MIN_PARALLAX) {
    return true; // 关键帧，边缘化最老帧
} else {
    return false; // 非关键帧，边缘化次新帧
}
```

### 6.3 实时性保障

| 机制 | 说明 |
|-----|------|
| 固定滑窗大小 | WINDOW_SIZE = 10，计算量不随时间增长 |
| 优化时间限制 | SOLVER_TIME = 40ms，超时强制终止 |
| 多线程加速 | 边缘化线性化使用 4 线程并行 |
| 高频 IMU 预测 | 图像间隙用 IMU 递推输出 200Hz 位姿 |

---

## 七、关键设计决策总结

| 设计点 | VINS 的选择 | 原因 |
|-------|------------|------|
| 耦合方式 | **紧耦合** | 精度更高，联合优化视觉和 IMU |
| 优化策略 | **滑动窗口 BA** | 平衡精度和计算量 |
| 深度参数化 | **逆深度** | 远处点数值稳定性更好 |
| IMU 积分 | **中值积分** | 精度高于欧拉，计算量适中 |
| 回环优化 | **4DoF 位姿图** | IMU 模式下 roll/pitch 由重力确定 |
| 外点处理 | **Huber Loss + 重投影剔除** | 鲁棒且高效 |

---

## 八、文件索引

### 核心算法文件

| 文件 | 核心内容 |
|-----|---------|
| `vins_estimator/src/factor/integration_base.h` | IMU 预积分实现 |
| `vins_estimator/src/factor/imu_factor.h` | IMU 预积分因子（Ceres） |
| `vins_estimator/src/estimator/estimator.cpp` | 滑窗 BA 优化、边缘化 |
| `vins_estimator/src/factor/marginalization_factor.h` | 边缘化实现 |
| `vins_estimator/src/initial/initial_alignment.cpp` | 视觉惯性对齐 |
| `vins_estimator/src/initial/initial_ex_rotation.cpp` | 旋转外参标定 |

### 前端文件

| 文件 | 核心内容 |
|-----|---------|
| `vins_estimator/src/featureTracker/feature_tracker.cpp` | 光流追踪、角点提取 |
| `vins_estimator/src/estimator/feature_manager.cpp` | 特征点管理、三角化 |

---

## 九、延伸阅读

- **VINS-Mono 论文**："VINS-Mono: A Robust and Versatile Monocular Visual-Inertial State Estimator"
- **IMU 预积分理论**："On-Manifold Preintegration for Real-Time Visual-Inertial Odometry"
- **崔华坤 VIO 课程**：视觉惯性对齐部分
