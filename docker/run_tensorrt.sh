#!/bin/bash
# Run VINS-Fusion with TensorRT support in Docker

set -e

# Default values
IMAGE_NAME="vins-fusion-tensorrt"
TAG="latest"
CONFIG_FILE=""
DATASET_DIR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --dataset)
            DATASET_DIR="$2"
            shift 2
            ;;
        --image)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --config FILE    Configuration file path (required)"
            echo "  --dataset DIR    Dataset directory (optional)"
            echo "  --image NAME     Docker image name (default: vins-fusion-tensorrt)"
            echo "  --tag TAG        Image tag (default: latest)"
            echo "  --help           Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 --config config/euroc/euroc_stereo_imu_config.yaml --dataset /path/to/euroc"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check required arguments
if [ -z "$CONFIG_FILE" ]; then
    echo "Error: --config is required"
    echo "Use --help for usage information"
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Get absolute path of config file
CONFIG_ABS=$(realpath "$CONFIG_FILE")
CONFIG_DIR=$(dirname "$CONFIG_ABS")

# Build docker run command
DOCKER_ARGS=""

# Add GPU support
DOCKER_ARGS="$DOCKER_ARGS --gpus all"

# Add network
DOCKER_ARGS="$DOCKER_ARGS --net=host"

# Add display for GUI
DOCKER_ARGS="$DOCKER_ARGS -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix"

# Mount config directory
DOCKER_ARGS="$DOCKER_ARGS -v $CONFIG_DIR:/config"

# Mount dataset if provided
if [ -n "$DATASET_DIR" ]; then
    if [ ! -d "$DATASET_DIR" ]; then
        echo "Error: Dataset directory not found: $DATASET_DIR"
        exit 1
    fi
    DATASET_ABS=$(realpath "$DATASET_DIR")
    DOCKER_ARGS="$DOCKER_ARGS -v $DATASET_ABS:/dataset"
fi

# Mount output directory
mkdir -p ~/output
DOCKER_ARGS="$DOCKER_ARGS -v ~/output:/root/output"

echo "========================================="
echo "Running VINS-Fusion with TensorRT"
echo "========================================="
echo "Image: $IMAGE_NAME:$TAG"
echo "Config: $CONFIG_ABS"
echo "Dataset: ${DATASET_DIR:-"Not mounted"}"
echo "========================================="

# Run container
docker run -it --rm \
    $DOCKER_ARGS \
    $IMAGE_NAME:$TAG \
    /bin/bash -c "source /opt/ros/kinetic/setup.bash && \
                  source /root/catkin_ws/devel/setup.bash && \
                  roslaunch vins vins_rviz.launch config:=/config/$(basename $CONFIG_ABS)"
