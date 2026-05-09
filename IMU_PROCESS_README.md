# VINS-Fusion IMU 数据处理完整流程

本文档详细梳理 VINS-Fusion 中 IMU 数据从接收、缓存、预积分到参与滑窗优化的完整处理流水线。

---

## 一、数据入口与缓存

### 1.1 ROS 回调接收

IMU 数据通过 ROS 订阅进入系统：

- **文件**：`vins_estimator/src/rosNodeTest.cpp`（第 140-150 行）
- `ImuCallback` 接收 `sensor_msgs/Imu` 消息，提取时间戳、线加速度、角速度
- 调用 `vins_estimator_->inputIMU(t, acc, gyr)` 将数据送入估计器

### 1.2 入队与高频预测

在 `VinsEstimator::inputIMU()`（`estimator.cpp` 第 173-189 行）中：

1. **加锁入队**：`accBuf` 和 `gyrBuf` 是两个 `std::queue`，缓存原始 IMU 观测
2. **高频快速预测**：如果系统已进入常规 VIO 阶段（`flag_solver_type_ == NON_LINEAR`），每收到一个 IMU 就立即执行一次 `fastPredictIMU()`，用于输出高频里程计

```cpp
void VinsEstimator::inputIMU(double t, const Vector3d &linearAcc, const Vector3d &angularVel) {
    mtxBuf.lock();
    accBuf.push(make_pair(t, linearAcc));
    gyrBuf.push(make_pair(t, angularVel));
    mtxBuf.unlock();

    if (flag_solver_type_ == NON_LINEAR) {
        mtxPropagate.lock();
        fastPredictIMU(t, linearAcc, angularVel);
        if (handle_latest_odom_) {
            handle_latest_odom_(latest_P_, latest_Q_, latest_V_, t);
        }
        mtxPropagate.unlock();
    }
}
```

---

## 二、高频快速预测（fastPredictIMU）

**目的**：在图像帧到来之前，用 IMU 递推输出最新位姿，满足高频输出需求（如 200Hz）。

**实现**：`estimator.cpp` 第 1441-1453 行

采用**中值积分法**（Mid-point Integration）：

- 角速度取前后两帧平均：`un_gyr = 0.5 * (gyr_0 + gyr_1) - Bg`
- 姿态更新：`Q = Q * deltaQ(un_gyr * dt)`
- 加速度先转到世界系，再取平均：`un_acc = 0.5 * (un_acc_0 + un_acc_1)`
- 位置和速度更新：
  - `P = P + dt * V + 0.5 * dt^2 * un_acc`
  - `V = V + dt * un_acc`

> 注意：这里使用的是**最新优化后的状态**（`latest_P_`, `latest_Q_`, `latest_V_`, `latest_Ba_`, `latest_Bg_`）作为积分起点。

---

## 三、图像帧触发的主流程（processMeasurements）

当图像帧到来时，在 `processMeasurements()`（`estimator.cpp` 第 244-349 行）中：

### 3.1 数据对齐

- 等待 IMU 缓存覆盖当前图像时间戳
- 调用 `getIMUInterval(prev_time_, curr_time_, accVector, gyrVector)` 提取两帧图像之间的**所有 IMU 数据**

### 3.2 初始化第一帧姿态（静止假设）

如果尚未初始化第一帧姿态，调用 `initFirstIMUPose()`（`estimator.cpp` 第 388-408 行）：

- 计算这段 IMU 的平均加速度 `aveAcc`
- 利用重力方向确定初始滚转和俯仰角：`R0 = g2R(aveAcc)`
- 偏航角置零

### 3.3 逐 IMU 执行 processIMU

这是 IMU 处理的**核心步骤**，在 `estimator.cpp` 第 410-442 行：

```cpp
void VinsEstimator::processIMU(double t, double dt,
                               const Vector3d& _linearAcc,
                               const Vector3d& _angularVelo);
```

**做两件事**：

#### （1）IMU 预积分（IntegrationBase）

- 每个滑窗帧对应一个 `pre_integrations_[frame_count]` 对象
- 调用 `pre_integrations_[frame_count]->push_back(dt, acc, gyr)` 累积预积分量
- 同时维护 `tmp_pre_integration_`（用于下一帧图像的预积分器）

#### （2）常规积分递推（作为滑窗最新帧的预测）

