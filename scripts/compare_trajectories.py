#!/usr/bin/env python3
"""Compare SuperPoint vs Original VINS-Fusion trajectories on MH_01_easy"""
import csv
import numpy as np
import os

def load_vio_csv(path):
    data = []
    with open(path, 'r') as f:
        for line in f:
            parts = line.strip().split(',')
            if len(parts) >= 11:
                try:
                    t = float(parts[0])
                    tx, ty, tz = float(parts[1]), float(parts[2]), float(parts[3])
                    data.append([t, tx, ty, tz])
                except ValueError:
                    continue
    return np.array(data)

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
                    tx, ty, tz = float(parts[1]), float(parts[2]), float(parts[3])
                    data.append([t, tx, ty, tz])
                except ValueError:
                    continue
    return np.array(data)

def umeyama_alignment(P, Q):
    """Umeyama alignment: find s,R,t to align P to Q"""
    assert P.shape == Q.shape
    n, dim = P.shape
    
    mu_P = np.mean(P, axis=0)
    mu_Q = np.mean(Q, axis=0)
    
    sigma_P = np.sum(np.var(P, axis=0))
    sigma_Q = np.sum(np.var(Q, axis=0))
    
    P_centered = P - mu_P
    Q_centered = Q - mu_Q
    
    C = P_centered.T @ Q_centered / n
    U, _, Vt = np.linalg.svd(C)
    R = U @ Vt
    if np.linalg.det(R) < 0:
        Vt[-1, :] *= -1
        R = U @ Vt
    
    if sigma_P > 1e-10:
        s = np.trace(np.diag(_)) / sigma_P
    else:
        s = 1.0
    
    t = mu_Q - s * R @ mu_P
    return s, R, t

def compute_ate(est, gt):
    """Compute ATE with Umeyama alignment"""
    if len(est) == 0 or len(gt) == 0:
        return None, None, None
    
    # Match timestamps
    matched_est = []
    matched_gt = []
    for i in range(len(est)):
        t = est[i, 0]
        if t < gt[0, 0] or t > gt[-1, 0]:
            continue
        idx = np.searchsorted(gt[:, 0], t)
        if idx >= len(gt):
            idx = len(gt) - 1
        if idx > 0 and abs(gt[idx-1, 0] - t) < abs(gt[idx, 0] - t):
            idx = idx - 1
        matched_est.append([est[i, 1], est[i, 2], est[i, 3]])
        matched_gt.append([gt[idx, 1], gt[idx, 2], gt[idx, 3]])
    
    if len(matched_est) < 10:
        return None, None, None
    
    P = np.array(matched_est)
    Q = np.array(matched_gt)
    
    s, R, t = umeyama_alignment(P, Q)
    
    P_aligned = s * (P @ R.T) + t
    
    errors = np.sqrt(np.sum((P_aligned - Q)**2, axis=1))
    
    rmse = np.sqrt(np.mean(errors**2))
    mean_err = np.mean(errors)
    max_err = np.max(errors)
    return rmse, mean_err, max_err

def main():
    gt_path = "/dataset/mav0/state_groundtruth_estimate0/data.csv"
    sp_path = "/sp/vio.csv"
    orig_path = "/orig/vio.csv"
    
    print("=" * 60)
    print("VINS-Fusion Trajectory Comparison: SuperPoint vs Original")
    print("=" * 60)
    
    gt = load_ground_truth(gt_path)
    gt_t0 = gt[0, 0]
    gt_rel = gt.copy()
    gt_rel[:, 0] = gt_rel[:, 0] - gt_t0
    print(f"\nGround Truth: {len(gt)} poses, duration={gt[-1,0]-gt[0,0]:.1f}s")
    
    # SuperPoint
    if os.path.exists(sp_path):
        sp = load_vio_csv(sp_path)
        print(f"\nSuperPoint+Flow: {len(sp)} poses")
        if len(sp) > 0:
            print(f"  Start: ({sp[0,1]:.3f}, {sp[0,2]:.3f}, {sp[0,3]:.3f})")
            print(f"  End:   ({sp[-1,1]:.3f}, {sp[-1,2]:.3f}, {sp[-1,3]:.3f})")
            rmse, mean_e, max_e = compute_ate(sp, gt_rel)
            if rmse:
                print(f"  ATE RMSE:  {rmse:.4f} m")
                print(f"  ATE Mean:  {mean_e:.4f} m")
                print(f"  ATE Max:   {max_e:.4f} m")
    else:
        print(f"\nSuperPoint: NO vio.csv")
    
    # Original
    if os.path.exists(orig_path):
        orig = load_vio_csv(orig_path)
        print(f"\nOriginal Shi-Tomasi: {len(orig)} poses")
        if len(orig) > 0:
            print(f"  Start: ({orig[0,1]:.3f}, {orig[0,2]:.3f}, {orig[0,3]:.3f})")
            print(f"  End:   ({orig[-1,1]:.3f}, {orig[-1,2]:.3f}, {orig[-1,3]:.3f})")
            rmse, mean_e, max_e = compute_ate(orig, gt_rel)
            if rmse:
                print(f"  ATE RMSE:  {rmse:.4f} m")
                print(f"  ATE Mean:  {mean_e:.4f} m")
                print(f"  ATE Max:   {max_e:.4f} m")
    else:
        print(f"\nOriginal: NO vio.csv (need to re-run with output_path set)")
    
    print("\n" + "=" * 60)

if __name__ == "__main__":
    main()