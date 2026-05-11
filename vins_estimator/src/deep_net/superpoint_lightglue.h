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

class SuperPointLightGlue {
public:
    SuperPointLightGlue();
    ~SuperPointLightGlue();

    bool init(const std::string& enginePath, int mode = 0);

    std::vector<SpFeature> extractFeatures(const cv::Mat& image);

    const std::vector<SpFeature>& getLastFeatures() const { return lastFeatures_; }

    void setInputSize(int width, int height);

    bool isInitialized() const { return initialized_; }

    int getModelWidth() const { return modelWidth_; }
    int getModelHeight() const { return modelHeight_; }

private:
    std::unique_ptr<trt::TrtEngine> engine_;

    std::vector<SpFeature> lastFeatures_;

    int modelWidth_ = 1024;
    int modelHeight_ = 1024;
    int maxKeypoints_ = 2048;
    int mode_ = 0;
    bool initialized_ = false;

    cv::Mat preprocessImage(const cv::Mat& image);
};

} // namespace dl