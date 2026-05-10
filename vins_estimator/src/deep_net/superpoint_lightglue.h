#pragma once

#include <opencv2/opencv.hpp>
#include <vector>
#include <memory>
#include <string>

// 前向声明，避免在当前环境编译时找不到头文件
// 实际在Docker中会有TensorRT
namespace trt {
    class TrtEngine;
}

namespace dl {

// SuperPoint特征点结构
struct SpFeature {
    cv::Point2f pt;        // 像素坐标
    cv::Point2f pt_norm;   // 归一化坐标
    std::vector<float> desc; // 描述子 (256维)
    float score;           // 响应分数
};

// 匹配结果
struct Match {
    int queryIdx;  // 第一帧中的索引
    int trainIdx;  // 第二帧中的索引
    float score;   // 匹配分数
};

// SuperPoint + LightGlue 推理器
class SuperPointLightGlue {
public:
    SuperPointLightGlue();
    ~SuperPointLightGlue();

    // 初始化：加载TensorRT引擎
    // mode: 0 = SuperPoint + 光流, 1 = SuperPoint + LightGlue匹配
    bool init(const std::string& spEnginePath, 
              const std::string& lgEnginePath = "",
              int mode = 0);

    // 从ONNX构建引擎
    bool buildEngines(const std::string& spOnnxPath,
                      const std::string& lgOnnxPath,
                      const std::string& spEnginePath,
                      const std::string& lgEnginePath,
                      bool fp16 = true);

    // 提取SuperPoint特征
    std::vector<SpFeature> extractFeatures(const cv::Mat& image);

    // 使用LightGlue匹配两帧特征
    std::vector<Match> matchFeatures(const std::vector<SpFeature>& feats0,
                                      const std::vector<SpFeature>& feats1,
                                      int imgWidth, int imgHeight);

    // 获取上次提取的特征
    const std::vector<SpFeature>& getLastFeatures() const { return lastFeatures_; }

    // 设置输入图像尺寸
    void setInputSize(int width, int height);

    bool isInitialized() const { return initialized_; }

private:
    std::unique_ptr<trt::TrtEngine> spEngine_;
    std::unique_ptr<trt::TrtEngine> lgEngine_;
    
    std::vector<SpFeature> lastFeatures_;
    std::vector<float> lastDesc_;  // 连续存储的描述子
    std::vector<cv::Point2f> lastKptsNorm_; // 归一化坐标
    
    int inputWidth_ = 640;
    int inputHeight_ = 480;
    int mode_ = 0; // 0: SP+光流, 1: SP+LightGlue
    bool initialized_ = false;
    
    // 预处理图像
    cv::Mat preprocessImage(const cv::Mat& image);
    
    // 后处理特征点
    std::vector<SpFeature> postprocessKeypoints(
        const int* keypoints, const float* scores, const float* descriptors,
        int numKpts, int imgWidth, int imgHeight);
};

} // namespace dl
