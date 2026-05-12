# VINS-Fusion 对比测试分析

## 测试环境
- 数据集: EuRoC MH_01_easy (完整序列, ~187秒)
- GPU: RTX 2060 Super
- CUDA: 12.4
- TensorRT: 8.6.1.6
- SuperPoint 模型: superpoint_v1 (1024x1024)
- LightGlue 模型: superpoint_lightglue_pipeline (fabio-sim/LightGlue-ONNX)

## 测试结果

### 轨迹精度对比

| 指标 | Original (Shi-Tomasi) | SuperPoint+Flow | SuperPoint+LightGlue (0.5x) |
|------|----------------------|-----------------|---------------------------|
| ATE RMSE | 4.1283 m | 4.1149 m | **3.7335 m** |
| ATE Mean | 3.7708 m | 3.7539 m | **3.4135 m** |
| ATE Median | 4.2587 m | 4.2235 m | **3.8117 m** |
| ATE Std | 1.6805 m | 1.6855 m | **1.5124 m** |
| ATE Max | 7.1251 m | 7.0720 m | **6.4471 m** |
| ATE Min | 0.6382 m | 0.6197 m | 0.5983 m |
| RPE RMSE | **0.8709 m** | 0.8723 m | 0.8767 m |
| RPE Mean | **0.6936 m** | 0.6945 m | 0.6995 m |
| RPE Std | **0.5267 m** | 0.5277 m | 0.5285 m |
| 位姿数 | 1831 | 1831 | 1822 |

> 注: SuperPoint+LightGlue 使用 0.5x rosbag 播放速率以确保 LightGlue 匹配有足够时间处理每一帧。
> 在 1x 速率下位姿数仅 1480，ATE RMSE 为 4.0400m。

### 可视化结果
- `trajectory_3d.png`: 3D轨迹对比（含ATE误差曲线）
- `ate_comparison.png`: ATE指标柱状图对比

## 分析

### 整体表现
三种方法在 MH_01_easy 上均成功运行，轨迹整体趋势一致。

### SuperPoint+LightGlue (0.5x 播放速率)
- ✅ **ATE RMSE 最低**: 3.7335m，比原始版本提升 **9.6%**，比 SP+Flow 提升 **9.3%**
- ✅ **ATE Mean 最低**: 3.4135m
- ✅ **ATE Std 最小**: 1.5124m，轨迹一致性最好
- ✅ **ATE Max 最小**: 6.4471m，最大误差控制最好
- ✅ **RPE 与原始版本持平**: 0.8767m vs 0.8709m，差距仅 0.7%
- ✅ **位姿数接近满帧**: 1822/1831 (99.5%)

### SuperPoint+OpticalFlow
- 与原始版本精度接近，ATE RMSE 4.1149m
- 位姿数与原始版本相同(1831)，实时性良好

### 原始版本 (Shi-Tomasi + LK Flow)
- 稳定的基线性能，ATE RMSE 4.1283m
- RPE 表现最佳(0.8709m)，但 SP+LightGlue(0.5x) 仅差 0.7%

## 播放速率对 LightGlue 的影响

| 指标 | SP+LG (1x) | SP+LG (0.5x) | 改善 |
|------|-----------|-------------|------|
| ATE RMSE | 4.0400 m | 3.7335 m | **-7.6%** |
| ATE Std | 1.7212 m | 1.5124 m | **-12.1%** |
| RPE RMSE | 0.9136 m | 0.8767 m | **-4.0%** |
| 位姿数 | 1480 | 1822 | **+23.1%** |

降低播放速率后，LightGlue 能够处理几乎所有帧，各项指标全面提升。

## 结论

1. **SuperPoint+LightGlue** 在充足计算时间下，ATE 全面领先，是最优方案
2. LightGlue 匹配耗时是主要瓶颈，在实时场景下会丢帧导致精度下降
3. **SuperPoint+OpticalFlow** 在实时性和精度之间取得了最佳平衡
4. 未来优化方向：TensorRT 引擎优化、降低输入分辨率、使用更轻量的匹配网络