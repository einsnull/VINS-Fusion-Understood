#!/usr/bin/env python3
"""
Compare VINS-Fusion trajectory with EuRoC ground truth
"""

import sys
import numpy as np
import csv
from pathlib import Path

def load_groundtruth(gt_file):
    """Load EuRoC ground truth CSV file"""
    timestamps = []
    positions = []
    
    with open(gt_file, 'r') as f:
        reader = csv.reader(f)
        header = next(reader)  # Skip header
        
        for row in reader:
            if row[0].startswith('#'):
                continue
            
            timestamp = float(row[0]) / 1e9  # Convert to seconds
            px, py, pz = float(row[1]), float(row[2]), float(row[3])
            
            timestamps.append(timestamp)
            positions.append([px, py, pz])
    
    return np.array(timestamps), np.array(positions)

def load_vins_trajectory(bag_file):
    """Load VINS trajectory from bag file"""
    try:
        import rosbag
        from nav_msgs.msg import Odometry
        
        timestamps = []
        positions = []
        
        with rosbag.Bag(bag_file, 'r') as bag:
            for topic, msg, t in bag.read_messages(topics=['/vins_estimator/odometry']):
                timestamps.append(msg.header.stamp.to_sec())
                positions.append([
                    msg.pose.pose.position.x,
                    msg.pose.pose.position.y,
                    msg.pose.pose.position.z
                ])
        
        return np.array(timestamps), np.array(positions)
    except ImportError:
        print("Error: rosbag not available. Make sure ROS is sourced.")
        return None, None

def compute_ate(gt_positions, est_positions):
    """Compute Absolute Trajectory Error (ATE)"""
    # Align trajectories (simple version - assumes same starting point)
    gt_mean = np.mean(gt_positions, axis=0)
    est_mean = np.mean(est_positions, axis=0)
    
    # Center trajectories
    gt_centered = gt_positions - gt_mean
    est_centered = est_positions - est_mean
    
    # Compute optimal rotation using SVD
    H = est_centered.T @ gt_centered
    U, S, Vt = np.linalg.svd(H)
    R = Vt.T @ U.T
    
    # Ensure proper rotation (det(R) = 1)
    if np.linalg.det(R) < 0:
        Vt[-1, :] *= -1
        R = Vt.T @ U.T
    
    # Apply transformation
    est_aligned = (R @ est_centered.T).T + gt_mean
    
    # Compute ATE
    errors = np.linalg.norm(gt_positions - est_aligned, axis=1)
    
    return {
        'rmse': np.sqrt(np.mean(errors**2)),
        'mean': np.mean(errors),
        'median': np.median(errors),
        'std': np.std(errors),
        'min': np.min(errors),
        'max': np.max(errors)
    }

def main():
    if len(sys.argv) < 3:
        print("Usage: python compare_with_groundtruth.py <ground_truth.csv> <vins_bag_file>")
        sys.exit(1)
    
    gt_file = sys.argv[1]
    vins_bag = sys.argv[2]
    
    print(f"Loading ground truth: {gt_file}")
    gt_timestamps, gt_positions = load_groundtruth(gt_file)
    print(f"Ground truth: {len(gt_timestamps)} poses")
    
    print(f"Loading VINS trajectory: {vins_bag}")
    vins_timestamps, vins_positions = load_vins_trajectory(vins_bag)
    
    if vins_timestamps is None:
        print("Failed to load VINS trajectory")
        sys.exit(1)
    
    print(f"VINS trajectory: {len(vins_timestamps)} poses")
    
    # Interpolate ground truth to match VINS timestamps
    gt_interp = np.zeros_like(vins_positions)
    for i in range(3):
        gt_interp[:, i] = np.interp(
            vins_timestamps,
            gt_timestamps,
            gt_positions[:, i]
        )
    
    # Compute ATE
    ate = compute_ate(gt_interp, vins_positions)
    
    print("\n" + "="*50)
    print("Absolute Trajectory Error (ATE)")
    print("="*50)
    print(f"RMSE:  {ate['rmse']:.4f} m")
    print(f"Mean:  {ate['mean']:.4f} m")
    print(f"Median:{ate['median']:.4f} m")
    print(f"Std:   {ate['std']:.4f} m")
    print(f"Min:   {ate['min']:.4f} m")
    print(f"Max:   {ate['max']:.4f} m")
    print("="*50)

if __name__ == '__main__':
    main()
