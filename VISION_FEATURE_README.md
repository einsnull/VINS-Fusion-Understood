# VINS-Fusion 视觉特征点处理完整流程

本文档详细梳理 VINS-Fusion 中视觉特征点从检测到参与状态估计的完整处理流水线。

---

## 一、前端特征点追踪（FeatureTracker）

**核心文件**：
- `vins_estimator/src/featureTracker/feature_tracker.cpp`
- `vins_estimator/src/featureTracker/feature_tracker.h`

### 1.1 光流追踪（前后帧左目之间）

输入当前帧图像 `_img`（左目）和 `_img1`（右目，可选）：

1. **金字塔光流追踪**：若存在上一帧的 `prev_pts`，调用 `cv::calcOpticalFlowPyrLK` 进行追踪
2. **预测加速**：若外部给出了特征点位置预测（`has_predict_feats_`），使用 `OPTFLOW_USE_INITIAL_FLOW` 加速搜索；若追踪成功点数 < 10，放宽参数重新追踪
3. **反向校验**：若启用 `FLOW_BACK`，做反向校验（从当前帧追踪回上一帧，距离差 ≤ 0.5 像素才认为成功）
4. **边界过滤**：过滤掉不在图像边界内的点

### 1.2 补充新特征点

1. **设置掩码**：调用 `setCurrFeatureAsMask()`，将已有特征点位置设为 mask（避免重复提取）
2. **角点提取**：若当前特征点数量 < `MAX_CNT`，调用 `cv::goodFeaturesToTrack` 提取新的 Harris/MinEigenVal 角点
3. **ID 分配**：新特征点分配全局递增的 `feature_id`

### 1.3 去畸变与速度计算

- `undistortedPts()`：利用相机内参模型（camodocal）将像素坐标去畸变
- `ptsVelocity()`：计算去畸变后的像素在前后帧之间的移动速度

### 1.4 双目匹配（当前帧左右目之间）

若启用双目：
1. 对左目追踪到的特征点，在右目图像上做光流追踪（左→右）
2. 同样支持反向校验（右→左）
3. 右目特征点也去畸变、计算速度

### 1.5 输出数据结构

返回 `map<int, vector<pair<int, Matrix<double,7,1>>>>`：

```
{FeatureID -> [{CamID, [x, y, z, u, v, vx, vy]}, ...]}
```

其中：
- `x,y,z`：去畸变后的归一化平面坐标（z=1）
- `u,v`：原始像素坐标
- `vx,vy`：像素移动速度

---

## 二、特征点进入后端管理（FeatureManager）

**核心文件**：
- `vins_estimator/src/estimator/feature_manager.cpp`
- `vins_estimator/src/estimator/feature_manager.h`

### 2.1 特征点入容器（`addFeatureCheckParallax`）

- 将前端输出的特征点按 `FeatureID` 组织
- 每个特征点对应一个 `FeaturePerId`，内部持有 `vector<FeaturePerFrame>`
- `FeaturePerFrame` 保存该特征在某一帧中的：去畸变坐标、原始像素、速度、是否双目观测

### 2.2 关键帧判断

通过视差判断当前帧是否为关键帧：

1. **快速判定**（满足任一即关键帧）：
   - 滑窗未满
   - 追踪点数 < 20
   - 长追踪特征 < 40
   - 新特征占比 > 50%

2. **视差判定**：计算已有特征点在倒数第二帧和倒数第三帧之间的平均视差
   - 若平均视差 ≥ `MIN_PARALLAX`，判定为关键帧（边缘化最老帧）
   - 否则边缘化次新帧

---

## 三、特征点深度恢复（三角化）

**核心函数**：`FeatureManager::triangulate()`

### 3.1 双目三角化

- 若特征点在首帧就被左右目同时观测到，直接用双目视觉三角化
- 利用两相机的位姿（`Ps + Rs * tic/ric`）和像素坐标，DLT 求解 3D 点

### 3.2 单目/运动三角化

