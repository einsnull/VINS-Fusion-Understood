#pragma once

#include <NvInfer.h>
#include <cuda_runtime.h>
#include <memory>
#include <vector>
#include <string>
#include <opencv2/opencv.hpp>

#include "trt_logger.h"

namespace trt {

// 简单的TensorRT引擎封装
class TrtEngine {
public:
    TrtEngine() = default;
    ~TrtEngine();

    // 从引擎文件加载
    bool loadEngine(const std::string& enginePath);
    
    // 从ONNX文件构建引擎
    bool buildEngineFromOnnx(const std::string& onnxPath, 
                             const std::string& enginePath,
                             int maxBatchSize = 1,
                             bool fp16 = true);

    // 执行推理
    bool infer();

    // 获取输入/输出缓冲区
    void* getInputBuffer(int index = 0);
    void* getOutputBuffer(int index = 0);
    
    // 获取输入/输出维度
    std::vector<int> getInputDims(int index = 0);
    std::vector<int> getOutputDims(int index = 0);
    
    // 获取输入/输出名称
    std::string getInputName(int index = 0);
    std::string getOutputName(int index = 0);
    
    // 设置输入维度（动态批次）
    bool setInputDims(int index, const std::vector<int>& dims);
    
    // 同步CUDA流
    void synchronize();
    
    // 获取CUDA流
    cudaStream_t getStream() { return stream_; }

    int getNumInputs() const { return numInputs_; }
    int getNumOutputs() const { return numOutputs_; }

private:
    TrtLogger logger_;
    nvinfer1::IRuntime* runtime_ = nullptr;
    nvinfer1::ICudaEngine* engine_ = nullptr;
    nvinfer1::IExecutionContext* context_ = nullptr;
    cudaStream_t stream_ = nullptr;
    
    int numInputs_ = 0;
    int numOutputs_ = 0;
    
    std::vector<void*> deviceBuffers_;
    std::vector<std::vector<int>> inputDims_;
    std::vector<std::vector<int>> outputDims_;
    std::vector<std::string> inputNames_;
    std::vector<std::string> outputNames_;
    
    // 计算体积
    size_t volume(const std::vector<int>& dims);
};

} // namespace trt
