#!/bin/bash
mv /usr/lib/x86_64-linux-gnu/mesa /usr/lib/x86_64-linux-gnu/mesa.bak 2>/dev/null || true
ln -sf /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libGL.so
ln -sf /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libGL.so.1
ln -sf /usr/lib/x86_64-linux-gnu/libGLESv2_nvidia.so.2 /usr/lib/x86_64-linux-gnu/libGLESv2.so
ldconfig

source /opt/ros/kinetic/setup.bash
cd /root/catkin_ws
source devel/setup.bash

export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVIDIA_VISIBLE_DEVICES=all
export NVIDIA_DRIVER_CAPABILITIES=all

echo "Starting roscore..."
roscore &
sleep 2

CONFIG_FILE="$1"
UI_OPTION="$2"

echo "CONFIG_FILE: $CONFIG_FILE"
echo "UI_OPTION: $UI_OPTION"

if [ "$UI_OPTION" = "0" ]; then
    echo "Starting VINS without UI..."
    rosrun vins vins_node "$CONFIG_FILE" 0
else
    echo "Starting VINS with UI..."
    rosrun vins vins_node "$CONFIG_FILE" 1
fi &

tail -f /dev/null
