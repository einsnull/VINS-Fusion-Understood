#!/usr/bin/env python3
"""Patch torch.onnx.symbolic_opset9.transpose to handle edge cases."""
import sys

sym_file = sys.argv[1] if len(sys.argv) > 1 else '/usr/local/lib/python3.8/dist-packages/torch/onnx/symbolic_opset9.py'

with open(sym_file, 'r') as f:
    content = f.read()

old = '''    rank = symbolic_helper._get_tensor_rank(self)
    if rank is not None:
        axes = list(range(rank))
        axes[dim0], axes[dim1] = axes[dim1], axes[dim0]
        return g.op("Transpose", self, perm_i=axes)'''

new = '''    rank = symbolic_helper._get_tensor_rank(self)
    if rank is not None:
        if dim0 >= rank or dim1 >= rank:
            rank = max(dim0, dim1) + 1
        axes = list(range(rank))
        axes[dim0], axes[dim1] = axes[dim1], axes[dim0]
        return g.op("Transpose", self, perm_i=axes)'''

if old in content:
    content = content.replace(old, new)
    with open(sym_file, 'w') as f:
        f.write(content)
    print('Patched transpose successfully')
else:
    print('Pattern not found')
    for i, line in enumerate(content.split('\n')):
        if 'axes[dim0], axes[dim1]' in line:
            print(f'  Line {i+1}: {line}')