- 若特征点被至少 2 帧观测到，用相邻两帧做运动三角化
- 若特征点被 ≥4 帧观测到，用所有共视帧联合构建 SVD 最小二乘问题，估计深度

### 3.3 PnP 初始化帧位姿

- `initFramePoseByPnP()`：利用已有深度的 3D 特征点和当前帧 2D 观测，通过 OpenCV `solvePnP` 求解当前帧位姿
- 这在纯视觉或双目初始化时使用

---

## 四、滑窗优化中的特征点使用

**核心文件**：`vins_estimator/src/estimator/estimator.cpp`

### 4.1 构建视觉残差（`runOptimization`）

在 Ceres 优化问题中，仅使用追踪次数 ≥4 的"稳定特征点"：

| 因子类型 | 使用场景 | 优化变量 |
|---------|---------|---------|
| `ProjectionTwoFrameOneCamFactor` | 单目：特征点在两个不同帧的左目之间 | Pose_i, Pose_j, ExPose_left, 逆深度, Td |
| `ProjectionTwoFrameTwoCamFactor` | 双目：特征点在帧i左目和帧j右目之间 | Pose_i, Pose_j, ExPose_left, ExPose_right, 逆深度, Td |
| `ProjectionOneFrameTwoCamFactor` | 双目：特征点在同一帧的左右目之间 | ExPose_left, ExPose_right, 逆深度, Td |

所有视觉因子都使用 Huber Loss 作为鲁棒核函数。

### 4.2 外点剔除（`outliersRejection`）

- 优化后，计算每个特征点的平均重投影误差
- 若 `ave_err * FOCAL_LENGTH > 3`，标记为外点
- 从 `FeatureManager` 和 `FeatureTracker` 中同时移除

### 4.3 预测下一帧特征点位置（`predictPtsInNextFrame`）

- 基于匀速运动假设，预测下一帧位姿
- 将已有深度的特征点投影到下一帧相机系
- 将预测位置传给 `FeatureTracker`，加速下一轮光流追踪

### 4.4 滑窗边缘化

- **边缘化最老帧**：将最老帧的 Pose、SpeedBias、关联的视觉/IMU 因子边缘化掉，保留为先验
- **边缘化次新帧**：仅移除次新帧的视觉观测，保留其 IMU 预积分约束

### 4.5 特征点生命周期管理

- `removeFront()` / `removeBack()`：滑窗移动时更新特征的 frame index
- `removeBackShiftDepth()`：边缘化最老帧时，将特征深度转移到新的参考帧
- `removeFailures()`：移除三角化失败的特征点

---

## 五、完整数据流总结

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   图像输入       │────▶│  FeatureTracker  │────▶│ 光流追踪+新特征提取 │
│  (Mono/Stereo)  │     │  (前端)           │     │ 去畸变+速度计算    │
└─────────────────┘     └──────────────────┘     └────────┬────────┘
                                                          │
                    {FeatureID, [CamID, xyz_uv_vxvy]}     ▼
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  滑窗BA优化      │◀────│  FeatureManager  │◀────│ 特征点入容器      │
│  (Ceres后端)     │     │  (后端管理)       │     │ 关键帧判断        │
└─────────────────┘     └──────────────────┘     └─────────────────┘
        │                                               │
        │         三角化深度恢复 ◀──────────────────────┘
        ▼
┌─────────────────┐     ┌──────────────────┐
│  视觉重投影因子   │────▶│  边缘化+外点剔除   │
│  IMU预积分因子   │     │  滑窗移动          │
└─────────────────┘     └──────────────────┘
```

---

## 六、关键类说明

### FeatureTracker
前端特征追踪类，负责光流追踪、新特征提取、去畸变、速度计算。

### FeatureManager
后端特征管理类，负责特征点入容器、关键帧判断、三角化、深度管理、滑窗维护。

### FeaturePerId
锚定 FeatureID，保存一个特征点在所有帧中的观测信息。

### FeaturePerFrame
特征点在单帧图像中的表达，包含去畸变坐标、原始像素、速度、双目标志。
