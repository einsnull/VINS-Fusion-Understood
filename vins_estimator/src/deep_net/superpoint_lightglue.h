#pragma once

#include <opencv2/opencv.hpp>
#include <vector>
#include <memory>
#include <string>

namespace trt {
    class TrtEngine;
}

namespace dl {

struct SpFeature {
    cv::Point2f pt;
    cv::Point2f pt_norm;
    std::vector<float> desc;
    float score;
};

struct Match {
    int queryIdx;
    int trainIdx;
    float score;
};

struct MatchResult {
    std::vector<SpFeature> features0;
    std::vector<SpFeature> features1;
    std::vector<Match> matches;
};

class SuperPointLightGlue {
public:
    SuperPointLightGlue();
    ~SuperPointLightGlue();

    /// @brief 初始化推理器
    /// @param enginePath TensorRT引擎文件路径
    /// @param mode 0: SuperPoint提取模式, 1: SuperPoint+LightGlue pipeline模式
    /// @param spEnginePath SuperPoint单独引擎路径 (mode=1时需要，用于首帧提取)
    /// @return 是否初始化成功
    bool init(const std::string& enginePath, int mode, const std::string& spEnginePath = "");

    std::vector<SpFeature> extractFeatures(const cv::Mat& image);

    MatchResult matchFeatures(const cv::Mat& img0, const cv::Mat& img1);

    const std::vector<SpFeature>& getLastFeatures() const { return lastFeatures_; }

    void setInputSize(int width, int height);

    bool isInitialized() const { return initialized_; }

    int getModelWidth() const { return modelWidth_; }
    int getModelHeight() const { return modelHeight_; }

    int getMode() const { return mode_; }

private:
    std::unique_ptr<trt::TrtEngine> engine_;
    std::unique_ptr<trt::TrtEngine> spEngine_;     // SuperPoint单独引擎 (mode=1时用于首帧提取)

    std::vector<SpFeature> lastFeatures_;

    int modelWidth_ = 1024;
    int modelHeight_ = 1024;
    int maxKeypoints_ = 2048;
    int mode_ = 0;
    bool initialized_ = false;

    cv::Mat preprocessImage(const cv::Mat& image);
    cv::Mat preprocessImageForPipeline(const cv::Mat& image);
};

} // namespace dl