- 用中值积分更新滑窗最新帧的状态 `Rs[j]`, `Ps[j]`, `Vs[j]`
- 这是为了给后续视觉优化提供一个**良好的初始值**

---

## 四、IMU 预积分核心实现

**核心类**：`IntegrationBase`，定义于 `vins_estimator/src/factor/integration_base.h`

### 4.1 状态变量

预积分维护以下增量（相对于线性化点）：

| 变量 | 含义 |
|------|------|
| `delta_p` | 位置预积分增量 |
| `delta_q` | 姿态预积分增量（四元数） |
| `delta_v` | 速度预积分增量 |
| `linearized_ba` / `linearized_bg` | 线性化点处的加速度计/陀螺仪 bias |
| `jacobian` (15x15) | 预积分对状态量的雅可比 |
| `covariance` (15x15) | 预积分噪声协方差 |
| `sum_dt` | 累积时间 |

### 4.2 中值积分（midPointIntegration）

`integration_base.h` 第 74-171 行

**运动学递推**：

```
un_acc_0 = delta_q * (acc_0 - linearized_ba)
un_gyr   = 0.5 * (gyr_0 + gyr_1) - linearized_bg
delta_q  = delta_q * Quaternion(1, un_gyr*dt/2)
un_acc_1 = delta_q * (acc_1 - linearized_ba)
un_acc   = 0.5 * (un_acc_0 + un_acc_1)

delta_p = delta_p + delta_v*dt + 0.5*un_acc*dt^2
delta_v = delta_v + un_acc*dt
```

**噪声传播**：

- 构造状态转移矩阵 `F` (15x15) 和噪声输入矩阵 `V` (15x18)
- 协方差更新：`covariance = F * covariance * F^T + V * noise * V^T`
- 雅可比更新：`jacobian = F * jacobian`

> 这里 `noise` 是 18x18 的噪声矩阵，包含加速度计/陀螺仪的测量噪声（`ACC_N`, `GYR_N`）和随机游走（`ACC_W`, `GYR_W`）。

### 4.3 Bias 变化后的重传播（repropagate）

当优化后 bias 发生变化时，调用 `repropagate()`（`integration_base.h` 第 52-64 行）：

- 重置预积分量和雅可比/协方差
- 用新的 `linearized_ba`, `linearized_bg` 重新遍历所有 IMU 数据

---

## 五、IMU 因子在优化中的使用

### 5.1 残差定义（IMUFactor）

**文件**：`vins_estimator/src/factor/imu_factor.h`

继承自 `ceres::SizedCostFunction<15, 7, 9, 7, 9>`：

- 残差维度：15（位置3 + 姿态3 + 速度3 + bias_acc 3 + bias_gyr 3）
- 参数块：第 i 帧 pose(7) + speed_bias(9)，第 j 帧 pose(7) + speed_bias(9)

### 5.2 残差计算（evaluate）

`integration_base.h` 第 226-258 行

利用雅可比对 bias 变化进行一阶修正：

```cpp
dba = Bai - linearized_ba
dbg = Bgi - linearized_bg

corrected_delta_q = delta_q * deltaQ(dq_dbg * dbg)
corrected_delta_v = delta_v + dv_dba*dba + dv_dbg*dbg
corrected_delta_p = delta_p + dp_dba*dba + dp_dbg*dbg
```

**15维残差**：

```
r[0:3]  = Qi.inverse() * (0.5*G*sum_dt^2 + Pj - Pi - Vi*sum_dt) - corrected_delta_p
r[3:6]  = 2 * (corrected_delta_q.inverse() * (Qi.inverse() * Qj)).vec()
r[6:9]  = Qi.inverse() * (G*sum_dt + Vj - Vi) - corrected_delta_v
r[9:12] = Baj - Bai
r[12:15]= Bgj - Bgi
```

### 5.3 信息矩阵（sqrt_info）

```cpp
sqrt_info = LLT(covariance.inverse()).matrixL().transpose();
residual = sqrt_info * residual;
```

即使用预积分协方差的逆作为信息矩阵，对残差进行加权。

### 5.4 雅可比矩阵

在 `imu_factor.h` 第 96-180 行中手动推导了 4 个参数块的雅可比：

- `jacobian_pose_i` (15x7)：第 i 帧 pose
- `jacobian_speedbias_i` (15x9)：第 i 帧 speed + bias
- `jacobian_pose_j` (15x7)：第 j 帧 pose
- `jacobian_speedbias_j` (15x9)：第 j 帧 speed + bias

