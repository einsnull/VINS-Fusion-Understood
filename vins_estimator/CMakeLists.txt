cmake_minimum_required(VERSION 2.8.3)
project(vins)

set(CMAKE_BUILD_TYPE "Release")
set(CMAKE_CXX_FLAGS "-std=c++14") #11改为14以支持pangolin
#-DEIGEN_USE_MKL_ALL")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall -g")

## 一些库（比如glog）并不总能在系统中找到FindXXX.cmake之类的文件，我们在这里手动提供
message(STATUS "## CMAKE_SOURCE_DIR   : " ${CMAKE_SOURCE_DIR})
message(STATUS "## PROJECT_SOURCE_DIR : " ${PROJECT_SOURCE_DIR})
list(APPEND CMAKE_MODULE_PATH ${PROJECT_SOURCE_DIR}/../cmake)
list(APPEND CMAKE_MODULE_PATH ${PROJECT_SOURCE_DIR}/cmake)

find_package(Eigen3)
message(STATUS "## EIGEN3_FOUND        : " ${EIGEN3_FOUND})
message(STATUS "## EIGEN3_INCLUDE_DIR  : " ${EIGEN3_INCLUDE_DIR})

find_package(OpenCV REQUIRED)
message(STATUS "## OpenCV_VERSION      : " ${OpenCV_VERSION})
message(STATUS "## OpenCV_INCLUDE_DIRS : " ${OpenCV_INCLUDE_DIRS})
message(STATUS "## OpenCV_LIBRARIES    : " ${OpenCV_LIBRARIES})
message(STATUS "## OpenCV_LIBS         : " ${OpenCV_LIBS})

find_package(Ceres REQUIRED)
message(STATUS "## CERES_VERSION      : " ${CERES_VERSION})
message(STATUS "## CERES_INCLUDE_DIRS : " ${CERES_INCLUDE_DIRS})
message(STATUS "## CERES_LIBRARIES    : " ${CERES_LIBRARIES})

find_package(Glog REQUIRED)
message(STATUS "## GLOG_FOUND        : " ${GLOG_FOUND})
message(STATUS "## GLOG_INCLUDE_DIRS : " ${GLOG_INCLUDE_DIRS})
message(STATUS "## GLOG_INCLUDE_DIR  : " ${GLOG_INCLUDE_DIR})
message(STATUS "## GLOG_LIBRARIES    : " ${GLOG_LIBRARIES})

find_package(Gflags REQUIRED)
message(STATUS "## GFLAGS_FOUND        : " ${GFLAGS_FOUND})
message(STATUS "## GFLAGS_INCLUDE_DIRS : " ${GFLAGS_INCLUDE_DIRS})
message(STATUS "## GFLAGS_LIBRARIES    : " ${GFLAGS_LIBRARIES})

find_package(Pangolin REQUIRED) #QUIET
message(STATUS "## Pangolin INCLUDE DIRS: " ${Pangolin_INCLUDE_DIRS})
message(STATUS "## Pangolin LIBRARIES   : " ${Pangolin_LIBRARIES})
message(STATUS "## Pangolin FOUND       : " ${Pangolin_FOUND})
if(${Pangolin_FOUND}) 
  message(STATUS "## yes, found Pangolin!")
  add_definitions(-DUSE_PANGOLIN)
endif()

# ==================== TensorRT Support ====================
option(USE_TENSORRT "Enable TensorRT for deep learning features" OFF)

