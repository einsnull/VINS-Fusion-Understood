FROM ros:kinetic-perception

ENV CERES_VERSION="1.12.0"
ENV CATKIN_WS=/root/catkin_ws

# set up thread number for building
RUN if [ "x$(nproc)" = "x1" ] ; then export USE_PROC=1 ; \
    else export USE_PROC=$(($(nproc)/2)) ; fi && \
    apt-get update && apt-get install -y \
    cmake \
    libatlas-base-dev \
    libeigen3-dev \
    libgoogle-glog-dev \
    libsuitesparse-dev \
    python-catkin-tools \
    ros-${ROS_DISTRO}-cv-bridge \
    ros-${ROS_DISTRO}-image-transport \
    ros-${ROS_DISTRO}-message-filters \
    ros-${ROS_DISTRO}-tf \
    libglew-dev \
    libpython2.7-dev \
    pkg-config \
    libegl1-mesa-dev \
    libwayland-dev \
    libxkbcommon-dev \
    wayland-protocols && \
    rm -rf /var/lib/apt/lists/*

# Build and install gflags
RUN if [ "x$(nproc)" = "x1" ] ; then export USE_PROC=1 ; \
    else export USE_PROC=$(($(nproc)/2)) ; fi && \
    git clone https://github.com/gflags/gflags.git && \
    cd gflags && \
    git checkout v2.2.2 && \
    mkdir build && cd build && \
    cmake .. -DBUILD_SHARED_LIBS=ON && \
    make -j$(USE_PROC) install && \
    cd / && rm -rf /gflags

# Build and install Ceres
RUN if [ "x$(nproc)" = "x1" ] ; then export USE_PROC=1 ; \
    else export USE_PROC=$(($(nproc)/2)) ; fi && \
    git clone https://ceres-solver.googlesource.com/ceres-solver && \
    cd ceres-solver && \
    git checkout tags/${CERES_VERSION} && \
    mkdir build && cd build && \
    cmake .. && \
    make -j$(USE_PROC) install && \
    cd / && rm -rf /ceres-solver

# Build and install Pangolin
RUN if [ "x$(nproc)" = "x1" ] ; then export USE_PROC=1 ; \
    else export USE_PROC=$(($(nproc)/2)) ; fi && \
    git clone https://github.com/stevenlovegrove/Pangolin.git && \
    cd Pangolin && \
    git checkout v0.6 && \
    mkdir build && cd build && \
    cmake .. && \
    make -j$(USE_PROC) install && \
    cd / && rm -rf /Pangolin

RUN mkdir -p $CATKIN_WS/src/VINS-Fusion/

# Copy VINS-Fusion
COPY ./ $CATKIN_WS/src/VINS-Fusion/

# Build VINS-Fusion
WORKDIR $CATKIN_WS
ENV TERM=xterm
ENV PYTHONIOENCODING=UTF-8
RUN catkin config \
    --extend /opt/ros/$ROS_DISTRO \
    --cmake-args \
    -DCMAKE_BUILD_TYPE=Release && \
    catkin build && \
    sed -i '/exec "$@"/i \
    source "/root/catkin_ws/devel/setup.bash"' /ros_entrypoint.sh
