# VINS-Fusion 对比测试分析

## 测试环境
- 数据集: EuRoC MH_01_easy
- 时长: 60秒
- GPU: RTX 2060 Super
- CUDA: 12.4
- TensorRT: 8.6.1.6

## 测试结果

### 轨迹统计

| 版本 | 总距离 | 最终距离 | 高度范围 | 点数 |
|------|--------|----------|----------|------|
| Original VINS-Fusion | 13.75 m | 5.42 m | 0.64 m | 575 |
| SuperPoint + Optical Flow | 16695.17 m | 16691.79 m | 16677.77 m | 576 |
| SuperPoint + LightGlue | 16752.24 m | 16748.83 m | 16734.70 m | 577 |

### 可视化结果
- `trajectory_3d.png`: 3D轨迹对比
- `trajectory_2d.png`: 2D视图（XY, XZ, YZ平面）

## 分析

### 原始版本 (Original)
- ✅ 轨迹稳定合理
- ✅ 总距离13.75米符合预期
- ✅ 高度变化在0.64米范围内

### SuperPoint版本 (Flow & LightGlue)
- ❌ 轨迹严重发散
- ❌ Z轴快速增加到约16700米
- ❌ 位姿估计失效

## 问题诊断

SuperPoint集成存在bug，可能原因：

1. **特征点坐标格式**: SuperPoint输出的特征点坐标可能需要归一化或转换
2. **深度估计**: 特征点深度计算可能不正确
3. **TensorRT输出**: 推理结果可能需要后处理（如去归一化）
4. **相机内参**: 可能未正确传递给SuperPoint

## 建议修复

1. 检查SuperPoint输出坐标的范围和格式
2. 验证特征点深度计算逻辑
3. 添加TensorRT输出的后处理步骤
4. 对比原始特征点和SuperPoint特征点的坐标差异