if(USE_TENSORRT)
  # Find CUDA (optional, for includes)
  find_package(CUDA QUIET)
  if(CUDA_FOUND)
    message(STATUS "## CUDA found: " ${CUDA_VERSION})
    include_directories(${CUDA_INCLUDE_DIRS})
  else()
    message(STATUS "## CUDA not found, but TensorRT may still work")
  endif()
  
  # Find TensorRT - use absolute paths for Docker environment
  if(EXISTS /usr/include/NvInfer.h)
    set(TENSORRT_INCLUDE_DIR /usr/include)
    set(TENSORRT_LIBRARY /usr/lib/x86_64-linux-gnu/libnvinfer.so)
    if(EXISTS /usr/lib/x86_64-linux-gnu/libnvonnxparser.so)
      set(TENSORRT_ONNXPARSER_LIBRARY /usr/lib/x86_64-linux-gnu/libnvonnxparser.so)
    else()
      set(TENSORRT_ONNXPARSER_LIBRARY "")
    endif()
    message(STATUS "## TensorRT found (absolute path)")
  else()
    # Find TensorRT
    find_path(TENSORRT_INCLUDE_DIR NvInfer.h
      HINTS ${TENSORRT_ROOT} ${CUDA_TOOLKIT_ROOT_DIR} /usr/include
      PATH_SUFFIXES include)
    find_library(TENSORRT_LIBRARY nvinfer
      HINTS ${TENSORRT_ROOT} ${CUDA_TOOLKIT_ROOT_DIR} /usr/lib/x86_64-linux-gnu
      PATH_SUFFIXES lib lib64 lib/x64)
    find_library(TENSORRT_ONNXPARSER_LIBRARY nvonnxparser
      HINTS ${TENSORRT_ROOT} ${CUDA_TOOLKIT_ROOT_DIR} /usr/lib/x86_64-linux-gnu
      PATH_SUFFIXES lib lib64 lib/x64)
  endif()
  
  if(TENSORRT_INCLUDE_DIR AND TENSORRT_LIBRARY)
    message(STATUS "## TensorRT found")
    message(STATUS "## TENSORRT_INCLUDE_DIR: " ${TENSORRT_INCLUDE_DIR})
    message(STATUS "## TENSORRT_LIBRARY: " ${TENSORRT_LIBRARY})
    
    include_directories(${TENSORRT_INCLUDE_DIR})
    add_definitions(-DUSE_TENSORRT)
    # Link TensorRT and CUDA libraries
    set(TENSORRT_LIBS ${TENSORRT_LIBRARY})
    # Find and link CUDA libraries
    find_library(CUDA_RUNTIME_LIBRARY cudart HINTS /usr/local/cuda/lib64 /usr/lib/x86_64-linux-gnu)
    find_library(CUDA_DRIVER_LIBRARY cuda HINTS /usr/local/cuda/lib64 /usr/lib/x86_64-linux-gnu)
    if(CUDA_RUNTIME_LIBRARY)
      list(APPEND TENSORRT_LIBS ${CUDA_RUNTIME_LIBRARY})
    endif()
    if(CUDA_DRIVER_LIBRARY)
      list(APPEND TENSORRT_LIBS ${CUDA_DRIVER_LIBRARY})
    endif()
    # Find and link ONNX parser
    find_library(TENSORRT_ONNXPARSER_LIBRARY nvonnxparser HINTS /usr/lib/x86_64-linux-gnu)
    if(TENSORRT_ONNXPARSER_LIBRARY)
      list(APPEND TENSORRT_LIBS ${TENSORRT_ONNXPARSER_LIBRARY})
    endif()
  else()
    message(WARNING "## TensorRT not found, disabling deep learning features")
    set(USE_TENSORRT OFF)
  endif()
endif()

find_package(catkin REQUIRED COMPONENTS
  roscpp
  std_msgs
  geometry_msgs
  nav_msgs
  tf
  cv_bridge
  camera_models
  image_transport
)

include_directories(
  ${catkin_INCLUDE_DIRS}
  ${CERES_INCLUDE_DIRS}
  ${EIGEN3_INCLUDE_DIR}
  ${Glog_INCLUDE_DIRS}
  ${Pangolin_INCLUDE_DIRS}
)

catkin_package()

set(VINS_LIB_SOURCES
  src/estimator/parameters.cpp
  src/estimator/estimator.cpp
  src/estimator/feature_manager.cpp
  src/featureTracker/feature_tracker.cpp
  src/initial/solve_5pts.cpp
  src/initial/initial_alignment.cpp
  src/initial/initial_sfm.cpp
  src/initial/initial_ex_rotation.cpp
  src/factor/pose_local_parameterization.cpp
  src/factor/projectionTwoFrameOneCamFactor.cpp
  src/factor/projectionTwoFrameTwoCamFactor.cpp
  src/factor/projectionOneFrameTwoCamFactor.cpp
  src/factor/marginalization_factor.cpp
  src/utility/utility.cpp
  src/utility_ros/RosVisualization.cpp
  src/utility_ros/CameraPoseVisualization.cpp
  src/ui_pangolin/ui_window_impl.cpp
  src/ui_pangolin/ui_window.cpp
)

if(USE_TENSORRT)
  list(APPEND VINS_LIB_SOURCES
    src/deep_net/trt_engine.cpp
    src/deep_net/superpoint_lightglue.cpp
  )
  # Enable CUDA for deep_net files
  set_source_files_properties(
    src/deep_net/trt_engine.cpp
    src/deep_net/superpoint_lightglue.cpp
    PROPERTIES CUDA_SOURCE_PROPERTY_FORMAT OBJ
  )
endif()

add_library(vins_lib ${VINS_LIB_SOURCES})

# if (${Pangolin_FOUND}) {
#     add_library(vins_lib
#       src/ui_pangolin/ui_window_impl.cpp
#       src/ui_pangolin/ui_window.cpp
#   )
# }

target_link_libraries(vins_lib 
  ${catkin_LIBRARIES} 
  ${OpenCV_LIBS} 
  ${CERES_LIBRARIES}
  ${Pangolin_LIBRARIES}
  ${TENSORRT_LIBS}
)


add_executable(vins_node src/rosNodeTest.cpp)
target_link_libraries(vins_node vins_lib) 

add_executable(kitti_odom_test src/KITTIOdomTest.cpp)
target_link_libraries(kitti_odom_test vins_lib) 

add_executable(kitti_gps_test src/KITTIGPSTest.cpp)
target_link_libraries(kitti_gps_test vins_lib) 

