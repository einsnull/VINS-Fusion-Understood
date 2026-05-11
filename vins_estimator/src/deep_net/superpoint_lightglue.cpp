#include "superpoint_lightglue.h"
#include "trt_engine.h"
#include <cuda_runtime.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>

namespace dl {

SuperPointLightGlue::SuperPointLightGlue() = default;

SuperPointLightGlue::~SuperPointLightGlue() = default;

bool SuperPointLightGlue::init(const std::string& enginePath, int mode) {
    fprintf(stderr, "[SP] init: mode=%d, engine=%s\n", mode, enginePath.c_str());
    mode_ = mode;

    engine_ = std::make_unique<trt::TrtEngine>();
    if (!engine_->loadEngine(enginePath)) {
        fprintf(stderr, "[SP] Failed to load engine: %s\n", enginePath.c_str());
        return false;
    }

    fprintf(stderr, "[SP] Engine loaded. Inputs: %d, Outputs: %d\n",
            engine_->getNumInputs(), engine_->getNumOutputs());

    for (int i = 0; i < engine_->getNumInputs(); ++i) {
        auto dims = engine_->getInputDims(i);
        fprintf(stderr, "[SP]   Input[%d] %s: [", i, engine_->getInputName(i).c_str());
        for (size_t j = 0; j < dims.size(); ++j) {
            fprintf(stderr, "%d%s", dims[j], j < dims.size() - 1 ? ", " : "");
        }
        fprintf(stderr, "]\n");
    }
    for (int i = 0; i < engine_->getNumOutputs(); ++i) {
        auto dims = engine_->getOutputDims(i);
        fprintf(stderr, "[SP]   Output[%d] %s: [", i, engine_->getOutputName(i).c_str());
        for (size_t j = 0; j < dims.size(); ++j) {
            fprintf(stderr, "%d%s", dims[j], j < dims.size() - 1 ? ", " : "");
        }
        fprintf(stderr, "]\n");
    }

    auto kptsDims = engine_->getOutputDims(0);
    maxKeypoints_ = kptsDims[1];
    fprintf(stderr, "[SP] maxKeypoints=%d\n", maxKeypoints_);

    initialized_ = true;
    return true;
}

void SuperPointLightGlue::setInputSize(int width, int height) {
    modelWidth_ = width;
    modelHeight_ = height;
}

cv::Mat SuperPointLightGlue::preprocessImage(const cv::Mat& image) {
    cv::Mat gray;
    if (image.channels() == 3) {
        cv::cvtColor(image, gray, cv::COLOR_BGR2GRAY);
    } else {
        gray = image.clone();
    }

    cv::Mat resized;
    cv::resize(gray, resized, cv::Size(modelWidth_, modelHeight_));

    cv::Mat floatImg;
    resized.convertTo(floatImg, CV_32FC1, 1.0 / 255.0);

    return floatImg;
}

std::vector<SpFeature> SuperPointLightGlue::extractFeatures(const cv::Mat& image) {
    if (!initialized_ || !engine_) {
        fprintf(stderr, "[SP] extractFeatures: not initialized\n");
        return {};
    }

    int origWidth = image.cols;
    int origHeight = image.rows;

    cv::Mat procImg = preprocessImage(image);

    int imgSize = modelWidth_ * modelHeight_;
    void* inputBuffer = engine_->getInputBuffer(0);
    cudaMemcpyAsync(inputBuffer, procImg.ptr<float>(), imgSize * sizeof(float),
                    cudaMemcpyHostToDevice, engine_->getStream());

    engine_->infer();
    engine_->synchronize();

    void* kptsBuffer = engine_->getOutputBuffer(0);
    void* scoresBuffer = engine_->getOutputBuffer(1);
    void* descBuffer = engine_->getOutputBuffer(2);

    auto kptsDims = engine_->getOutputDims(0);
    int numKpts = kptsDims[1];

    std::vector<float> kptsHost(numKpts * 2);
    std::vector<float> scoresHost(numKpts);
    std::vector<float> descHost(numKpts * 256);

    cudaMemcpy(kptsHost.data(), kptsBuffer, numKpts * 2 * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(scoresHost.data(), scoresBuffer, numKpts * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(descHost.data(), descBuffer, numKpts * 256 * sizeof(float), cudaMemcpyDeviceToHost);

    fprintf(stderr, "[SP] Raw kpts[0..9]: ");
    for (int i = 0; i < std::min(10, numKpts * 2); ++i) fprintf(stderr, "%.1f ", kptsHost[i]);
    fprintf(stderr, "\n");
    fprintf(stderr, "[SP] Raw scores[0..4]: ");
    for (int i = 0; i < std::min(5, numKpts); ++i) fprintf(stderr, "%.4f ", scoresHost[i]);
    fprintf(stderr, "\n");

    float scaleX = static_cast<float>(origWidth) / modelWidth_;
    float scaleY = static_cast<float>(origHeight) / modelHeight_;

    std::vector<SpFeature> features;
    features.reserve(numKpts);

    for (int i = 0; i < numKpts; ++i) {
        float x = kptsHost[i * 2];
        float y = kptsHost[i * 2 + 1];

        if (x <= 0.0f && y <= 0.0f) continue;

        SpFeature feat;
        feat.pt.x = x * scaleX;
        feat.pt.y = y * scaleY;
        feat.pt_norm.x = (x - modelWidth_ / 2.0f) / std::max(modelWidth_ / 2.0f, modelHeight_ / 2.0f);
        feat.pt_norm.y = (y - modelHeight_ / 2.0f) / std::max(modelWidth_ / 2.0f, modelHeight_ / 2.0f);
        feat.score = scoresHost[i];
        feat.desc.assign(descHost.begin() + i * 256, descHost.begin() + (i + 1) * 256);

        features.push_back(feat);
    }

    fprintf(stderr, "[SP] Extracted %d valid features (from %d total)\n",
            (int)features.size(), numKpts);
    for (int i = 0; i < std::min(5, (int)features.size()); ++i) {
        fprintf(stderr, "[SP]   feat[%d]: pt=(%.1f, %.1f) score=%.4f\n",
                i, features[i].pt.x, features[i].pt.y, features[i].score);
    }

    lastFeatures_ = features;
    return features;
}

} // namespace dl