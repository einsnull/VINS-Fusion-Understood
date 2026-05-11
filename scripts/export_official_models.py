#!/usr/bin/env python3
"""
Export official SuperPoint and LightGlue models to ONNX format.

Official repos:
- SuperPoint: magicleap/SuperPointPretrainedNetwork (pretrained weights)
- LightGlue: cvg/LightGlue (includes SuperPoint implementation + LightGlue matcher)

We use the SuperPoint implementation from cvg/LightGlue which is compatible
with the LightGlue matcher and uses the official pretrained weights.
"""

import os
import sys
import argparse
import numpy as np
import torch
import torch.onnx

# Add LightGlue repo to path
sys.path.insert(0, '/LightGlue')


def export_superpoint(output_path, image_size=1024, max_keypoints=2048):
    """Export SuperPoint to ONNX.
    
    Input: image (1, 1, H, W) grayscale float32
    Output: keypoints (N, 2) int64, scores (N,) float32, descriptors (N, 256) float32
    """
    from lightglue import SuperPoint
    import lightglue.superpoint as sp_module
    
    # Patch simple_nms to add channel dim for ONNX compatibility
    _original_simple_nms = sp_module.simple_nms
    def _patched_simple_nms(scores, nms_radius):
        def max_pool(x):
            if x.dim() == 3:
                x = x.unsqueeze(1)
                result = torch.nn.functional.max_pool2d(
                    x, kernel_size=nms_radius * 2 + 1, stride=1, padding=nms_radius
                )
                return result.squeeze(1)
            return torch.nn.functional.max_pool2d(
                x, kernel_size=nms_radius * 2 + 1, stride=1, padding=nms_radius
            )
        zeros = torch.zeros_like(scores)
        max_mask = scores == max_pool(scores)
        for _ in range(2):
            supp_mask = max_pool(max_mask.float()) > 0
            supp_scores = torch.where(supp_mask, zeros, scores)
            new_max_mask = supp_scores == max_pool(supp_scores)
            max_mask = max_mask | (new_max_mask & (~supp_mask))
        return torch.where(max_mask, scores, zeros)
    sp_module.simple_nms = _patched_simple_nms
    
    print(f"[SuperPoint] Creating model with max_keypoints={max_keypoints}...")
    model = SuperPoint(max_num_keypoints=max_keypoints).eval().cuda()
    
    H, W = image_size, image_size
    dummy_input = torch.randn(1, 1, H, W, device='cuda')
    
    # SuperPoint forward returns a dict with: keypoints, keypoint_scores, descriptors
    # We need to trace the model
    print(f"[SuperPoint] Tracing model with input shape (1, 1, {H}, {W})...")
    
    class SuperPointWrapper(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model
            
        def forward(self, image):
            # image: (1, 1, H, W) float32, values in [0, 1] or [0, 255]
            result = self.model({'image': image})
            # result contains: keypoints (B, N, 2), keypoint_scores (B, N), descriptors (B, N, D)
            kpts = result['keypoints']      # (1, N, 2)
            scores = result['keypoint_scores']  # (1, N)
            desc = result['descriptors']    # (1, N, 256)
            return kpts, scores, desc
    
    wrapped = SuperPointWrapper(model)
    
    # Do a test forward pass first
    with torch.no_grad():
        kpts, scores, desc = wrapped(dummy_input)
        print(f"[SuperPoint] Test forward: keypoints shape={kpts.shape}, scores shape={scores.shape}, descriptors shape={desc.shape}")
    
    torch.onnx.export(
        wrapped,
        dummy_input,
        output_path,
        input_names=['image'],
        output_names=['keypoints', 'scores', 'descriptors'],
        opset_version=17,
        do_constant_folding=True,
    )
    print(f"[SuperPoint] Exported to {output_path}")
    
    # Verify
    import onnx
    model_onnx = onnx.load(output_path)
    onnx.checker.check_model(model_onnx)
    print(f"[SuperPoint] ONNX model verified OK")


def export_lightglue(output_path, max_keypoints=1024, descriptor_dim=256):
    """Export LightGlue to ONNX with fixed parameters for TensorRT.
    
    Input: 
        keypoints0 (1, N, 2) float32 - normalized to [0,1]
        descriptors0 (1, N, 256) float32
        image_size0 (1, 2) float32 - (width, height) of image0
        keypoints1 (1, N, 2) float32 - normalized to [0,1]
        descriptors1 (1, N, 256) float32
        image_size1 (1, 2) float32 - (width, height) of image1
    Output:
        matches0 (1, N) int64 - indices in image0, -1 = no match
        matches1 (1, N) int64 - indices in image1, -1 = no match
        mscores (1, N) float32 - match confidence scores
    """
    from lightglue import LightGlue
    
    print(f"[LightGlue] Patching LightGlue for ONNX compatibility...")
    import lightglue.lightglue as lg_module
    
    # Fix 0: Replace torch.unflatten with reshape globally
    _original_unflatten = torch.Tensor.unflatten
    def _patched_unflatten(self, dim, sizes):
        shape = list(self.shape)
        if dim < 0:
            dim = len(shape) + dim
        total = shape[dim]
        known_prod = 1
        neg_count = 0
        for s in sizes:
            if s == -1:
                neg_count += 1
            else:
                known_prod *= s
        inferred = total // known_prod if known_prod > 0 else total
        resolved_sizes = [inferred if s == -1 else s for s in sizes]
        new_shape = shape[:dim] + resolved_sizes + shape[dim+1:]
        return self.reshape(new_shape)
    torch.Tensor.unflatten = _patched_unflatten
    
    # Fix 0.5: Monkey-patch _get_tensor_sizes to handle edge cases
    import torch.onnx.symbolic_helper as sym_helper
    _original_get_tensor_sizes = sym_helper._get_tensor_sizes
    def _patched_get_tensor_sizes(g, self=None):
        try:
            if self is None:
                return _original_get_tensor_sizes(g)
            return _original_get_tensor_sizes(g, self)
        except Exception:
            return None
    sym_helper._get_tensor_sizes = _patched_get_tensor_sizes
    
    # Also patch transpose directly
    import torch.onnx.symbolic_opset9 as sym_opset9
    _original_transpose = sym_opset9.transpose
    def _patched_transpose(g, self, dim0, dim1):
        if dim0 == dim1:
            return self
        sizes = sym_helper._get_tensor_sizes(g, self)
        if sizes is None:
            return g.op("Transpose", self, perm_i=[dim0, dim1])
        rank = len(sizes)
        if dim0 >= rank or dim1 >= rank:
            return g.op("Transpose", self, perm_i=[dim0, dim1])
        axes = list(range(rank))
        axes[dim0], axes[dim1] = axes[dim1], axes[dim0]
        return g.op("Transpose", self, perm_i=axes)
    sym_opset9.transpose = _patched_transpose
    
    # Fix 1: Replace unflatten/flatten with hardcoded reshape in SelfBlock
    # D=256, num_heads=4, head_dim=64
    _original_self_block_forward = lg_module.SelfBlock.forward
    def _patched_self_block_forward(self, x, encoding, mask=None):
        qkv = self.Wqkv(x)
        B, N = x.shape[0], x.shape[1]
        qkv = qkv.reshape(B, N, 4, 64, 3).transpose(1, 2)
        q, k, v = qkv[..., 0], qkv[..., 1], qkv[..., 2]
        q = lg_module.apply_cached_rotary_emb(encoding, q)
        k = lg_module.apply_cached_rotary_emb(encoding, k)
        context = self.inner_attn(q, k, v, mask=mask)
        message = self.out_proj(context.transpose(1, 2).reshape(B, N, 256))
        result = torch.cat([x.reshape(B, N, 256), message.reshape(B, N, 256)], dim=2)
        return x + self.ffn(result)
    lg_module.SelfBlock.forward = _patched_self_block_forward

    # Fix 1b: Replace unflatten/flatten with hardcoded reshape in CrossBlock
    _original_cross_block_forward = lg_module.CrossBlock.forward
    def _patched_cross_block_forward(self, x0, x1, mask=None):
        qk0, qk1 = self.map_(self.to_qk, x0, x1)
        v0, v1 = self.map_(self.to_v, x0, x1)
        qk0 = qk0.reshape(qk0.shape[0], qk0.shape[1], 4, 64).transpose(1, 2)
        qk1 = qk1.reshape(qk1.shape[0], qk1.shape[1], 4, 64).transpose(1, 2)
        v0 = v0.reshape(v0.shape[0], v0.shape[1], 4, 64).transpose(1, 2)
        v1 = v1.reshape(v1.shape[0], v1.shape[1], 4, 64).transpose(1, 2)
        if self.flash is not None and qk0.device.type == "cuda":
            m0 = self.flash(qk0, qk1, v1, mask)
            m1 = self.flash(qk1, qk0, v0, mask.transpose(-1, -2) if mask is not None else None)
        else:
            qk0, qk1 = qk0 * self.scale**0.5, qk1 * self.scale**0.5
            sim = torch.einsum("bhid, bhjd -> bhij", qk0, qk1)
            if mask is not None:
                sim = sim.masked_fill(~mask, -float("inf"))
            attn01 = torch.nn.functional.softmax(sim, dim=-1)
            attn10 = torch.nn.functional.softmax(sim.transpose(-2, -1).contiguous(), dim=-1)
            m0 = torch.einsum("bhij, bhjd -> bhid", attn01, v1)
            m1 = torch.einsum("bhji, bhjd -> bhid", attn10.transpose(-2, -1), v0)
            if mask is not None:
                m0, m1 = m0.nan_to_num(), m1.nan_to_num()
        m0 = m0.transpose(1, 2).reshape(m0.shape[0], m0.shape[2], 256)
        m1 = m1.transpose(1, 2).reshape(m1.shape[0], m1.shape[2], 256)
        m0, m1 = self.map_(self.to_out, m0, m1)
        x0 = x0 + self.ffn(torch.cat([x0.reshape(x0.shape[0], x0.shape[1], 256), m0.reshape(m0.shape[0], m0.shape[1], 256)], dim=2))
        x1 = x1 + self.ffn(torch.cat([x1.reshape(x1.shape[0], x1.shape[1], 256), m1.reshape(m1.shape[0], m1.shape[1], 256)], dim=2))
        return x0, x1
    lg_module.CrossBlock.forward = _patched_cross_block_forward
    
    # Fix 2: Convert class attributes for dynamo compatibility
    lg_module.LightGlue.required_data_keys = tuple(lg_module.LightGlue.required_data_keys)
    lg_module.LightGlue.pruning_keypoint_thresholds = {"cpu": -1, "mps": -1, "cuda": -1, "flash": -1}
    lg_module.LightGlue.default_conf["width_confidence"] = -1
    lg_module.LightGlue.default_conf["depth_confidence"] = -1
    
    lg_module.LightGlue.pruning_min_kpts = lambda self, device: -1
    
    # Fix 2b: Patch sigmoid_log_double_softmax to use reshape instead of squeeze
    _original_slds = lg_module.sigmoid_log_double_softmax
    def _patched_slds(sim, z0, z1):
        b, m, n = sim.shape
        certainties = torch.nn.functional.logsigmoid(z0) + torch.nn.functional.logsigmoid(z1).transpose(1, 2)
        scores0 = torch.nn.functional.log_softmax(sim, 2)
        scores1 = torch.nn.functional.log_softmax(sim.transpose(-1, -2).contiguous(), 2).transpose(-1, -2)
        scores = sim.new_full((b, m + 1, n + 1), 0)
        scores[:, :m, :n] = scores0 + scores1 + certainties
        scores[:, :-1, -1] = torch.nn.functional.logsigmoid(-z0.reshape(b, m))
        scores[:, -1, :-1] = torch.nn.functional.logsigmoid(-z1.reshape(b, n))
        return scores
    lg_module.sigmoid_log_double_softmax = _patched_slds
    
    # Also patch get_matchability to use reshape
    _original_matchability = lg_module.MatchAssignment.get_matchability
    def _patched_get_matchability(self, desc):
        return torch.sigmoid(self.matchability(desc)).reshape(desc.shape[0], desc.shape[1])
    lg_module.MatchAssignment.get_matchability = _patched_get_matchability
    
    print(f"[LightGlue] Creating model with fixed params (n_layers=9, no early stop)...")
    model = LightGlue(
        features='superpoint',
        n_layers=9,
        depth_confidence=-1,   # disable early stopping
        width_confidence=-1,   # disable point pruning
        flash=True,
    ).eval().cuda()
    
    N = max_keypoints
    H, W = 1024, 1024
    dummy_kpts0 = torch.rand(1, N, 2, device='cuda')
    dummy_kpts1 = torch.rand(1, N, 2, device='cuda')
    dummy_desc0 = torch.randn(1, N, descriptor_dim, device='cuda')
    dummy_desc1 = torch.randn(1, N, descriptor_dim, device='cuda')
    dummy_size0 = torch.tensor([[W, H]], device='cuda', dtype=torch.float32)
    dummy_size1 = torch.tensor([[W, H]], device='cuda', dtype=torch.float32)
    
    print(f"[LightGlue] Tracing model with {N} keypoints...")
    
    class LightGlueWrapper(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model
            
        def forward(self, kpts0, desc0, size0, kpts1, desc1, size1):
            data = {
                'image0': {
                    'keypoints': kpts0,
                    'descriptors': desc0,
                    'image_size': size0,
                },
                'image1': {
                    'keypoints': kpts1,
                    'descriptors': desc1,
                    'image_size': size1,
                },
            }
            result = self.model(data)
            m0 = result['matches0']
            m1 = result['matches1']
            mscores = result.get('matching_scores0', result.get('matching_scores1'))
            if mscores is None:
                mscores = torch.ones_like(m0, dtype=torch.float32)
            return m0, m1, mscores
    
    wrapped = LightGlueWrapper(model)
    
    with torch.no_grad():
        m0, m1, mscores = wrapped(dummy_kpts0, dummy_desc0, dummy_size0,
                                   dummy_kpts1, dummy_desc1, dummy_size1)
        print(f"[LightGlue] Test forward: matches0 shape={m0.shape}, matches1 shape={m1.shape}, mscores shape={mscores.shape}")
    
    print(f"[LightGlue] Exporting with torch.onnx.export (TorchScript path, opset 17)...")
    torch.onnx.export(
        wrapped,
        (dummy_kpts0, dummy_desc0, dummy_size0, dummy_kpts1, dummy_desc1, dummy_size1),
        output_path,
        input_names=['keypoints0', 'descriptors0', 'image_size0',
                     'keypoints1', 'descriptors1', 'image_size1'],
        output_names=['matches0', 'matches1', 'mscores'],
        opset_version=17,
        do_constant_folding=True,
    )
    print(f"[LightGlue] Exported to {output_path}")
    
    import onnx
    from onnx import shape_inference
    model_onnx = onnx.load(output_path)
    print(f"[LightGlue] Running shape inference...")
    inferred = shape_inference.infer_shapes(model_onnx, check_type=True, strict_mode=False)
    onnx.save(inferred, output_path)
    print(f"[LightGlue] Shape inference done, saved to {output_path}")
    
    model_onnx = onnx.load(output_path)
    onnx.checker.check_model(model_onnx)
    print(f"[LightGlue] ONNX model verified OK")


def main():
    parser = argparse.ArgumentParser(description='Export official SuperPoint and LightGlue to ONNX')
    parser.add_argument('--output-dir', type=str, default='/output',
                        help='Output directory for ONNX models')
    parser.add_argument('--image-size', type=int, default=1024,
                        help='Input image size (square)')
    parser.add_argument('--max-keypoints', type=int, default=2048,
                        help='Maximum number of keypoints')
    parser.add_argument('--skip-superpoint', action='store_true',
                        help='Skip SuperPoint export')
    parser.add_argument('--skip-lightglue', action='store_true',
                        help='Skip LightGlue export')
    args = parser.parse_args()
    
    os.makedirs(args.output_dir, exist_ok=True)
    
    # Clone LightGlue repo if not already present
    if not os.path.exists('/LightGlue'):
        print("Cloning LightGlue repository...")
        os.system('GIT_SSL_NO_VERIFY=1 git clone --depth 1 https://github.com/cvg/LightGlue.git /LightGlue')
        os.system('pip3 install -e /LightGlue -q 2>&1 | tail -2')
    
    if not args.skip_superpoint:
        sp_path = os.path.join(args.output_dir, 'superpoint_official.onnx')
        export_superpoint(sp_path, args.image_size, args.max_keypoints)
    
    if not args.skip_lightglue:
        lg_path = os.path.join(args.output_dir, 'lightglue_official.onnx')
        export_lightglue(lg_path, args.max_keypoints)
    
    print("\n=== Export Complete ===")
    print(f"Output directory: {args.output_dir}")
    for f in os.listdir(args.output_dir):
        if f.endswith('.onnx'):
            size_mb = os.path.getsize(os.path.join(args.output_dir, f)) / (1024*1024)
            print(f"  {f}: {size_mb:.1f} MB")


if __name__ == '__main__':
    main()