export class EdgeIdleBehavior {
  constructor({
    edgeTolerance = 24,
    stableDurationMs = 0,
    minimumIdleDurationMs = 60_000,
    cooldownDurationMs = 180_000,
  } = {}) {
    this.configuration = {
      edgeTolerance,
      stableDurationMs,
      minimumIdleDurationMs,
      cooldownDurationMs,
    };
    this.candidate = undefined;
    this.lastTriggerTime = undefined;
  }

  evaluate({ windowFrame, workArea, idleDurationMs, now, eligibility }) {
    const edge = eligibility
      ? nearEdge(windowFrame, workArea, this.configuration.edgeTolerance)
      : undefined;
    if (!edge || !Number.isFinite(idleDurationMs) || idleDurationMs < 0 || !Number.isFinite(now)) {
      this.resetCandidate();
      return undefined;
    }

    const idleSessionStartedAt = now - idleDurationMs;
    if (this.candidate?.edge === edge && now >= this.candidate.startedAt) {
      this.candidate.startedAt = Math.max(this.candidate.startedAt, idleSessionStartedAt);
    } else {
      this.candidate = { edge, startedAt: Math.max(now, idleSessionStartedAt) };
    }

    if (idleDurationMs < this.configuration.minimumIdleDurationMs
        || now - this.candidate.startedAt < this.configuration.stableDurationMs) {
      return undefined;
    }
    if (this.lastTriggerTime !== undefined
        && now - this.lastTriggerTime < this.configuration.cooldownDurationMs) {
      return undefined;
    }

    this.lastTriggerTime = now;
    this.candidate = { edge, startedAt: now };
    return edge;
  }

  resetCandidate() {
    this.candidate = undefined;
  }
}

export function nearEdge(windowFrame, workArea, tolerance = 24) {
  if (!validRectangle(windowFrame) || !validRectangle(workArea)
      || !Number.isFinite(tolerance) || tolerance < 0) return undefined;
  const distances = [
    ["bottom", Math.abs(
      windowFrame.y + windowFrame.height - (workArea.y + workArea.height),
    )],
    ["left", Math.abs(windowFrame.x - workArea.x)],
    ["right", Math.abs(
      windowFrame.x + windowFrame.width - (workArea.x + workArea.width),
    )],
  ];
  let nearest;
  for (const [edge, distance] of distances) {
    if (distance > tolerance) continue;
    if (!nearest || distance < nearest.distance) nearest = { edge, distance };
  }
  return nearest?.edge;
}

function validRectangle(value) {
  return value
    && [value.x, value.y, value.width, value.height].every(Number.isFinite)
    && value.width > 0
    && value.height > 0;
}