---

## 六、优化与边缘化中的 IMU

在 `runOptimization()`（`estimator.cpp` 第 822-1130 行）中：

### 6.1 添加 IMU 因子

```cpp
for (int i = 0; i < frame_count; i++) {
    int j = i + 1;
    if (pre_integrations_[j]->sum_dt > 10.0) continue;
    IMUFactor* imu_factor = new IMUFactor(pre_integrations_[j]);
    problem.AddResidualBlock(imu_factor, NULL,
        para_Pose_[i], para_Speed_Bias_[i],
        para_Pose_[j], para_Speed_Bias_[j]);
}
```

### 6.2 边缘化最老帧时的 IMU 处理

当边缘化最老帧时（`MARGIN_OLD`）：

- 与最老帧关联的 IMU 预积分因子（`pre_integrations_[1]`，即帧0到帧1）被收集到边缘化器中
- drop set 为 `{0, 1}`（帧0的 pose 和 speed_bias）
- 边缘化后，这些信息被压缩成先验因子，带入下一轮优化

当边缘化次新帧时（`MARGIN_SECOND_NEW`）：

- 视觉约束直接丢弃
- IMU 预积分器不重置，继续累积到下一帧

---

## 七、滑动窗口中的 IMU 状态传递

在 `slideWindow()`（`estimator.cpp` 第 1170-1220 行）中：

- 边缘化最老帧时，`pre_integrations_[i]` 整体前移（`swap`）
- 最新帧的预积分器重置，以当前 IMU 为起点新建 `IntegrationBase`

---

## 八、完整流程图

```
ROS IMU 消息
    |
    v
ImuCallback ---> inputIMU()
    |                |
    |                |---> 入队 accBuf/gyrBuf
    |                |---> fastPredictIMU() ---> 高频里程计输出
    |
    v
图像帧触发 processMeasurements()
    |
    |---> getIMUInterval() 提取帧间所有 IMU
    |
    |---> initFirstIMUPose() (首次)
    |
    |---> 对每个 IMU 调用 processIMU()
    |           |
    |           |---> pre_integrations_[j]->push_back() ---> 预积分
    |           |         |
    |           |         |---> midPointIntegration()
    |           |               |---> delta_p, delta_q, delta_v 更新
    |           |               |---> jacobian 更新
    |           |               |---> covariance 传播
    |           |
    |           |---> 中值积分更新 Rs/Ps/Vs（预测）
    |
    v
processImage()
    |
    |---> triangulate() (用预测位姿初始化特征深度)
    |
    |---> runOptimization()
    |         |
    |         |---> 添加 IMUFactor 到 Ceres (pre_integrations_[j])
    |         |---> 添加视觉重投影因子
    |         |---> 求解
    |         |---> CeresParamToState()
    |
    v
slideWindow() ---> 预积分器前移/重置
    |
    v
updateLatestStates() ---> 同步 latest_* 状态
```

---

## 九、关键设计要点总结

| 设计点 | 说明 |
|--------|------|
| **双线程缓存** | IMU 高频入队，图像帧触发批量处理 |
| **中值积分** | 同时用于快速预测和预积分，兼顾精度与效率 |
| **预积分相对量** | 将 IMU 积分表示为相对位姿增量，避免重复积分 |
| **Bias 一阶修正** | 利用雅可比快速修正 bias 变化，避免频繁重传播 |
| **15维残差** | 同时约束 P、Q、V、Ba、Bg，实现紧耦合 |
| **信息矩阵加权** | 使用协方差逆的平方根对残差归一化 |
| **边缘化保留** | 最老帧的 IMU 约束通过边缘化转化为先验 |

---

## 十、核心文件索引

| 文件 | 作用 |
|------|------|
| `vins_estimator/src/rosNodeTest.cpp` | ROS 节点入口，IMU/图像回调 |
| `vins_estimator/src/estimator/estimator.cpp` | 主估计器，数据流调度 |
| `vins_estimator/src/estimator/estimator.h` | 估计器类定义 |
| `vins_estimator/src/factor/integration_base.h` | IMU 预积分核心类 |
| `vins_estimator/src/factor/imu_factor.h` | Ceres IMU 因子（残差+雅可比） |
