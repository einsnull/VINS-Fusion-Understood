#!/bin/bash
# Build VINS-Fusion with TensorRT support in Docker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
DOCKERFILE="$SCRIPT_DIR/Dockerfile.tensorrt"
IMAGE_NAME="vins-fusion-tensorrt"
TAG="latest"
BUILD_TYPE="Release"
USE_TENSORRT="ON"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --image-name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --build-type)
            BUILD_TYPE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --no-cache      Build without cache"
            echo "  --tag TAG       Image tag (default: latest)"
            echo "  --image-name    Image name (default: vins-fusion-tensorrt)"
            echo "  --build-type    Build type: Release/Debug (default: Release)"
            echo "  --help          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "========================================="
echo "Building VINS-Fusion with TensorRT"
echo "========================================="
echo "Project root: $PROJECT_ROOT"
echo "Dockerfile: $DOCKERFILE"
echo "Image: $IMAGE_NAME:$TAG"
echo "Build type: $BUILD_TYPE"
echo "TensorRT: $USE_TENSORRT"
echo "========================================="

# Check if Dockerfile exists
if [ ! -f "$DOCKERFILE" ]; then
    echo "Error: Dockerfile not found at $DOCKERFILE"
    exit 1
fi

# Build Docker image
echo "Building Docker image..."
docker build \
    $NO_CACHE \
    -f "$DOCKERFILE" \
    -t "$IMAGE_NAME:$TAG" \
    --build-arg BUILD_TYPE="$BUILD_TYPE" \
    "$PROJECT_ROOT"

echo "========================================="
echo "Build completed successfully!"
echo "Image: $IMAGE_NAME:$TAG"
echo "========================================="
echo ""
echo "To run the container:"
echo "  docker run --gpus all -it --rm \\"
echo "    -v /path/to/your/data:/data \\"
echo "    -v /path/to/output:/root/output \\"
echo "    $IMAGE_NAME:$TAG"
echo ""
echo "To convert ONNX models to TensorRT engines:"
echo "  docker run --gpus all -it --rm \\"
echo "    -v /path/to/models:/models \\"
echo "    $IMAGE_NAME:$TAG \\"
echo "    python3 /tmp/convert_onnx_to_trt.py --onnx /models/model.onnx --output /models/model.engine --fp16"
