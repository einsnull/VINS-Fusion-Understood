#include "superpoint_lightglue.h"
#include "trt_engine.h"
#include <cuda_runtime.h>
#include <algorithm>
#include <cmath>

namespace dl {

SuperPointLightGlue::SuperPointLightGlue() = default;

SuperPointLightGlue::~SuperPointLightGlue() = default;

bool SuperPointLightGlue::init(const std::string& spEnginePath,
                                const std::string& lgEnginePath,
                                int mode) {
    mode_ = mode;
    
    spEngine_ = std::make_unique<trt::TrtEngine>();
    if (!spEngine_->loadEngine(spEnginePath)) {
        std::cerr << "Failed to load SuperPoint engine: " << spEnginePath << std::endl;
        // Try to build from ONNX
        std::string spOnnxPath = spEnginePath.substr(0, spEnginePath.find_last_of('.')) + ".onnx";
        std::cout << "Trying to build from ONNX: " << spOnnxPath << std::endl;
        if (!spEngine_->buildEngineFromOnnx(spOnnxPath, spEnginePath, 1, false)) {
            std::cerr << "Failed to build SuperPoint engine from ONNX" << std::endl;
            return false;
        }
    }
    
    if (mode_ == 1 && !lgEnginePath.empty()) {
        lgEngine_ = std::make_unique<trt::TrtEngine>();
        if (!lgEngine_->loadEngine(lgEnginePath)) {
            std::cerr << "Failed to load LightGlue engine: " << lgEnginePath << std::endl;
            // Try to build from ONNX
            std::string lgOnnxPath = lgEnginePath.substr(0, lgEnginePath.find_last_of('.')) + ".onnx";
            std::cout << "Trying to build from ONNX: " << lgOnnxPath << std::endl;
            if (!lgEngine_->buildEngineFromOnnx(lgOnnxPath, lgEnginePath, 1, false)) {
                std::cerr << "Failed to build LightGlue engine from ONNX" << std::endl;
                return false;
            }
        }
    }
    
    initialized_ = true;
    return true;
}

bool SuperPointLightGlue::buildEngines(const std::string& spOnnxPath,
                                         const std::string& lgOnnxPath,
                                         const std::string& spEnginePath,
                                         const std::string& lgEnginePath,
                                         bool fp16) {
    spEngine_ = std::make_unique<trt::TrtEngine>();
    if (!spEngine_->buildEngineFromOnnx(spOnnxPath, spEnginePath, 1, fp16)) {
        std::cerr << "Failed to build SuperPoint engine" << std::endl;
        return false;
    }
    
    if (mode_ == 1 && !lgOnnxPath.empty()) {
        lgEngine_ = std::make_unique<trt::TrtEngine>();
        if (!lgEngine_->buildEngineFromOnnx(lgOnnxPath, lgEnginePath, 1, fp16)) {
            std::cerr << "Failed to build LightGlue engine" << std::endl;
            return false;
        }
    }
    
    initialized_ = true;
    return true;
}

void SuperPointLightGlue::setInputSize(int width, int height) {
    inputWidth_ = width;
    inputHeight_ = height;
}

cv::Mat SuperPointLightGlue::preprocessImage(const cv::Mat& image) {
    cv::Mat gray;
    if (image.channels() == 3) {
        cv::cvtColor(image, gray, cv::COLOR_BGR2GRAY);
    } else {
        gray = image.clone();
    }
    
    // 调整大小
    cv::Mat resized;
    cv::resize(gray, resized, cv::Size(inputWidth_, inputHeight_));
    
    // 归一化到 [0, 1]
    cv::Mat floatImg;
    resized.convertTo(floatImg, CV_32FC1, 1.0 / 255.0);
    
    return floatImg;
}

std::vector<SpFeature> SuperPointLightGlue::extractFeatures(const cv::Mat& image) {
    if (!initialized_ || !spEngine_) {
        return {};
    }
    
    int origWidth = image.cols;
    int origHeight = image.rows;
    
    // 预处理
    cv::Mat procImg = preprocessImage(image);
    
    // 拷贝到GPU
    void* inputBuffer = spEngine_->getInputBuffer(0);
    cudaMemcpyAsync(inputBuffer, procImg.data, 
                    inputWidth_ * inputHeight_ * sizeof(float),
                    cudaMemcpyHostToDevice, spEngine_->getStream());
    
    // 推理
    spEngine_->infer();
    spEngine_->synchronize();
    
    // 获取输出
    // SuperPoint输出: descriptors, keypoints, scores
    void* descBuffer = spEngine_->getOutputBuffer(0);
    void* kptsBuffer = spEngine_->getOutputBuffer(1);
    void* scoresBuffer = spEngine_->getOutputBuffer(2);
    
    auto descDims = spEngine_->getOutputDims(0);
    auto kptsDims = spEngine_->getOutputDims(1);
    auto scoresDims = spEngine_->getOutputDims(2);
    
    int numKpts = kptsDims[1]; // [1, N, 2]
    int descDim = descDims[2]; // [1, N, 256]
    
    // 拷贝回CPU
    std::vector<int> keypoints(numKpts * 2);
    std::vector<float> scores(numKpts);
    std::vector<float> descriptors(numKpts * descDim);
    
    cudaMemcpy(keypoints.data(), kptsBuffer, numKpts * 2 * sizeof(int), cudaMemcpyDeviceToHost);
    cudaMemcpy(scores.data(), scoresBuffer, numKpts * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(descriptors.data(), descBuffer, numKpts * descDim * sizeof(float), cudaMemcpyDeviceToHost);
    
    // 后处理
    auto features = postprocessKeypoints(keypoints.data(), scores.data(), descriptors.data(),
                                          numKpts, origWidth, origHeight);
    
    // 保存用于后续匹配
    lastFeatures_ = features;
    lastDesc_.clear();
    lastKptsNorm_.clear();
    for (const auto& f : features) {
        lastDesc_.insert(lastDesc_.end(), f.desc.begin(), f.desc.end());
        lastKptsNorm_.push_back(f.pt_norm);
    }
    
    return features;
}

std::vector<SpFeature> SuperPointLightGlue::postprocessKeypoints(
    const int* keypoints, const float* scores, const float* descriptors,
    int numKpts, int imgWidth, int imgHeight) {
    
    std::vector<SpFeature> features;
    features.reserve(numKpts);
    
    float shiftW = inputWidth_ / 2.0f;
    float shiftH = inputHeight_ / 2.0f;
    float scale = std::max(shiftW, shiftH);
    
    float scaleX = static_cast<float>(imgWidth) / inputWidth_;
    float scaleY = static_cast<float>(imgHeight) / inputHeight_;
    
    for (int i = 0; i < numKpts; ++i) {
        SpFeature feat;
        
        // 原始坐标（在resize后的图像上）
        float x = keypoints[i * 2];
        float y = keypoints[i * 2 + 1];
        
        // 映射回原图
        feat.pt.x = x * scaleX;
        feat.pt.y = y * scaleY;
        
        // 归一化坐标（用于LightGlue输入）
        feat.pt_norm.x = (x - shiftW) / scale;
        feat.pt_norm.y = (y - shiftH) / scale;
        
        feat.score = scores[i];
        
        // 描述子 (256维)
        feat.desc.resize(256);
        for (int j = 0; j < 256; ++j) {
            feat.desc[j] = descriptors[i * 256 + j];
        }
        
        features.push_back(feat);
    }
    
    return features;
}

std::vector<Match> SuperPointLightGlue::matchFeatures(const std::vector<SpFeature>& feats0,
                                                       const std::vector<SpFeature>& feats1,
                                                       int imgWidth, int imgHeight) {
    if (!initialized_ || !lgEngine_) {
        return {};
    }
    
    int n0 = feats0.size();
    int n1 = feats1.size();
    
    if (n0 == 0 || n1 == 0) return {};
    
    // 准备输入数据
    std::vector<float> kpts0(n0 * 2);
    std::vector<float> kpts1(n1 * 2);
    std::vector<float> desc0(n0 * 256);
    std::vector<float> desc1(n1 * 256);
    
    float shiftW = inputWidth_ / 2.0f;
    float shiftH = inputHeight_ / 2.0f;
    float scale = std::max(shiftW, shiftH);
    
    for (int i = 0; i < n0; ++i) {
        kpts0[i * 2] = feats0[i].pt_norm.x;
        kpts0[i * 2 + 1] = feats0[i].pt_norm.y;
        for (int j = 0; j < 256; ++j) {
            desc0[i * 256 + j] = feats0[i].desc[j];
        }
    }
    
    for (int i = 0; i < n1; ++i) {
        kpts1[i * 2] = feats1[i].pt_norm.x;
        kpts1[i * 2 + 1] = feats1[i].pt_norm.y;
        for (int j = 0; j < 256; ++j) {
            desc1[i * 256 + j] = feats1[i].desc[j];
        }
    }
    
    // 设置动态输入维度
    lgEngine_->setInputDims(0, {1, n0, 2});
    lgEngine_->setInputDims(1, {1, n1, 2});
    lgEngine_->setInputDims(2, {1, n0, 256});
    lgEngine_->setInputDims(3, {1, n1, 256});
    
    // 拷贝到GPU
    cudaMemcpyAsync(lgEngine_->getInputBuffer(0), kpts0.data(), n0 * 2 * sizeof(float),
                    cudaMemcpyHostToDevice, lgEngine_->getStream());
    cudaMemcpyAsync(lgEngine_->getInputBuffer(1), kpts1.data(), n1 * 2 * sizeof(float),
                    cudaMemcpyHostToDevice, lgEngine_->getStream());
    cudaMemcpyAsync(lgEngine_->getInputBuffer(2), desc0.data(), n0 * 256 * sizeof(float),
                    cudaMemcpyHostToDevice, lgEngine_->getStream());
    cudaMemcpyAsync(lgEngine_->getInputBuffer(3), desc1.data(), n1 * 256 * sizeof(float),
                    cudaMemcpyHostToDevice, lgEngine_->getStream());
    
    // 推理
    lgEngine_->infer();
    lgEngine_->synchronize();
    
    // 获取输出
    void* matchesBuffer = lgEngine_->getOutputBuffer(0);
    void* mscoresBuffer = lgEngine_->getOutputBuffer(1);
    
    auto matchDims = lgEngine_->getOutputDims(0);
    int numMatches = matchDims[0];
    
    std::vector<int> matches(numMatches * 2);
    std::vector<float> mscores(numMatches);
    
    cudaMemcpy(matches.data(), matchesBuffer, numMatches * 2 * sizeof(int), cudaMemcpyDeviceToHost);
    cudaMemcpy(mscores.data(), mscoresBuffer, numMatches * sizeof(float), cudaMemcpyDeviceToHost);
    
    // 解析匹配结果
    std::vector<Match> result;
    result.reserve(numMatches);
    
    for (int i = 0; i < numMatches; ++i) {
        int idx0 = matches[i * 2];
        int idx1 = matches[i * 2 + 1];
        
        // -1 表示无匹配
        if (idx0 >= 0 && idx1 >= 0 && idx0 < n0 && idx1 < n1) {
            Match m;
            m.queryIdx = idx0;
            m.trainIdx = idx1;
            m.score = mscores[i];
            result.push_back(m);
        }
    }
    
    return result;
}

} // namespace dl
