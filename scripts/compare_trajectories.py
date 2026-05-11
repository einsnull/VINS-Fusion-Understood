#!/usr/bin/env python3
"""Comprehensive VINS-Fusion trajectory comparison with ATE/RPE and 3D visualization"""
import numpy as np
import os
import sys
import argparse

try:
    import rosbag
    HAS_ROSBAG = True
except ImportError:
    HAS_ROSBAG = False
    print("[WARN] rosbag not available, will try CSV only")

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d import Axes3D
    HAS_MPL = True
except ImportError:
    HAS_MPL = False
    print("[WARN] matplotlib not available, skipping plots")


def load_ground_truth(path):
    data = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('#') or not line:
                continue
            parts = line.split(',')
            if len(parts) >= 8:
                try:
                    t = int(parts[0]) / 1e9
                    px, py, pz = float(parts[1]), float(parts[2]), float(parts[3])
                    qw, qx, qy, qz = float(parts[4]), float(parts[5]), float(parts[6]), float(parts[7])
                    data.append([t, px, py, pz, qw, qx, qy, qz])
                except ValueError:
                    continue
    return np.array(data)


def load_vio_csv(path):
    """Load vio.csv: timestamp_ns,px,py,pz,qw,qx,qy,qz,vx,vy,vz"""
    data = []
    with open(path, 'r') as f:
        for line in f:
            parts = line.strip().rstrip(',').split(',')
            if len(parts) >= 8:
                try:
                    t = float(parts[0]) / 1e9
                    px, py, pz = float(parts[1]), float(parts[2]), float(parts[3])
                    qw, qx, qy, qz = float(parts[4]), float(parts[5]), float(parts[6]), float(parts[7])
                    data.append([t, px, py, pz, qw, qx, qy, qz])
                except (ValueError, IndexError):
                    continue
    return np.array(data)


def extract_from_bag(bag_path, odom_topic='/vins_estimator/odometry'):
    """Extract odometry poses with timestamps from rosbag"""
    if not HAS_ROSBAG:
        print("[ERROR] rosbag not available, cannot extract from bag")
        return None
    data = []
    bag = rosbag.Bag(bag_path)
    for topic, msg, t in bag.read_messages(topics=[odom_topic]):
        ts = t.to_sec()
        px = msg.pose.pose.position.x
        py = msg.pose.pose.position.y
        pz = msg.pose.pose.position.z
        qw = msg.pose.pose.orientation.w
        qx = msg.pose.pose.orientation.x
        qy = msg.pose.pose.orientation.y
        qz = msg.pose.pose.orientation.z
        data.append([ts, px, py, pz, qw, qx, qy, qz])
    bag.close()
    return np.array(data)


def umeyama_alignment(P, Q):
    """Umeyama alignment: find s,R,t to align P to Q"""
    assert P.shape == Q.shape
    n, dim = P.shape

    mu_P = np.mean(P, axis=0)
    mu_Q = np.mean(Q, axis=0)

    P_centered = P - mu_P
    Q_centered = Q - mu_Q

    C = P_centered.T @ Q_centered / n
    U, s_vals, Vt = np.linalg.svd(C)
    R = U @ Vt
    if np.linalg.det(R) < 0:
        Vt[-1, :] *= -1
        R = U @ Vt

    sigma_P = np.sum(np.var(P, axis=0))
    if sigma_P > 1e-10:
        s = np.sum(s_vals) / sigma_P
    else:
        s = 1.0

    t = mu_Q - s * R @ mu_P
    return s, R, t


def match_trajectories(est, gt):
    """Match estimated trajectory to ground truth by timestamp"""
    matched_est_pos = []
    matched_gt_pos = []
    matched_est_full = []
    matched_gt_full = []

    for i in range(len(est)):
        t = est[i, 0]
        if t < gt[0, 0] or t > gt[-1, 0]:
            continue
        idx = np.searchsorted(gt[:, 0], t)
        if idx >= len(gt):
            idx = len(gt) - 1
        if idx > 0 and abs(gt[idx - 1, 0] - t) < abs(gt[idx, 0] - t):
            idx = idx - 1
        matched_est_pos.append([est[i, 1], est[i, 2], est[i, 3]])
        matched_gt_pos.append([gt[idx, 1], gt[idx, 2], gt[idx, 3]])
        matched_est_full.append(est[i])
        matched_gt_full.append(gt[idx])

    return (np.array(matched_est_pos), np.array(matched_gt_pos),
            np.array(matched_est_full), np.array(matched_gt_full))


