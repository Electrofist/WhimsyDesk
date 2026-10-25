#!/usr/bin/env python3
"""Numerical check of the door model. Mirrors Sources/FridgeCore/DoorPhysics.swift.

Run: python3 tools/sim_door.py
Every constant here must match DoorParameters in the Swift file.
"""
import math

DEG = math.pi / 180.0

P = dict(
    inertia=1.0,
    free_damping=3.0,
    tilt_stiffness=1.0,
    creep_torque=0.04,
    hand_stiffness=45.0,
    hand_damping=8.7,
    max_angle=105 * DEG,
    stop_stiffness=900.0,
    stop_damping=42.0,
    max_stop_damping=17.0,
    magnet_range=7 * DEG,
    magnet_strength=14.0,
    item_floor=34 * DEG,
    item_floor_stiffness=18.0,
    item_floor_damping=6.0,
)
STEP = 1.0 / 240.0


class Door:
    def __init__(self):
        self.a = 0.0
        self.w = 0.0
        self.hand = None
        self.items = False

    def torque(self):
        p, a, w = P, self.a, self.w
        t = 0.0
        if self.hand is not None:
            tgt = min(max(self.hand, 0.0), p["max_angle"])
            t += p["hand_stiffness"] * (tgt - a) - p["hand_damping"] * w
        else:
            t -= p["free_damping"] * w
            if not self.items:
                if a > 0:
                    t -= p["tilt_stiffness"] * a + p["creep_torque"]
                if a < p["magnet_range"]:
                    x = 1.0 - max(a, 0.0) / p["magnet_range"]
                    t -= p["magnet_strength"] * x * x
        if a < 0:
            t += p["stop_stiffness"] * (-a) - p["stop_damping"] * w
        if a > p["max_angle"]:
            t += -p["stop_stiffness"] * (a - p["max_angle"]) - p["max_stop_damping"] * w
        if self.items and a < p["item_floor"]:
            t += p["item_floor_stiffness"] * (p["item_floor"] - a) - p["item_floor_damping"] * w
        return t

    def step(self):
        self.w += self.torque() / P["inertia"] * STEP
        self.a += self.w * STEP

    def at_rest(self):
        return abs(self.w) < 0.01 and abs(self.torque()) < 0.005


def close_time(deg):
    d = Door()
    d.a = deg * DEG
    t = 0.0
    while t < 30:
        d.step()
        t += STEP
        if d.at_rest():
            return t, d.a / DEG
    return None, d.a / DEG


def hand_drag(path, hold=1.0):
    """path: list of (time, target_deg). Returns peak angle, final angle after hold and settle."""
    d = Door()
    t = 0.0
    peak = 0.0
    end = path[-1][0]
    while t < end + hold:
        tgt = None
        for i in range(len(path) - 1):
            t0, a0 = path[i]
            t1, a1 = path[i + 1]
            if t0 <= t <= t1:
                tgt = a0 + (a1 - a0) * (t - t0) / (t1 - t0)
        if tgt is None:
            tgt = path[-1][1]
        d.hand = tgt * DEG
        d.step()
        peak = max(peak, d.a / DEG)
        t += STEP
    lag_at_mid = None
    return peak, d.a / DEG


def fling(omega, release_deg=20):
    d = Door()
    d.a = release_deg * DEG
    d.w = omega
    peak = 0
    t = 0.0
    while t < 30:
        d.step()
        peak = max(peak, d.a / DEG)
        t += STEP
        if d.at_rest():
            return peak, d.a / DEG, t
    return peak, d.a / DEG, None


def lag_slow_drag():
    """Pointer moves 0 -> 60 deg over 3 s. Max lag between pointer and door."""
    d = Door()
    t = 0.0
    maxlag = 0
    while t < 3.0:
        tgt = 60 * t / 3.0
        d.hand = tgt * DEG
        d.step()
        if t > 0.5:
            maxlag = max(maxlag, tgt - d.a / DEG)
        t += STEP
    return maxlag


def item_drag_block():
    d = Door()
    d.a = 45 * DEG
    d.items = True
    t = 0.0
    while t < 20:
        d.step()
        t += STEP
    # shove it shut with a velocity
    d.w = -3.0
    low = d.a
    for _ in range(int(5 / STEP)):
        d.step()
        low = min(low, d.a)
    return d.a / DEG, low / DEG


if __name__ == "__main__":
    print("close times (release ajar, free drift):")
    for deg in (10, 20, 30, 45, 60, 90, 105):
        t, final = close_time(deg)
        print(f"  from {deg:>3} deg: {t:.2f}s, rests at {final:.3f} deg")
    print("fling open (release at 20 deg):")
    for om in (1.0, 3.0, 6.0, 10.0):
        peak, final, t = fling(om)
        print(f"  omega {om:>4} rad/s: peak {peak:.1f} deg, final {final:.2f} deg")
    print("hand: fast swing 0 to 60 deg in 0.15s then hold:")
    peak, final = hand_drag([(0, 0), (0.15, 60), (0.16, 60)], hold=2.0)
    print(f"  peak {peak:.1f} deg (overshoot {peak - 60:.1f}), settles {final:.2f}")
    print("hand: slow drag lag (0 to 60 deg over 3 s):", f"{lag_slow_drag():.1f} deg max lag")
    fin, low = item_drag_block()
    print(f"item drag active: door at 45 deg shoved shut, rests {fin:.1f} deg, lowest {low:.1f} deg")
