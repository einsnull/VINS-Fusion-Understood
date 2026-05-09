# VINS-Fusion 相机标定流程

本文档详细梳理 VINS-Fusion 中相机内参标定、外参标定以及在线外参估计的完整流程。

---

## 一、相机内参标定

### 1.1 支持的相机模型

VINS-Fusion 通过 `camodocal` 库支持多种相机模型：

| 相机模型 | 文件 | 适用场景 |
|---------|------|---------|
| 针孔模型（Pinhole） | `PinholeCamera.cc/h` | 普通相机 |
| 全针孔模型（PinholeFull） | `PinholeFullCamera.cc/h` | 广角相机 |
| Mei 模型（CataCamera） | `CataCamera.cc/h` | 鱼眼相机 |
| 等距模型（Equidistant） | `EquidistantCamera.cc/h` | 鱼眼相机 |
| Scaramuzza 模型 | `ScaramuzzaCamera.cc/h` | 鱼眼相机 |

### 1.2 标定工具

**核心文件**：`camera_models/src/intrinsic_calib.cc`

使用棋盘格进行标定：
1. 采集多组不同姿态的棋盘格图像
2. 检测角点并建立 2D-3D 对应关系
3. 通过非线性优化估计相机内参和畸变系数

### 1.3 标定结果格式

标定结果保存为 YAML 文件，例如：

```yaml
%YAML:1.0
---
model_type: PINHOLE
camera_name: camera
image_width: 752
image_height: 480
distortion_parameters:
   k1: -0.28340811
   k2: 0.07395907
   p1: 0.00019359
   p2: 1.76187114e-05
distortion_model: radtan
intrinsics:
   fx: 458.654
   fy: 457.296
   cx: 367.215
   cy: 248.375
```

### 1.4 内参读取

在 `FeatureTracker::readIntrinsicParameter()` 中：

```cpp
camodocal::CameraPtr camera = 
    CameraFactory::instance()->generateCameraFromYamlFile(calib_file[i]);
m_camera.push_back(camera);
```

---

## 二、相机-IMU 外参标定

### 2.1 外参定义

外参表示相机坐标系到 IMU 坐标系的变换：

- 旋转外参 $R_{ic}$：相机坐标系到 IMU 坐标系的旋转
- 平移外参 $t_{ic}$：相机坐标系原点在 IMU 坐标系中的位置

### 2.2 外参配置方式

在配置文件中通过 `estimate_extrinsic` 参数控制：

| 值 | 含义 |
|---|------|
| 0 | 外参已知且固定，直接使用配置文件中的值 |
| 1 | 外参有先验，优化时围绕先验值微调 |
| 2 | 外参完全未知，需要在线标定 |

### 2.3 在线旋转外参标定

**核心文件**：`vins_estimator/src/initial/initial_ex_rotation.cpp`

#### 2.3.1 触发条件

```cpp
if(ESTIMATE_EXTRINSIC == 2) {
    // 需要足够的旋转运动才能标定成功
    if (frame_count != 0) {
        // 获取相邻帧的共视特征点
        vector<pair<Vector3d, Vector3d>> corres = 
            f_manager_.getCorresponding(frame_count - 1, frame_count);
        // 尝试标定
        if (init_extrin_rot_.CalibrationExRotation(
            corres, pre_integrations_[frame_count]->delta_q, calibed_Rot_IC)) {
            R_IC_[0] = calibed_Rot_IC;
            ESTIMATE_EXTRINSIC = 1; // 标定完成
        }
    }
}
```

#### 2.3.2 标定原理

基于**手眼标定（Hand-Eye Calibration）**：

$$R_c^{k,k+1} \cdot R_{ic} = R_{ic} \cdot R_{imu}^{k,k+1}$$

其中：
- $R_c^{k,k+1}$：通过视觉本质矩阵分解得到的相机相对旋转
- $R_{imu}^{k,k+1}$：IMU 预积分得到的相对旋转
- $R_{ic}$：待求的相机-IMU 旋转外参

#### 2.3.3 求解步骤

1. **视觉相对旋转估计**：
   - 获取相邻帧共视特征点（>9 对）
   - 通过 8-point 算法求本质矩阵 E
   - SVD 分解 E 得到 4 组 (R,t) 候选
   - 通过三角化测试选择正确解（正深度点比例最高）

2. **构建约束方程**：
   将四元数形式的旋转约束转化为线性方程：
   
   $$(L - R) \cdot q_{ic} = 0$$
   
   其中 L 和 R 是由视觉旋转和 IMU 旋转构建的 4x4 矩阵。

3. **累积多帧约束**：
   
   $$A = \begin{bmatrix} huber_1(L_1 - R_1) \\ huber_2(L_2 - R_2) \\ \vdots \\ huber_n(L_n - R_n) \end{bmatrix}$$

