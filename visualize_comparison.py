#!/usr/bin/env python3
"""
Visualize VINS-Fusion trajectory comparison
"""

import csv
import matplotlib
matplotlib.use('Agg')  # Non-interactive backend
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
import numpy as np
import os

def read_trajectory(csv_file):
    """Read trajectory from CSV file"""
    try:
        x, y, z = [], [], []
        with open(csv_file, 'r') as f:
            reader = csv.reader(f)
            header = next(reader)  # Skip header
            
            # Find position column indices
            try:
                x_idx = header.index('field.pose.pose.position.x')
                y_idx = header.index('field.pose.pose.position.y')
                z_idx = header.index('field.pose.pose.position.z')
            except ValueError:
                print(f"Warning: Could not find position columns in {csv_file}")
                return None, None, None
            
            for row in reader:
                if len(row) > max(x_idx, y_idx, z_idx):
                    try:
                        x.append(float(row[x_idx]))
                        y.append(float(row[y_idx]))
                        z.append(float(row[z_idx]))
                    except (ValueError, IndexError):
                        continue
        
        return np.array(x), np.array(y), np.array(z)
    except Exception as e:
        print(f"Error reading {csv_file}: {e}")
        return None, None, None

def plot_trajectories_3d(trajectories, labels, output_file):
    """Plot multiple trajectories in 3D"""
    fig = plt.figure(figsize=(12, 9))
    ax = fig.add_subplot(111, projection='3d')
    
    colors = ['blue', 'red', 'green']
    
    for (x, y, z), label, color in zip(trajectories, labels, colors):
        if x is not None and len(x) > 0:
            # Downsample for visualization
            step = max(1, len(x) // 500)
            ax.plot(x[::step], y[::step], z[::step], 
                   color=color, label=label, linewidth=2, alpha=0.7)
            # Mark start and end
            ax.scatter(x[0], y[0], z[0], color=color, s=100, marker='*', 
                      edgecolors='black', linewidths=1, label=f'{label} start')
            ax.scatter(x[-1], y[-1], z[-1], color=color, s=100, marker='X', 
                      edgecolors='black', linewidths=1, label=f'{label} end')
    
    ax.set_xlabel('X (m)', fontsize=12)
    ax.set_ylabel('Y (m)', fontsize=12)
    ax.set_zlabel('Z (m)', fontsize=12)
    ax.set_title('VINS-Fusion Trajectory Comparison (3D)', fontsize=14, fontweight='bold')
    ax.legend(fontsize=8, loc='best')
    ax.grid(True, alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300, bbox_inches='tight')
    print(f"3D plot saved to: {output_file}")
    plt.close()

def plot_trajectories_2d(trajectories, labels, output_file):
    """Plot multiple trajectories in 2D views"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 12))
    
    colors = ['blue', 'red', 'green']
    
    # XY plane (top view)
    ax = axes[0, 0]
    for (x, y, z), label, color in zip(trajectories, labels, colors):
        if x is not None and len(x) > 0:
            ax.plot(x, y, color=color, label=label, linewidth=2, alpha=0.7)
            ax.scatter(x[0], y[0], color=color, s=100, marker='*', edgecolors='black')
            ax.scatter(x[-1], y[-1], color=color, s=100, marker='X', edgecolors='black')
    ax.set_xlabel('X (m)')
    ax.set_ylabel('Y (m)')
    ax.set_title('Top View (XY Plane)')
    ax.legend()
    ax.grid(True, alpha=0.3)
    ax.axis('equal')
    
    # XZ plane
    ax = axes[0, 1]
    for (x, y, z), label, color in zip(trajectories, labels, colors):
        if x is not None and len(x) > 0:
            ax.plot(x, z, color=color, label=label, linewidth=2, alpha=0.7)
            ax.scatter(x[0], z[0], color=color, s=100, marker='*', edgecolors='black')
            ax.scatter(x[-1], z[-1], color=color, s=100, marker='X', edgecolors='black')
    ax.set_xlabel('X (m)')
    ax.set_ylabel('Z (m)')
    ax.set_title('Side View (XZ Plane)')
    ax.legend()
    ax.grid(True, alpha=0.3)
    
    # YZ plane
    ax = axes[1, 0]
    for (x, y, z), label, color in zip(trajectories, labels, colors):
        if x is not None and len(x) > 0:
            ax.plot(y, z, color=color, label=label, linewidth=2, alpha=0.7)
            ax.scatter(y[0], z[0], color=color, s=100, marker='*', edgecolors='black')
            ax.scatter(y[-1], z[-1], color=color, s=100, marker='X', edgecolors='black')
    ax.set_xlabel('Y (m)')
    ax.set_ylabel('Z (m)')
    ax.set_title('Front View (YZ Plane)')
    ax.legend()
    ax.grid(True, alpha=0.3)
    
    # Distance over time
    ax = axes[1, 1]
    for (x, y, z), label, color in zip(trajectories, labels, colors):
        if x is not None and len(x) > 0:
            dist = np.sqrt(x**2 + y**2 + z**2)
            t = np.arange(len(dist))
            ax.plot(t, dist, color=color, label=label, linewidth=2, alpha=0.7)
    ax.set_xlabel('Frame')
    ax.set_ylabel('Distance from Origin (m)')
    ax.set_title('Distance from Origin')
    ax.legend()
    ax.grid(True, alpha=0.3)
    
    plt.suptitle('VINS-Fusion Trajectory Comparison', fontsize=16, fontweight='bold')
    plt.tight_layout()
    plt.savefig(output_file, dpi=300, bbox_inches='tight')
    print(f"2D plot saved to: {output_file}")
    plt.close()

def calculate_statistics(x, y, z):
    """Calculate trajectory statistics"""
    if x is None or len(x) == 0:
        return {}
    
    # Total distance
    dx = np.diff(x)
    dy = np.diff(y)
    dz = np.diff(z)
    total_distance = np.sum(np.sqrt(dx**2 + dy**2 + dz**2))
    
    # Final position
    final_distance = np.sqrt(x[-1]**2 + y[-1]**2 + z[-1]**2)
    
    # Altitude range
    altitude_range = np.max(z) - np.min(z)
    
    return {
        'total_distance': total_distance,
        'final_distance': final_distance,
        'altitude_range': altitude_range,
        'num_points': len(x)
    }

def main():
    # Results directory (use relative path for Docker compatibility)
    results_dir = "comparison_results"
    os.makedirs(results_dir, exist_ok=True)
    
    # Define test versions
    versions = [
        ("01_original.csv", "Original VINS-Fusion"),
        ("02_superpoint_flow.csv", "SuperPoint + Optical Flow"),
        ("03_superpoint_lightglue.csv", "SuperPoint + LightGlue")
    ]
    
    trajectories = []
    labels = []
    stats = []
    
    print("Reading trajectory data...")
    for filename, label in versions:
        csv_file = os.path.join(results_dir, filename)
        if os.path.exists(csv_file):
            x, y, z = read_trajectory(csv_file)
            trajectories.append((x, y, z))
            labels.append(label)
            stat = calculate_statistics(x, y, z)
            stats.append(stat)
            if stat:
                print(f"  {label}: {stat['num_points']} points")
        else:
            print(f"  Warning: {csv_file} not found")
            trajectories.append((None, None, None))
            labels.append(label)
            stats.append({})
    
    # Generate plots
    print("\nGenerating visualizations...")
    plot_trajectories_3d(trajectories, labels, os.path.join(results_dir, "trajectory_3d.png"))
    plot_trajectories_2d(trajectories, labels, os.path.join(results_dir, "trajectory_2d.png"))
    
    # Print statistics
    print("\n=========================================")
    print("Trajectory Statistics")
    print("=========================================")
    for label, stat in zip(labels, stats):
        if stat:
            print(f"\n{label}:")
            print(f"  Total Distance: {stat['total_distance']:.2f} m")
            print(f"  Final Distance: {stat['final_distance']:.2f} m")
            print(f"  Altitude Range: {stat['altitude_range']:.2f} m")
            print(f"  Number of Points: {stat['num_points']}")
    
    print(f"\nVisualization files saved to: {results_dir}")
    print("  - trajectory_3d.png")
    print("  - trajectory_2d.png")
    print("Done!")

if __name__ == "__main__":
    main()
