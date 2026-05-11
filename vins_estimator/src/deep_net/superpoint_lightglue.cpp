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

bool SuperPointLightGlue::init(const std::string& enginePath, int mode, const std::string& spEnginePath) {
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

    if (mode_ == 1 && !spEnginePath.empty()) {
        spEngine_ = std::make_unique<trt::TrtEngine>();
        if (!spEngine_->loadEngine(spEnginePath)) {
            fprintf(stderr, "[SP] Failed to load SP engine: %s\n", spEnginePath.c_str());
            spEngine_.reset();
        } else {
            fprintf(stderr, "[SP] SuperPoint engine loaded for first-frame extraction\n");
        }
    }

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
    if (!initialized_) {
        fprintf(stderr, "[SP] extractFeatures: not initialized\n");
        return {};
    }

    trt::TrtEngine* activeEngine = (mode_ == 1 && spEngine_) ? spEngine_.get() : engine_.get();
    if (!activeEngine) {
        fprintf(stderr, "[SP] extractFeatures: no engine available\n");
        return {};
    }

    int origWidth = image.cols;
    int origHeight = image.rows;

    cv::Mat procImg = preprocessImage(image);

    int imgSize = modelWidth_ * modelHeight_;
    void* inputBuffer = activeEngine->getInputBuffer(0);
    cudaMemcpyAsync(inputBuffer, procImg.ptr<float>(), imgSize * sizeof(float),
                    cudaMemcpyHostToDevice, activeEngine->getStream());

    activeEngine->infer();
    activeEngine->synchronize();

    void* kptsBuffer = activeEngine->getOutputBuffer(0);
    void* scoresBuffer = activeEngine->getOutputBuffer(1);
    void* descBuffer = activeEngine->getOutputBuffer(2);

    auto kptsDims = activeEngine->getOutputDims(0);
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

cv::Mat SuperPointLightGlue::preprocessImageForPipeline(const cv::Mat& image) {
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

MatchResult SuperPointLightGlue::matchFeatures(const cv::Mat& img0, const cv::Mat& img1) {
    MatchResult result;

    if (!initialized_ || !engine_) {
        fprintf(stderr, "[SP-LG] matchFeatures: not initialized\n");
        return result;
    }

    if (mode_ != 1) {
        fprintf(stderr, "[SP-LG] matchFeatures: wrong mode=%d, need mode=1\n", mode_);
        return result;
    }

    int origWidth0 = img0.cols, origHeight0 = img0.rows;
    int origWidth1 = img1.cols, origHeight1 = img1.rows;

    cv::Mat proc0 = preprocessImageForPipeline(img0);
    cv::Mat proc1 = preprocessImageForPipeline(img1);

    int imgSize = modelWidth_ * modelHeight_;
    std::vector<float> batchData(imgSize * 2);
    std::memcpy(batchData.data(), proc0.ptr<float>(), imgSize * sizeof(float));
    std::memcpy(batchData.data() + imgSize, proc1.ptr<float>(), imgSize * sizeof(float));

    void* inputBuffer = engine_->getInputBuffer(0);
    cudaMemcpyAsync(inputBuffer, batchData.data(), imgSize * 2 * sizeof(float),
                    cudaMemcpyHostToDevice, engine_->getStream());

    engine_->infer();
    engine_->synchronize();

    int outputBindingIdx0 = -1, outputBindingIdx1 = -1, outputBindingIdx2 = -1;
    for (int i = 0; i < engine_->getNumBindings(); ++i) {
        if (!engine_->isInput(i)) {
            if (outputBindingIdx0 == -1) outputBindingIdx0 = i;
            else if (outputBindingIdx1 == -1) outputBindingIdx1 = i;
            else if (outputBindingIdx2 == -1) outputBindingIdx2 = i;
        }
    }

    auto actualKptsDims = engine_->getActualBindingDims(outputBindingIdx0);
    int numKpts = actualKptsDims.size() > 1 ? actualKptsDims[1] : 0;

    auto actualMatchesDims = engine_->getActualBindingDims(outputBindingIdx1);
    int numMatches = actualMatchesDims.size() > 0 ? actualMatchesDims[0] : 0;

    void* kptsBuffer = engine_->getOutputBuffer(0);
    void* matchesBuffer = engine_->getOutputBuffer(1);
    void* mscoresBuffer = engine_->getOutputBuffer(2);

    std::vector<int> kptsHost(2 * numKpts * 2);
    std::vector<int> matchesHost(numMatches * 3);
    std::vector<float> mscoresHost(numMatches);

    cudaMemcpy(kptsHost.data(), kptsBuffer, 2 * numKpts * 2 * sizeof(int), cudaMemcpyDeviceToHost);
    cudaMemcpy(matchesHost.data(), matchesBuffer, numMatches * 3 * sizeof(int), cudaMemcpyDeviceToHost);
    cudaMemcpy(mscoresHost.data(), mscoresBuffer, numMatches * sizeof(float), cudaMemcpyDeviceToHost);

    float scaleX0 = static_cast<float>(origWidth0) / modelWidth_;
    float scaleY0 = static_cast<float>(origHeight0) / modelHeight_;
    float scaleX1 = static_cast<float>(origWidth1) / modelWidth_;
    float scaleY1 = static_cast<float>(origHeight1) / modelHeight_;

    for (int i = 0; i < numKpts; ++i) {
        int x0 = kptsHost[i * 2];
        int y0 = kptsHost[i * 2 + 1];

        if (x0 > 0 || y0 > 0) {
            SpFeature feat;
            feat.pt.x = x0 * scaleX0;
            feat.pt.y = y0 * scaleY0;
            feat.pt_norm.x = (x0 - modelWidth_ / 2.0f) / std::max(modelWidth_ / 2.0f, modelHeight_ / 2.0f);
            feat.pt_norm.y = (y0 - modelHeight_ / 2.0f) / std::max(modelWidth_ / 2.0f, modelHeight_ / 2.0f);
            feat.score = 1.0f;
            result.features0.push_back(feat);
        }
    }

    for (int i = 0; i < numKpts; ++i) {
        int x1 = kptsHost[numKpts * 2 + i * 2];
        int y1 = kptsHost[numKpts * 2 + i * 2 + 1];

        if (x1 > 0 || y1 > 0) {
            SpFeature feat;
            feat.pt.x = x1 * scaleX1;
            feat.pt.y = y1 * scaleY1;
            feat.pt_norm.x = (x1 - modelWidth_ / 2.0f) / std::max(modelWidth_ / 2.0f, modelHeight_ / 2.0f);
            feat.pt_norm.y = (y1 - modelHeight_ / 2.0f) / std::max(modelWidth_ / 2.0f, modelHeight_ / 2.0f);
            feat.score = 1.0f;
            result.features1.push_back(feat);
        }
    }

    for (int i = 0; i < numMatches; ++i) {
        int batchIdx = matchesHost[i * 3];
        int idx0 = matchesHost[i * 3 + 1];
        int idx1 = matchesHost[i * 3 + 2];
        float score = mscoresHost[i];

        if (batchIdx == 0 && idx0 >= 0 && idx1 >= 0 &&
            idx0 < (int)result.features0.size() && idx1 < (int)result.features1.size()) {
            Match m;
            m.queryIdx = idx0;
            m.trainIdx = idx1;
            m.score = score;
            result.matches.push_back(m);
        }
    }

    return result;
}

} // namespace dl