def compute_ate(est, gt):
    """Compute Absolute Trajectory Error with Umeyama alignment"""
    if len(est) == 0 or len(gt) == 0:
        return None

    est_pos, gt_pos, est_full, gt_full = match_trajectories(est, gt)

    if len(est_pos) < 10:
        return None

    s, R, t = umeyama_alignment(est_pos, gt_pos)
    P_aligned = s * (est_pos @ R.T) + t
    errors = np.sqrt(np.sum((P_aligned - gt_pos) ** 2, axis=1))

    return {
        'rmse': np.sqrt(np.mean(errors ** 2)),
        'mean': np.mean(errors),
        'median': np.median(errors),
        'std': np.std(errors),
        'max': np.max(errors),
        'min': np.min(errors),
        'n_matches': len(est_pos),
        'aligned': P_aligned,
        'gt_pos': gt_pos,
        'errors': errors,
        's': s, 'R': R, 't': t,
    }


def compute_rpe(est, gt, delta=1.0):
    """Compute Relative Pose Error over fixed time intervals"""
    if len(est) == 0 or len(gt) == 0:
        return None

    est_pos, gt_pos, est_full, gt_full = match_trajectories(est, gt)

    if len(est_pos) < 10:
        return None

    trans_errors = []
    for i in range(len(est_full) - 1):
        for j in range(i + 1, len(est_full)):
            dt = est_full[j, 0] - est_full[i, 0]
            if dt >= delta - 0.1 and dt <= delta + 0.1:
                est_delta = est_pos[j] - est_pos[i]
                gt_delta = gt_pos[j] - gt_pos[i]
                trans_err = np.linalg.norm(est_delta - gt_delta)
                trans_errors.append(trans_err)
                break

    if len(trans_errors) < 5:
        return None

    trans_errors = np.array(trans_errors)
    return {
        'rmse': np.sqrt(np.mean(trans_errors ** 2)),
        'mean': np.mean(trans_errors),
        'median': np.median(trans_errors),
        'std': np.std(trans_errors),
        'max': np.max(trans_errors),
        'n_pairs': len(trans_errors),
    }


def plot_trajectories_3d(gt, results, output_path):
    """Generate 3D trajectory comparison plot"""
    if not HAS_MPL:
        print("[WARN] matplotlib not available, skipping 3D plot")
        return

    fig = plt.figure(figsize=(14, 6))

    ax1 = fig.add_subplot(121, projection='3d')
    ax1.plot(gt[:, 1], gt[:, 2], gt[:, 3], 'k-', linewidth=0.5, alpha=0.5, label='Ground Truth')

    colors = {'original': 'blue', 'superpoint': 'red'}
    labels = {'original': 'Original (Shi-Tomasi)', 'superpoint': 'SuperPoint+Flow'}

    for name, result in results.items():
        if result is not None and 'aligned' in result:
            aligned = result['aligned']
            ax1.plot(aligned[:, 0], aligned[:, 1], aligned[:, 2],
                     color=colors.get(name, 'green'), linewidth=1.0, label=labels.get(name, name))

    ax1.set_xlabel('X (m)')
    ax1.set_ylabel('Y (m)')
    ax1.set_zlabel('Z (m)')
    ax1.set_title('3D Trajectory Comparison (MH_01_easy)')
    ax1.legend()

    ax2 = fig.add_subplot(122)
    for name, result in results.items():
        if result is not None and 'errors' in result:
            ax2.plot(result['errors'], linewidth=0.5, alpha=0.7,
                     color=colors.get(name, 'green'), label=labels.get(name, name))
    ax2.set_xlabel('Frame')
    ax2.set_ylabel('ATE (m)')
    ax2.set_title('Absolute Trajectory Error Over Time')
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    plt.close()
    print(f"[PLOT] Saved 3D trajectory plot to {output_path}")


def plot_error_comparison(results, output_path):
    """Generate bar chart comparing ATE metrics"""
    if not HAS_MPL:
        return

    names = list(results.keys())
    if len(names) < 2:
        return

    metrics = ['rmse', 'mean', 'median', 'std', 'max']
    x = np.arange(len(metrics))
    width = 0.35

    fig, ax = plt.subplots(figsize=(10, 5))
    colors = ['blue', 'red']

    for i, name in enumerate(names):
        if results[name] is not None:
            values = [results[name][m] for m in metrics]
            ax.bar(x + i * width, values, width, label=name, color=colors[i % len(colors)])

    ax.set_ylabel('Error (m)')
    ax.set_title('ATE Metrics Comparison')
    ax.set_xticks(x + width / 2)
    ax.set_xticklabels(['RMSE', 'Mean', 'Median', 'Std', 'Max'])
    ax.legend()
    ax.grid(True, alpha=0.3, axis='y')

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    plt.close()
    print(f"[PLOT] Saved error comparison to {output_path}")


