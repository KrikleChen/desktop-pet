const CONFIGURATION = Object.freeze({
  gravity: 1_600,
  airResistancePerSecond: 0.60,
  edgeRestitution: 0.20,
  tangentialDamping: 0.68,
  settlementSpeed: 175,
  maximumInitialSpeed: 4_200,
  maximumSubstepDistance: 18,
});

export function createThrowState(bounds, velocity) {
  const limited = limitVelocity(velocity, CONFIGURATION.maximumInitialSpeed);
  return {
    x: bounds.x,
    y: bounds.y,
    width: bounds.width,
    height: bounds.height,
    velocityX: limited.x,
    velocityY: limited.y,
    elapsed: 0,
  };
}

export function stepThrowPhysics(state, visibleFrames, elapsedSeconds) {
  const delta = Math.min(Math.max(elapsedSeconds, 0), 1 / 20);
  const next = { ...state, elapsed: state.elapsed + delta };
  next.velocityY += CONFIGURATION.gravity * delta;
  const drag = Math.exp(-CONFIGURATION.airResistancePerSecond * delta);
  next.velocityX *= drag;
  next.velocityY *= drag;

  const travelDistance = Math.hypot(next.velocityX, next.velocityY) * delta;
  const stepCount = Math.max(1, Math.min(
    16,
    Math.ceil(travelDistance / CONFIGURATION.maximumSubstepDistance),
  ));
  const substepDuration = delta / stepCount;
  let impact;

  for (let index = 0; index < stepCount; index += 1) {
    const candidate = advance(next, visibleFrames, {
      x: next.velocityX * substepDuration,
      y: next.velocityY * substepDuration,
    });
    if (!candidate) continue;
    if (!impact || candidate.normalSpeed > impact.normalSpeed) {
      impact = { ...candidate, edges: new Set([...(impact?.edges ?? []), ...candidate.edges]) };
    } else {
      candidate.edges.forEach((edge) => impact.edges.add(edge));
    }
  }

  return {
    state: next,
    impact: impact && {
      edges: [...impact.edges],
      normalSpeed: impact.normalSpeed,
      severity: impact.normalSpeed >= 1_100 ? "heavy"
        : impact.normalSpeed >= 420 ? "medium" : "light",
    },
    shouldSettle: Boolean(
      impact?.edges.has("bottom")
      && Math.abs(next.velocityX) <= CONFIGURATION.settlementSpeed
      && Math.abs(next.velocityY) <= CONFIGURATION.settlementSpeed,
    ),
  };
}

function advance(state, visibleFrames, displacement) {
  const proposed = frameAt(state, displacement.x, displacement.y);
  if (isFullyCovered(proposed, visibleFrames)) {
    state.x = proposed.x;
    state.y = proposed.y;
    return undefined;
  }

  const preCollisionVelocity = { x: state.velocityX, y: state.velocityY };
  const edges = new Set();
  const horizontal = frameAt(state, displacement.x, 0);
  if (isFullyCovered(horizontal, visibleFrames)) {
    state.x = horizontal.x;
  } else if (displacement.x !== 0) {
    edges.add(displacement.x > 0 ? "right" : "left");
    state.velocityX = -state.velocityX * CONFIGURATION.edgeRestitution;
    state.velocityY *= CONFIGURATION.tangentialDamping;
  }

  const vertical = frameAt(state, 0, displacement.y);
  if (isFullyCovered(vertical, visibleFrames)) {
    state.y = vertical.y;
  } else if (displacement.y !== 0) {
    edges.add(displacement.y > 0 ? "bottom" : "top");
    state.velocityY = -state.velocityY * CONFIGURATION.edgeRestitution;
    state.velocityX *= CONFIGURATION.tangentialDamping;
  }
  if (edges.size === 0) return undefined;

  return {
    edges,
    normalSpeed: Math.max(...[...edges].map((edge) => normalSpeed(edge, preCollisionVelocity))),
  };
}

function normalSpeed(edge, velocity) {
  if (edge === "left") return Math.max(0, -velocity.x);
  if (edge === "right") return Math.max(0, velocity.x);
  if (edge === "top") return Math.max(0, -velocity.y);
  return Math.max(0, velocity.y);
}

function frameAt(state, deltaX, deltaY) {
  return {
    x: state.x + deltaX,
    y: state.y + deltaY,
    width: state.width,
    height: state.height,
  };
}

function isFullyCovered(frame, visibleFrames) {
  if (!(frame.width > 0 && frame.height > 0)) return false;
  const intersections = visibleFrames
    .map((visible) => intersection(frame, visible))
    .filter(Boolean);
  if (intersections.length === 0) return false;
  return unionArea(intersections) >= frame.width * frame.height - 0.5;
}

function intersection(lhs, rhs) {
  const x = Math.max(lhs.x, rhs.x);
  const y = Math.max(lhs.y, rhs.y);
  const right = Math.min(lhs.x + lhs.width, rhs.x + rhs.width);
  const bottom = Math.min(lhs.y + lhs.height, rhs.y + rhs.height);
  if (right <= x || bottom <= y) return undefined;
  return { x, y, width: right - x, height: bottom - y };
}

function unionArea(rectangles) {
  const xs = [...new Set(rectangles.flatMap((rectangle) => [
    rectangle.x,
    rectangle.x + rectangle.width,
  ]))].sort((a, b) => a - b);
  let area = 0;
  for (let index = 0; index < xs.length - 1; index += 1) {
    const left = xs[index];
    const right = xs[index + 1];
    const midpoint = (left + right) / 2;
    const intervals = rectangles
      .filter((rectangle) => rectangle.x <= midpoint && midpoint <= rectangle.x + rectangle.width)
      .map((rectangle) => [rectangle.y, rectangle.y + rectangle.height])
      .sort((lhs, rhs) => lhs[0] - rhs[0]);
    if (intervals.length === 0) continue;
    let [start, end] = intervals[0];
    let height = 0;
    for (const [nextStart, nextEnd] of intervals.slice(1)) {
      if (nextStart <= end) end = Math.max(end, nextEnd);
      else {
        height += end - start;
        [start, end] = [nextStart, nextEnd];
      }
    }
    area += (right - left) * (height + end - start);
  }
  return area;
}

function limitVelocity(velocity, maximum) {
  const magnitude = Math.hypot(velocity.x, velocity.y);
  if (magnitude <= maximum || magnitude === 0) return { ...velocity };
  const scale = maximum / magnitude;
  return { x: velocity.x * scale, y: velocity.y * scale };
}
