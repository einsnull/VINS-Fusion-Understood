# EuRoC 数据集上微调 SuperPoint + LightGlue 指南

## 1. 背景与动机

在 Machine Hall 全序列对比实验中，SuperPoint + LightGlue 在简单/中等场景（MH_01、MH_03）表现优于原始 VINS-Fusion，但在困难场景（MH_04、MH_05）退化明显：

| 序列 | Original ATE | SP+Flow ATE | SP+LG (0.5x) ATE |
|------|-------------|------------|-------------------|
| MH_01_easy | 4.13m | 4.11m | **4.04m** |
| MH_03_medium | 3.79m | 3.80m | **3.15m** |
| MH_04_difficult | 9.78m | **8.73m** | 9.40m |
| MH_05_difficult | **9.69m** | 9.92m | 10.95m |

原因分析：LightGlue 的预训练权重来自 MegaDepth（户外地标场景），与 EuRoC（室内工厂/机房）存在显著的域差异（domain gap）。通过在 EuRoC 数据上进行微调，有望让模型适应室内工业场景的视觉特征（低纹理、重复结构、运动模糊），从而提升困难场景的匹配质量。

## 2. 原始训练方法回顾

LightGlue 的训练代码位于 [cvg/glue-factory](https://github.com/cvg/glue-factory)，采用两阶段训练：

### 2.1 阶段 1：Homography 预训练

```
Oxford-Paris 图像（100万张互联网图片）
        │
        ▼
随机生成单应矩阵 H（旋转、缩放、透视变换）
        │
        ▼
对原图做 warp 生成图像对 (I, I')
        │
        ▼
H 矩阵已知 → 像素级精确对应关系已知
        │
        ▼
SuperPoint 提取特征（冻结，不训练）
        │
        ▼
LightGlue 学习匹配 → 监督信号来自 H 矩阵投影
```

- **数据集**：Oxford-Paris distractors（~450GB）
- **特点**：纯合成数据，不需要真实 3D 信息
- **目的**：让 LightGlue 学会基本的特征匹配能力

### 2.2 阶段 2：MegaDepth 微调

```
MegaDepth 场景（地标照片 + SfM 重建）
        │
        ▼
每张图提供：RGB + 稠密深度图 + 相机内参 K + 相机位姿 T
        │
        ▼
图像对选择：基于 overlap_matrix（深度投影计算的重叠比例）
        │
        ▼
匹配真值生成：
  图A 特征点 p_A → 深度图 → 3D 坐标 P_3D
                → 相对位姿 T_0to1 → 投影到图B → p_A'
                → 若 p_A' 附近有 SuperPoint 检测点 → 真匹配
        │
        ▼
LightGlue 学习匹配 → 监督信号来自深度+位姿投影
```

- **数据集**：MegaDepth（~420GB）
- **特点**：真实场景，复杂外观和视角变化
- **目的**：让 LightGlue 适应真实世界的匹配场景

### 2.3 关键依赖

| 数据 | 阶段1 (Homography) | 阶段2 (MegaDepth) |
|------|-------------------|-------------------|
| RGB 图像 | ✅ | ✅ |
| 相机内参 | ❌ | ✅ |
| 相机位姿 | ❌ | ✅ |
| 稠密深度图 | ❌ | ✅ **必需** |
| 重叠矩阵 | ❌ | ✅ |

## 3. EuRoC 微调方案

### 3.1 阶段 1：EuRoC Homography 预训练

**可行性**：✅ 直接可行，不依赖任何 3D 信息。

**方案**：
1. 从 EuRoC rosbag 提取 cam0（左目）图像帧
2. 使用 glue-factory 的 Homography 训练流程
3. 对每张 EuRoC 图像随机生成单应变换，生成训练对
4. 冻结 SuperPoint，训练 LightGlue

**数据准备**：
```bash
# 提取所有序列的左目图像
for seq in MH_01_easy MH_02_easy MH_03_medium MH_04_difficult MH_05_difficult; do
    unzip dataset/machine_hall/${seq}/${seq}.zip \
        "mav0/cam0/data/*.png" -d dataset/machine_hall/${seq}/
done
```

**训练命令**（参考 glue-factory）：
```bash
python -m gluefactory.train sp+lg_euroc_homography \
    --conf gluefactory/configs/superpoint+lightglue_homography.yaml \
    data.dataset_name=euroc_homography \
    data.root=/path/to/euroc_frames
```

**预期效果**：让 LightGlue 适应 EuRoC 的图像风格（灰度、光照、纹理模式），但匹配能力仍受限于合成变换的简单性。

### 3.2 阶段 2：EuRoC MegaDepth 风格微调

**可行性**：⚠️ 需要额外步骤，EuRoC 没有稠密深度图。

**方案**：利用 EuRoC 的双目相机计算深度。

```
EuRoC 双目图像对 (cam0, cam1)
        │
        ▼
双目匹配 → 视差图 → 深度图（稀疏/半稠密）
        │
        ▼
Vicon 真值位姿 → 相对位姿 T_0to1
        │
        ▼
构建 MegaDepth 格式数据集：
  - images/: 左目图像
  - depths/: 双目计算的深度图（HDF5 格式）
  - intrinsics: 相机内参矩阵
  - poses: Vicon 真值位姿
  - overlap_matrix: 基于深度投影计算
        │
        ▼
用 glue-factory 在 EuRoC 上微调 LightGlue
```

**深度图计算**：

EuRoC 双目基线 ~11cm，图像分辨率 752×480。可使用以下方法：

1. **OpenCV StereoBM/StereoSGBM**：快速但精度一般
2. **RAFT-Stereo**：深度学习双目匹配，精度更高
3. **CREStereo**：当前 SOTA 双目匹配

推荐使用 RAFT-Stereo 或 CREStereo 以获得更可靠的深度图。

**数据格式要求**（参考 MegaDepth 格式）：

```
euroc_megadepth/
├── Undistorted_SfM/
│   └── MH_01_easy/
│       ├── 1403636579763555584.png
│       ├── 1403636579813555456.png
│       └── ...
├── depth_undistorted/
│   └── MH_01_easy/
│       ├── 1403636579763555584.h5    # HDF5, key='/depth'
│       ├── 1403636579813555456.h5
│       └── ...
└── scene_info/
    └── MH_01_easy.npz                # 包含:
        ├── image_paths               # 图像路径列表
        ├── depth_paths               # 深度图路径列表
        ├── intrinsics                # 内参矩阵 (N×3×3)
        ├── poses                     # 位姿矩阵 (N×4×4)
        └── overlap_matrix            # 重叠矩阵 (N×N)
```

**训练命令**：
```bash
# 先提取特征缓存（节省训练时间）
python -m gluefactory.scripts.export_megadepth --method sp --num_workers 8

# 在阶段1基础上微调
python -m gluefactory.train sp+lg_euroc_megadepth \
    --conf gluefactory/configs/superpoint+lightglue_megadepth.yaml \
    train.load_experiment=sp+lg_euroc_homography \
    data.load_features.do=True
```

**预期效果**：让 LightGlue 学习 EuRoC 真实场景下的匹配规律，包括运动模糊、低纹理区域、重复结构等挑战。

### 3.3 训练策略建议

| 参数 | 阶段1 | 阶段2 | 说明 |
|------|-------|-------|------|
| SuperPoint | 冻结 | 冻结 | 不训练检测器 |
| LightGlue | 从头训练 | 从阶段1加载 | 只训练匹配器 |
| Batch size | 32-128 | 16-32 | 取决于 GPU 显存 |
| Learning rate | 1e-3 | 1e-4 | 阶段2 用更小学习率 |
| Epochs | 50-100 | 20-50 | EuRoC 数据量小，防止过拟合 |
| 数据增强 | 随机旋转±90° | 随机旋转±90° | 模拟无人机姿态变化 |

## 4. 部署流程

训练完成后，需要将 PyTorch 模型转换回 TensorRT 引擎：

```
PyTorch 权重 (.pth)
        │
        ▼
导出 ONNX（使用 LightGlue-ONNX 的 export.py）
        │
        ▼
ONNX → TensorRT Engine（使用 convert_onnx_to_trt.py）
        │
        ▼
替换 VINS-Fusion 中的 engine 文件
        │
        ▼
运行对比测试验证效果
```

```bash
# 1. 导出 ONNX
python dynamo.py export superpoint \
    --num-keypoints 1024 \
    -b 2 -h 480 -w 752 \
    --ckpt /path/to/finetuned_checkpoint.pth \
    -o weights/superpoint_lightglue_euroc.onnx

# 2. 转 TensorRT
python scripts/convert_onnx_to_trt.py \
    --onnx weights/superpoint_lightglue_euroc.onnx \
    --output weights/superpoint_lightglue_euroc.trt

# 3. 替换 engine 并测试
cp weights/superpoint_lightglue_euroc.trt \
   docker/superpoint_lightglue_v2.trt
# 重新构建 Docker 镜像
# 运行对比测试
```

## 5. 潜在问题与对策

| 问题 | 影响 | 对策 |
|------|------|------|
| EuRoC 数据量小（~18000帧） | 容易过拟合 | 强数据增强、early stopping、减小模型容量 |
| 双目深度噪声大 | 匹配标签不准确 | 使用高质量双目匹配算法、设置合理的投影阈值 |
| 低纹理区域深度缺失 | 部分区域无监督信号 | 只在高置信度深度区域计算 loss |
| 运动模糊帧 | 特征提取质量差 | 在模糊帧上不做监督，或降低 loss 权重 |
| 域差异（室内 vs 户外） | 预训练权重不适用 | 阶段1 的 Homography 训练可缓解 |
| GPU 显存限制（RTX 2060 8GB） | 无法使用大 batch size | 减小 batch size、使用 gradient accumulation |

## 6. 参考资源

- [glue-factory](https://github.com/cvg/glue-factory) — LightGlue 训练框架
- [LightGlue](https://github.com/cvg/LightGlue) — 原始 LightGlue 推理代码
- [LightGlue-ONNX](https://github.com/fabio-sim/LightGlue-ONNX) — ONNX/TensorRT 导出
- [LightGlue Paper](https://arxiv.org/abs/2306.13643) — ICCV 2023
- [SuperPoint Paper](https://arxiv.org/abs/1712.07629) — 自监督关键点检测