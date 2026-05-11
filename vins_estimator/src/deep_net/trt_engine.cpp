#include "trt_engine.h"
#include <fstream>
#include <iostream>
#include <NvOnnxParser.h>

namespace trt {

static std::vector<char> readFile(const std::string& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        std::cerr << "Failed to open file: " << path << std::endl;
        return {};
    }
    size_t size = file.tellg();
    file.seekg(0, std::ios::beg);
    std::vector<char> buffer(size);
    file.read(buffer.data(), size);
    return buffer;
}

TrtEngine::~TrtEngine() {
    for (auto& buf : deviceBuffers_) {
        if (buf) cudaFree(buf);
    }
    if (context_) context_->destroy();
    if (engine_) engine_->destroy();
    if (runtime_) runtime_->destroy();
    if (stream_) cudaStreamDestroy(stream_);
}

bool TrtEngine::loadEngine(const std::string& enginePath) {
    fprintf(stderr, "[TRT] loadEngine: %s\n", enginePath.c_str());
    auto engineData = readFile(enginePath);
    if (engineData.empty()) {
        fprintf(stderr, "[TRT] readFile returned empty\n");
        return false;
    }
    fprintf(stderr, "[TRT] read %zu bytes, creating runtime...\n", engineData.size());

    runtime_ = nvinfer1::createInferRuntime(logger_);
    if (!runtime_) {
        fprintf(stderr, "[TRT] Failed to create TensorRT runtime\n");
        return false;
    }
    fprintf(stderr, "[TRT] runtime created, deserializing...\n");

    engine_ = runtime_->deserializeCudaEngine(engineData.data(), engineData.size());
    if (!engine_) {
        fprintf(stderr, "[TRT] Failed to deserialize engine (not a valid engine file)\n");
        return false;
    }
    fprintf(stderr, "[TRT] engine deserialized, creating context...\n");

    context_ = engine_->createExecutionContext();
    if (!context_) {
        std::cerr << "Failed to create execution context" << std::endl;
        return false;
    }

    cudaStreamCreate(&stream_);

    numInputs_ = engine_->getNbBindings();
    // 注意：TensorRT 8+ 使用 getNbIOTensors，这里简化处理
    for (int i = 0; i < engine_->getNbBindings(); ++i) {
        auto dims = engine_->getBindingDimensions(i);
        std::vector<int> dimVec;
        for (int j = 0; j < dims.nbDims; ++j) {
            dimVec.push_back(dims.d[j]);
        }
        
        size_t vol = volume(dimVec);
        void* devicePtr = nullptr;
        cudaMalloc(&devicePtr, vol * sizeof(float));
        deviceBuffers_.push_back(devicePtr);
        
        if (engine_->bindingIsInput(i)) {
            inputDims_.push_back(dimVec);
            inputNames_.push_back(engine_->getBindingName(i));
        } else {
            outputDims_.push_back(dimVec);
            outputNames_.push_back(engine_->getBindingName(i));
        }
    }
    
    numInputs_ = inputNames_.size();
    numOutputs_ = outputNames_.size();

    return true;
}

