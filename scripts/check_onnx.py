#!/usr/bin/env python3
import onnx
import sys

model_path = sys.argv[1]
m = onnx.load(model_path)
print(f'Model: {model_path}')
print(f'Opset: {m.opset_import[0].version}')
print('Inputs:')
for inp in m.graph.input:
    dims = [d.dim_value if d.dim_value else 'dynamic' for d in inp.type.tensor_type.shape.dim]
    print(f'  {inp.name}: {dims}')
print('Outputs:')
for out in m.graph.output:
    dims = [d.dim_value if d.dim_value else 'dynamic' for d in out.type.tensor_type.shape.dim]
    print(f'  {out.name}: {dims}')
print()

# Find problematic nodes
for node in m.graph.node:
    if node.op_type in ('MaxPool', 'Resize', 'GridSample'):
        print(f'{node.op_type}: {node.name}')
        for attr in node.attribute:
            if attr.ints:
                print(f'  {attr.name}: {list(attr.ints)}')
            elif attr.i:
                print(f'  {attr.name}: {attr.i}')
        print(f'  inputs: {node.input}')
        print(f'  outputs: {node.output}')
        print()