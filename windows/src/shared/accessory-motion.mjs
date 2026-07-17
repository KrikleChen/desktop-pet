export const ACCESSORY_MOTIONS = Object.freeze({
  "attorney-badge": motion(560, "goldenArc", 0.72, 0.04, 1.5),
  "case-file": motion(700, "fileFlutter", 0.03, 0.14, 3),
  magatama: motion(620, "cyanSpirit", 0.34, 0.08, 2),
  evidence: motion(550, "redBlueEmphasis", -0.18, 0.10, 3.2),
  pen: motion(480, "penSpiral", 1.35, 0.03, 2),
  "sticky-note": motion(740, "paperFall", 0.06, 0.24, 3.5),
});

export function accessoryMotionPosition(kind, start, destination, progress) {
  const motion = ACCESSORY_MOTIONS[kind];
  if (!motion) return destination;
  const pathProgress = easedProgress(progress);
  // macOS geometry uses a bottom-up y axis. Convert Windows screen coordinates
  // into that space, apply the same curve, then convert the result back.
  const from = { x: start.x, y: -start.y };
  const to = { x: destination.x, y: -destination.y };
  const deltaX = to.x - from.x;
  const deltaY = to.y - from.y;
  const distance = Math.max(1, Math.hypot(deltaX, deltaY));
  const direction = { x: deltaX / distance, y: deltaY / distance };
  const normal = { x: -direction.y, y: direction.x };
  const envelope = Math.sin(Math.PI * pathProgress);
  const point = {
    x: from.x + deltaX * pathProgress,
    y: from.y + deltaY * pathProgress,
  };
  const add = (vector, amount) => {
    point.x += vector.x * amount;
    point.y += vector.y * amount;
  };

  switch (motion.curve) {
    case "goldenArc":
      point.y += Math.min(76, Math.max(24, distance * 0.18)) * envelope;
      break;
    case "fileFlutter":
      point.y += Math.min(38, Math.max(16, distance * 0.08)) * envelope;
      add(normal, Math.sin(3 * Math.PI * pathProgress) * Math.min(22, Math.max(9, distance * 0.055)) * envelope);
      break;
    case "cyanSpirit":
      point.y += Math.min(46, Math.max(20, distance * 0.11)) * envelope;
      add(normal, (16 + 8 * Math.sin(4 * Math.PI * pathProgress)) * envelope);
      break;
    case "redBlueEmphasis":
      point.y += Math.min(24, Math.max(10, distance * 0.05)) * envelope;
      add(normal, Math.sin(2 * Math.PI * pathProgress) * Math.min(30, Math.max(12, distance * 0.075)) * envelope);
      break;
    case "penSpiral": {
      const radius = Math.min(20, Math.max(8, distance * 0.05)) * envelope * (1 - 0.55 * pathProgress);
      add(normal, Math.sin(4 * Math.PI * pathProgress) * radius);
      add(direction, Math.cos(4 * Math.PI * pathProgress) * radius * 0.42);
      break;
    }
    case "paperFall": {
      const fallingEnvelope = envelope * Math.pow(1 - pathProgress, 0.35);
      point.y -= Math.min(46, Math.max(22, distance * 0.10)) * fallingEnvelope;
      add(normal, Math.sin(3 * Math.PI * pathProgress) * Math.min(24, Math.max(10, distance * 0.06)) * envelope);
      break;
    }
    default:
      break;
  }
  return { x: point.x, y: -point.y };
}

export function easedProgress(progress) {
  const bounded = Math.min(1, Math.max(0, progress));
  if (bounded < 0.5) return 4 * bounded * bounded * bounded;
  return 1 - Math.pow(-2 * bounded + 2, 3) / 2;
}

function motion(durationMs, curve, rotationTurns, swingAmplitude, swingCycles) {
  return Object.freeze({ durationMs, curve, rotationTurns, swingAmplitude, swingCycles });
}