def print_results(name, ate, rpe):
    print(f"\n{'=' * 60}")
    print(f"  {name}")
    print(f"{'=' * 60}")
    if ate:
        print(f"  ATE RMSE:   {ate['rmse']:.4f} m")
        print(f"  ATE Mean:   {ate['mean']:.4f} m")
        print(f"  ATE Median: {ate['median']:.4f} m")
        print(f"  ATE Std:    {ate['std']:.4f} m")
        print(f"  ATE Max:    {ate['max']:.4f} m")
        print(f"  ATE Min:    {ate['min']:.4f} m")
        print(f"  Matched poses: {ate['n_matches']}")
    else:
        print("  ATE: N/A")
    if rpe:
        print(f"  RPE RMSE:   {rpe['rmse']:.4f} m")
        print(f"  RPE Mean:   {rpe['mean']:.4f} m")
        print(f"  RPE Std:    {rpe['std']:.4f} m")
        print(f"  RPE pairs:  {rpe['n_pairs']}")
    else:
        print("  RPE: N/A")


def main():
    parser = argparse.ArgumentParser(description='VINS-Fusion trajectory comparison')
    parser.add_argument('--gt', default='/dataset/mav0/state_groundtruth_estimate0/data.csv',
                        help='Ground truth CSV path')
    parser.add_argument('--orig-bag', default='/orig/trajectory.bag',
                        help='Original VINS trajectory bag')
    parser.add_argument('--sp-bag', default='/sp/trajectory.bag',
                        help='SuperPoint VINS trajectory bag')
    parser.add_argument('--orig-csv', default=None,
                        help='Original VINS vio.csv (optional)')
    parser.add_argument('--sp-csv', default='/sp/vio.csv',
                        help='SuperPoint VINS vio.csv')
    parser.add_argument('--output-dir', default='/output',
                        help='Output directory for plots')
    parser.add_argument('--rpe-delta', type=float, default=1.0,
                        help='Time interval for RPE (seconds)')
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    print("=" * 60)
    print("VINS-Fusion Trajectory Comparison")
    print("  Original (Shi-Tomasi) vs SuperPoint+Optical Flow")
    print("=" * 60)

    gt = load_ground_truth(args.gt)
    if len(gt) == 0:
        print("[ERROR] Failed to load ground truth")
        sys.exit(1)
    gt_t0 = gt[0, 0]
    gt_rel = gt.copy()
    gt_rel[:, 0] -= gt_t0
    print(f"\nGround Truth: {len(gt)} poses, {gt[-1,0]-gt[0,0]:.1f}s duration")

    results = {}

    for label, bag_path, csv_path in [
        ('original', args.orig_bag, args.orig_csv),
        ('superpoint', args.sp_bag, args.sp_csv),
    ]:
        est = None
        source = "none"

        if csv_path and os.path.exists(csv_path):
            est = load_vio_csv(csv_path)
            source = "csv"
        elif bag_path and os.path.exists(bag_path) and HAS_ROSBAG:
            est = extract_from_bag(bag_path)
            source = "bag"

        if est is None or len(est) == 0:
            print(f"\n{label}: NO DATA (bag={os.path.exists(bag_path) if bag_path else 'N/A'}, csv={os.path.exists(csv_path) if csv_path else 'N/A'})")
            results[label] = None
            continue

        print(f"\n{label}: {len(est)} poses (from {source}), {est[-1,0]-est[0,0]:.1f}s")

        ate = compute_ate(est, gt)
        rpe = compute_rpe(est, gt, delta=args.rpe_delta)

        print_results(label, ate, rpe)
        results[label] = ate

    if HAS_MPL:
        plot_trajectories_3d(gt_rel, results,
                             os.path.join(args.output_dir, 'trajectory_3d.png'))
        plot_error_comparison(results,
                              os.path.join(args.output_dir, 'ate_comparison.png'))

    print("\n" + "=" * 60)
    print("Comparison complete!")
    print("=" * 60)


if __name__ == "__main__":
    main()