4. **SVD 求解**：
   - 对 A 做 SVD：$A = U \Sigma V^T$
   - 取最小奇异值对应的右奇异向量作为四元数解
   - 转换为旋转矩阵：$R_{ic} = q^{-1}$

5. **收敛判断**：
   - 累积帧数 >= WINDOW_SIZE
   - 次小奇异值 > 0.25（表明约束足够）

#### 2.3.4 Huber 权重

根据视觉旋转与 IMU 旋转的角距离施加权重：

```cpp
double angular_distance = 180 / M_PI * r1.angularDistance(r2);
double huber = angular_distance > 5.0 ? 5.0 / angular_distance : 1.0;
```

角距离越大，权重越小，降低异常值的影响。

### 2.4 平移外参

VINS-Fusion 中平移外参 `T_IC_` 通常通过以下方式获得：

1. **离线标定**：使用 Kalibr 等工具预先标定
2. **配置文件读取**：从 YAML 配置文件中读取
3. **固定使用**：在优化中通常固定平移外参，主要优化旋转外参

---

## 三、时间偏移标定

### 3.1 时间偏移定义

`Td`：相机时间戳与 IMU 时间戳之间的偏移量

$$t_{imu} = t_{cam} + T_d$$

### 3.2 时间偏移估计

在滑窗优化中，时间偏移作为优化变量之一：

```cpp
problem.AddParameterBlock(para_Td_[0], 1);
if (!ESTIMATE_TD || Vs[0].norm() < 0.2) {
    problem.SetParameterBlockConstant(para_Td_[0]);
}
```

当速度足够大（>0.2 m/s）时，才启用时间偏移估计。

### 3.3 在视觉因子中的应用

视觉重投影因子中考虑了时间偏移导致的像素位置变化：

```cpp
// 根据时间偏移和像素速度，修正像素坐标
pts_i_comp = pts_i - velocity_i * td_i;
pts_j_comp = pts_j - velocity_j * td_j;
```

---

## 四、双目外参

### 4.1 双目配置

双目相机的外参包括：
- 左目内参：`camera0`（`R_IC_[0]`, `T_IC_[0]`）
- 右目内参：`camera1`（`R_IC_[1]`, `T_IC_[1]`）

### 4.2 双目外参读取

```cpp
// 读取两个相机的标定文件
readIntrinsicParameter({left_calib_file, right_calib_file});
// 自动判断为双目模式
flag_stereo_cam_ = true;
```

### 4.3 双目在优化中的使用

双目外参参与三种视觉因子的构建：

1. `ProjectionTwoFrameOneCamFactor`：单目帧间重投影
2. `ProjectionTwoFrameTwoCamFactor`：双目帧间重投影
3. `ProjectionOneFrameTwoCamFactor`：同一帧左右目重投影

---

## 五、标定文件示例

### 5.1 单目+IMU 配置

```yaml
%YAML:1.0

# 外参估计模式
estimate_extrinsic: 1   # 0:固定 1:有先验优化 2:在线标定

# 外参（相机到IMU）
extrinsicRotation: !!opencv-matrix
   rows: 3
   cols: 3
   dt: d
   data: [0, -1, 0,
          1, 0, 0,
          0, 0, 1]
extrinsicTranslation: !!opencv-matrix
   rows: 3
   cols: 1
   dt: d
   data: [-0.0216401454975,
          -0.064676986768,
           0.00981073058949]

# 时间偏移
td: 0.0
estimate_td: 1   # 是否在线估计时间偏移
```

### 5.2 双目配置

```yaml
%YAML:1.0

# 左目标定文件
cam0_calib: "left.yaml"
# 右目标定文件
cam1_calib: "right.yaml"

# 双目外参（右目到左目）
extrinsicRotation: !!opencv-matrix
   rows: 3
   cols: 3
   dt: d
   data: [...]
extrinsicTranslation: !!opencv-matrix
   rows: 3
   cols: 1
   dt: d
   data: [...]
```

---

## 六、标定质量评估

### 6.1 旋转外参标定质量

通过 SVD 奇异值判断：
- 次小奇异值 > 0.25：标定成功，约束充分
- 次小奇异值 < 0.25：需要更多旋转运动

### 6.2 重投影误差

优化后通过 `outliersRejection()` 计算重投影误差：
- `ave_err * FOCAL_LENGTH > 3`：标记为外点
- 外点过多说明标定参数或外参不准确

### 6.3 视觉-IMU 一致性

通过 `CalibrationExRotation` 中的角距离判断：
- 视觉旋转与 IMU 旋转的角距离应较小（<5°）
- 角距离过大说明标定结果不可靠
