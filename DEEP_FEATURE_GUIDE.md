# VINS-Fusion with SuperPoint + LightGlue (TensorRT)

This guide explains how to use deep learning features (SuperPoint + LightGlue) in VINS-Fusion with TensorRT acceleration.

## Features

- **SuperPoint Feature Extraction**: Replace traditional corner detection with deep learning-based feature points
- **LightGlue Matching**: Deep learning-based feature matching for more robust tracking
- **SuperPoint + Optical Flow**: Use SuperPoint features with traditional LK optical flow for real-time performance
- **TensorRT Acceleration**: GPU-accelerated inference for real-time performance

## Requirements

- NVIDIA GPU with CUDA support (RTX 2060 Super or better recommended)
- Docker with NVIDIA Container Toolkit
- TensorRT 8.x

## Quick Start

### 1. Build Docker Image

```bash
cd docker
./build_tensorrt.sh
```

### 2. Convert ONNX Models to TensorRT Engines

The ONNX models are already included in the `models/` directory. Convert them to TensorRT engines:

```bash
docker run --gpus all -it --rm \
  -v $(pwd)/models:/models \
  vins-fusion-tensorrt:latest \
  python3 /tmp/convert_onnx_to_trt.py \
  --onnx /models/superpoint_lightglue_fused.onnx \
  --output /models/superpoint_lightglue_fused.engine \
  --fp16
```

### 3. Run VINS-Fusion with Deep Features

```bash
docker run --gpus all -it --rm \
  --net=host \
  -v $(pwd)/config:/root/catkin_ws/src/VINS-Fusion/config \
  -v $(pwd)/models:/root/catkin_ws/src/VINS-Fusion/models \
  vins-fusion-tensorrt:latest \
  roslaunch vins vins_rviz.launch config:=config/euroc/euroc_stereo_imu_config_deep.yaml
```

## Configuration

Add the following parameters to your config file:

```yaml
#======================== Deep Learning Feature Parameters ========================
# Enable deep learning features (SuperPoint + LightGlue)
use_deep_features: 1    # 0: disable, 1: enable SuperPoint features

# Deep feature mode:
# 0: SuperPoint feature extraction + Optical Flow tracking (faster)
# 1: SuperPoint feature extraction + LightGlue matching (more accurate)
deep_feature_mode: 0

# TensorRT engine paths
sp_engine_path: "/root/catkin_ws/src/VINS-Fusion/models/superpoint_lightglue_fused.engine"
lg_engine_path: "/root/catkin_ws/src/VINS-Fusion/models/superpoint_lightglue_fused.engine"

# SuperPoint input image size
sp_input_width: 640
sp_input_height: 480
```

## Modes

### Mode 0: SuperPoint + Optical Flow (Recommended for Real-time)

- Uses SuperPoint to extract features
- Uses LK optical flow for tracking between frames
- Faster but may lose tracking on challenging scenes
- Good balance between accuracy and speed

### Mode 1: SuperPoint + LightGlue

- Uses SuperPoint to extract features
- Uses LightGlue neural network for feature matching
- More accurate but slower
- Better for scenes with large viewpoint changes

## Performance Tips

1. **FP16 Mode**: Enable FP16 for 2x speedup with minimal accuracy loss
2. **Input Size**: Adjust `sp_input_width` and `sp_input_height` based on your GPU memory
3. **Batch Size**: For multi-camera setups, consider increasing batch size

## Troubleshooting

### TensorRT Engine Build Fails

- Ensure you have enough GPU memory
- Try building without FP16 first
- Check CUDA and TensorRT versions match

### Model Not Found

- Ensure ONNX models are in the `models/` directory
- Check engine paths in config file

### Low FPS

- Use Mode 0 (SuperPoint + Optical Flow) instead of Mode 1
- Reduce input image size
- Enable FP16 mode

## Model Information

- **Source**: [LightGlue-ONNX](https://github.com/fabio-sim/LightGlue-ONNX)
- **Model**: superpoint_lightglue_fused.onnx
- **Size**: ~44MB
- **Input**: Grayscale image (640x480 or custom size)
- **Output**: Keypoints, descriptors, scores, matches

## Citation

If you use this feature in your research, please cite:

```bibtex
@article{sarlin2023superglue,
  title={SuperGlue: Learning Feature Matching with Graph Neural Networks},
  author={Sarlin, Paul-Edouard and DeTone, Daniel and Malisiewicz, Tomasz and Rabinovich, Andrew},
  journal={CVPR},
  year={2020}
}

@article{lindenberger2023lightglue,
  title={LightGlue: Local Feature Matching at Light Speed},
  author={Lindenberger, Philipp and Sarlin, Paul-Edouard and Pollefeys, Marc},
  journal={ICCV},
  year={2023}
}
```
