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

| 指标 | Original (Shi-Tomasi) | SuperPoint+Flow | SuperPoint+LightGlue |
|------|----------------------|-----------------|---------------------|
| ATE RMSE | 4.1283 m | 4.1149 m | **4.0400 m** |
| ATE Mean | 3.7708 m | 3.7539 m | **3.6549 m** |
| ATE Median | 4.2587 m | 4.2235 m | 4.3901 m |
| ATE Std | 1.6805 m | 1.6855 m | 1.7212 m |
| ATE Max | 7.1251 m | 7.0720 m | **6.1476 m** |
| ATE Min | 0.6382 m | 0.6197 m | **0.1176 m** |
| RPE RMSE | **0.8709 m** | 0.8723 m | 0.9136 m |
| RPE Mean | **0.6936 m** | 0.6945 m | 0.7293 m |
| RPE Std | **0.5267 m** | 0.5277 m | 0.5502 m |
| 位姿数 | 1831 | 1831 | 1480 |

### 可视化结果
- `trajectory_3d.png`: 3D轨迹对比（含ATE误差曲线）
- `ate_comparison.png`: ATE指标柱状图对比

## 分析

### 整体表现
三种方法在 MH_01_easy 上均成功运行，轨迹整体趋势一致。

### SuperPoint+LightGlue
- ✅ **ATE RMSE 最低**: 4.0400m，优于原始版本(4.1283m)和SP+Flow(4.1149m)
- ✅ **ATE Max 最小**: 6.1476m，最大误差控制最好
- ✅ **ATE Min 最小**: 0.1176m，最佳帧精度最高
- ⚠️ **RPE 略高**: 0.9136m，相对位姿误差比另外两种方法略高
- ⚠️ **位姿数较少**: 1480 vs 1831，因为 LightGlue 匹配耗时更长，跳过了部分帧

### SuperPoint+OpticalFlow
- 与原始版本精度接近，ATE RMSE 4.1149m
- 位姿数与原始版本相同(1831)，实时性良好

### 原始版本 (Shi-Tomasi + LK Flow)
- 稳定的基线性能，ATE RMSE 4.1283m
- RPE 表现最佳(0.8709m)

## 结论

1. **SuperPoint+LightGlue** 在绝对轨迹误差(ATE)上表现最优，适合对全局精度要求高的场景
2. **SuperPoint+OpticalFlow** 在实时性和精度之间取得了良好平衡
3. **原始版本** 在相对位姿误差(RPE)上仍有优势，适合对局部一致性要求高的场景
4. LightGlue 的计算开销较大，导致帧率降低，未来可通过优化 TensorRT 引擎或降低分辨率来改善