bool TrtEngine::buildEngineFromOnnx(const std::string& onnxPath,
                                     const std::string& enginePath,
                                     int maxBatchSize,
                                     bool fp16) {
    auto builder = nvinfer1::createInferBuilder(logger_);
    if (!builder) {
        std::cerr << "Failed to create builder" << std::endl;
        return false;
    }

    const auto explicitBatch = 1U << static_cast<uint32_t>(nvinfer1::NetworkDefinitionCreationFlag::kEXPLICIT_BATCH);
    auto network = builder->createNetworkV2(explicitBatch);
    if (!network) {
        std::cerr << "Failed to create network" << std::endl;
        return false;
    }

    auto parser = nvonnxparser::createParser(*network, logger_);
    if (!parser->parseFromFile(onnxPath.c_str(), static_cast<int>(nvinfer1::ILogger::Severity::kWARNING))) {
        std::cerr << "Failed to parse ONNX file" << std::endl;
        return false;
    }

    auto config = builder->createBuilderConfig();
    if (fp16) {
        config->setFlag(nvinfer1::BuilderFlag::kFP16);
    }
    config->setMaxWorkspaceSize(1 << 30); // 1GB

    auto profile = builder->createOptimizationProfile();
    // 设置动态输入形状（简化处理）
    auto inputName = network->getInput(0)->getName();
    auto inputDims = network->getInput(0)->getDimensions();
    if (inputDims.nbDims > 0) {
        nvinfer1::Dims minDims = inputDims;
        nvinfer1::Dims optDims = inputDims;
        nvinfer1::Dims maxDims = inputDims;
        minDims.d[0] = 1;
        optDims.d[0] = maxBatchSize;
        maxDims.d[0] = maxBatchSize;
        profile->setDimensions(inputName, nvinfer1::OptProfileSelector::kMIN, minDims);
        profile->setDimensions(inputName, nvinfer1::OptProfileSelector::kOPT, optDims);
        profile->setDimensions(inputName, nvinfer1::OptProfileSelector::kMAX, maxDims);
        config->addOptimizationProfile(profile);
    }

    auto engine = builder->buildEngineWithConfig(*network, *config);
    if (!engine) {
        std::cerr << "Failed to build engine" << std::endl;
        return false;
    }

    // 保存引擎
    auto serialized = engine->serialize();
    std::ofstream file(enginePath, std::ios::binary);
    file.write(static_cast<const char*>(serialized->data()), serialized->size());
    
    serialized->destroy();
    engine->destroy();
    parser->destroy();
    network->destroy();
    config->destroy();
    builder->destroy();

    // 加载刚保存的引擎
    return loadEngine(enginePath);
}

bool TrtEngine::infer() {
    if (!context_) return false;
    return context_->enqueueV2(deviceBuffers_.data(), stream_, nullptr);
}

void* TrtEngine::getInputBuffer(int index) {
    if (index < 0 || index >= numInputs_) return nullptr;
    int bufIdx = 0;
    for (int i = 0; i < engine_->getNbBindings(); ++i) {
        if (engine_->bindingIsInput(i)) {
            if (bufIdx == index) return deviceBuffers_[i];
            bufIdx++;
        }
    }
    return nullptr;
}

void* TrtEngine::getOutputBuffer(int index) {
    if (index < 0 || index >= numOutputs_) return nullptr;
    int bufIdx = 0;
    for (int i = 0; i < engine_->getNbBindings(); ++i) {
        if (!engine_->bindingIsInput(i)) {
            if (bufIdx == index) return deviceBuffers_[i];
            bufIdx++;
        }
    }
    return nullptr;
}

std::vector<int> TrtEngine::getInputDims(int index) {
    if (index < 0 || index >= static_cast<int>(inputDims_.size())) return {};
    return inputDims_[index];
}

std::vector<int> TrtEngine::getOutputDims(int index) {
    if (index < 0 || index >= static_cast<int>(outputDims_.size())) return {};
    return outputDims_[index];
}

std::string TrtEngine::getInputName(int index) {
    if (index < 0 || index >= static_cast<int>(inputNames_.size())) return "";
    return inputNames_[index];
}

std::string TrtEngine::getOutputName(int index) {
    if (index < 0 || index >= static_cast<int>(outputNames_.size())) return "";
    return outputNames_[index];
}

bool TrtEngine::setInputDims(int index, const std::vector<int>& dims) {
    if (index < 0 || index >= numInputs_) return false;
    int bufIdx = 0;
    for (int i = 0; i < engine_->getNbBindings(); ++i) {
        if (engine_->bindingIsInput(i)) {
            if (bufIdx == index) {
                nvinfer1::Dims trtDims;
                trtDims.nbDims = dims.size();
                for (size_t j = 0; j < dims.size(); ++j) {
                    trtDims.d[j] = dims[j];
                }
                if (!context_->setBindingDimensions(i, trtDims)) {
                    return false;
                }
                // 重新分配内存
                cudaFree(deviceBuffers_[i]);
                size_t vol = volume(dims);
                cudaMalloc(&deviceBuffers_[i], vol * sizeof(float));
                inputDims_[index] = dims;
                return true;
            }
            bufIdx++;
        }
    }
    return false;
}

void TrtEngine::synchronize() {
    if (stream_) cudaStreamSynchronize(stream_);
}

size_t TrtEngine::volume(const std::vector<int>& dims) {
    size_t vol = 1;
    for (auto d : dims) {
        if (d > 0) vol *= d;
    }
    return vol;
}

} // namespace trt
