#!/usr/bin/env python3
"""
Convert ONNX models to TensorRT engines for SuperPoint and LightGlue.
Usage:
    python3 convert_onnx_to_trt.py --onnx /path/to/model.onnx --output /path/to/model.engine --fp16
"""

import argparse
import sys
import os

try:
    import tensorrt as trt
except ImportError:
    print("Error: TensorRT not installed. Please install TensorRT first.")
    sys.exit(1)

import numpy as np


class TensorRTConverter:
    def __init__(self, verbose=False):
        self.logger = trt.Logger(trt.Logger.VERBOSE if verbose else trt.Logger.WARNING)
        self.builder = trt.Builder(self.logger)
        
    def build_engine(self, onnx_path, output_path, fp16=True, max_batch_size=1, 
                     max_workspace_size=1<<30):
        """Build TensorRT engine from ONNX model"""
        
        print(f"Loading ONNX model from: {onnx_path}")
        
        # Create network
        network_flags = 1 << int(trt.NetworkDefinitionCreationFlag.EXPLICIT_BATCH)
        network = self.builder.create_network(network_flags)
        parser = trt.OnnxParser(network, self.logger)
        
        # Parse ONNX
        with open(onnx_path, 'rb') as f:
            if not parser.parse(f.read()):
                print("ERROR: Failed to parse ONNX file")
                for error in range(parser.num_errors):
                    print(parser.get_error(error))
                return False
        
        print(f"ONNX model parsed successfully.")
        print(f"Network inputs: {network.num_inputs}")
        print(f"Network outputs: {network.num_outputs}")
        
        # Create builder config
        config = self.builder.create_builder_config()
        config.max_workspace_size = max_workspace_size
        
        if fp16:
            config.set_flag(trt.BuilderFlag.FP16)
            print("FP16 mode enabled")
        
        # Set optimization profiles for dynamic shapes
        profile = self.builder.create_optimization_profile()
        
        for i in range(network.num_inputs):
            input_tensor = network.get_input(i)
            name = input_tensor.name
            shape = input_tensor.shape
            
            print(f"Input {i}: {name}, shape: {shape}")
            
            # Handle dynamic shapes
            if shape[0] == -1 or shape[0] == 'batch_size':
                min_shape = list(shape)
                opt_shape = list(shape)
                max_shape = list(shape)
                min_shape[0] = 1
                opt_shape[0] = max_batch_size
                max_shape[0] = max_batch_size
                
                profile.set_shape(name, min_shape, opt_shape, max_shape)
                print(f"  Dynamic batch: min={min_shape}, opt={opt_shape}, max={max_shape}")
        
        if network.num_inputs > 0:
            config.add_optimization_profile(profile)
        
        # Build engine
        print("Building TensorRT engine...")
        engine = self.builder.build_engine(network, config)
        
        if engine is None:
            print("ERROR: Failed to build engine")
            return False
        
        # Save engine
        print(f"Saving engine to: {output_path}")
        with open(output_path, 'wb') as f:
            f.write(engine.serialize())
        
        print("Engine built and saved successfully!")
        return True


def main():
    parser = argparse.ArgumentParser(description='Convert ONNX to TensorRT')
    parser.add_argument('--onnx', required=True, help='Path to ONNX model')
    parser.add_argument('--output', required=True, help='Path to output engine file')
    parser.add_argument('--fp16', action='store_true', help='Use FP16 precision')
    parser.add_argument('--batch-size', type=int, default=1, help='Max batch size')
    parser.add_argument('--workspace', type=int, default=1024, help='Max workspace size in MB')
    parser.add_argument('--verbose', action='store_true', help='Verbose output')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.onnx):
        print(f"Error: ONNX file not found: {args.onnx}")
        sys.exit(1)
    
    converter = TensorRTConverter(verbose=args.verbose)
    success = converter.build_engine(
        args.onnx, 
        args.output, 
        fp16=args.fp16,
        max_batch_size=args.batch_size,
        max_workspace_size=args.workspace * (1 << 20)
    )
    
    if not success:
        sys.exit(1)


if __name__ == '__main__':
    main()
