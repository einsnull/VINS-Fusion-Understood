# VINS-Fusion with SuperPoint + TensorRT
# For RTX 2060 Super (SM75) with CUDA 12.x
# Based on nvidia/cuda:12.4.0-devel-ubuntu20.04 + ROS Noetic

FROM nvidia/cuda:12.4.0-devel-ubuntu20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=noetic
ENV CATKIN_WS=/root/catkin_ws

# Use China mirrors for apt
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# Install basic dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    gnupg \
    software-properties-common \
    python3 \
    python3-pip \
    python3-dev \
    git \
    lsb-release \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Add ROS repository
RUN sh -c 'echo "deb http://packages.ros.org/ros/ubuntu $(lsb_release -sc) main" > /etc/apt/sources.list.d/ros-latest.list' && \
    curl -sSL 'http://keyserver.ubuntu.com/pks/lookup?op=get&search=0xC1CF6E31E6BADE8868B172B4F42ED6FBAB17C654' | apt-key add -

# Install ROS base + RViz
RUN apt-get update && apt-get install -y \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-cv-bridge \
    ros-${ROS_DISTRO}-image-transport \
    ros-${ROS_DISTRO}-tf \
    ros-${ROS_DISTRO}-rviz \
    python3-rosdep \
    python3-rosinstall \
    python3-rosinstall-generator \
    python3-wstool \
    python3-catkin-tools \
    && rm -rf /var/lib/apt/lists/*

# Initialize rosdep
RUN rosdep init || true && \
    rosdep update || true

# Configure pip to use China mirror
RUN pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple || true

# Install additional dependencies for VINS-Fusion
RUN apt-get update && apt-get install -y \
    libopencv-dev \
    libeigen3-dev \
    libceres-dev \
    libboost-all-dev \
    libgoogle-glog-dev \
    libgflags-dev \
    libglew-dev \
    libpython3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install cuDNN (required by TensorRT)
RUN apt-get update && apt-get install -y \
    libcudnn8 \
    libcudnn8-dev \
    && rm -rf /var/lib/apt/lists/*

# Build Pangolin from source
RUN cd /tmp && \
    git clone --recursive https://github.com/stevenlovegrove/Pangolin.git && \
    cd Pangolin && \
    git checkout v0.6 && \
    mkdir build && cd build && \
    cmake .. && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    cd / && rm -rf /tmp/Pangolin

# Copy and extract TensorRT from local file
COPY docker/TensorRT-8.6.1.6.Linux.x86_64-gnu.cuda-12.0.tar.gz /tmp/
RUN cd /tmp && \
    tar -xzf TensorRT-8.6.1.6.Linux.x86_64-gnu.cuda-12.0.tar.gz && \
    cp -r TensorRT-8.6.1.6/lib/* /usr/lib/x86_64-linux-gnu/ && \
    cp -r TensorRT-8.6.1.6/include/* /usr/include/ && \
    ldconfig && \
    pip3 install --no-cache-dir TensorRT-8.6.1.6/python/tensorrt-8.6.1-cp38-none-linux_x86_64.whl && \
    python3 -c "import tensorrt; print('TensorRT Python version:', tensorrt.__version__)" && \
    rm -rf TensorRT-8.6.1.6*

# Install ONNX for model conversion
RUN pip3 install --no-cache-dir onnx onnxruntime || true

# Install PyTorch for model export
RUN pip3 install --no-cache-dir \
    'typing-extensions<4.6' \
    numpy \
    && pip3 install --no-cache-dir \
    torch==1.13.1+cu117 \
    torchvision==0.14.1+cu117 \
    --index-url https://download.pytorch.org/whl/cu117 \
    && python3 -c "import torch; print('PyTorch', torch.__version__, 'CUDA', torch.cuda.is_available())"

# Set environment variables
ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH}
ENV LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:${LIBRARY_PATH}
ENV CUDA_MODULE_LOADING=LAZY

# Copy model files and conversion script
COPY models/ /models/
COPY scripts/convert_onnx_to_trt.py /scripts/convert_onnx_to_trt.py

# Copy VINS-Fusion source
RUN rm -rf $CATKIN_WS/src/VINS-Fusion/*
COPY ./ $CATKIN_WS/src/VINS-Fusion/

# Build VINS-Fusion with TensorRT
WORKDIR $CATKIN_WS
ENV TERM=xterm
ENV PYTHONIOENCODING=UTF-8

RUN /bin/bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash && \
    catkin init && \
    catkin config --extend /opt/ros/${ROS_DISTRO} --cmake-args \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_TENSORRT=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 && \
    catkin build"

# Set up entrypoint
RUN echo '#!/bin/bash\nsource /opt/ros/noetic/setup.bash\nsource /root/catkin_ws/devel/setup.bash\nexec "$@"' > /ros_entrypoint.sh && \
    chmod +x /ros_entrypoint.sh

WORKDIR $CATKIN_WS
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["/bin/bash"]