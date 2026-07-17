export function stepAccessoryPhysics(state, workArea, deltaSeconds) {
  const delta = Math.min(Math.max(deltaSeconds, 1 / 120), 1 / 30);
  const next = { ...state };
  let justLanded = false;

  next.velocityY += 840 * delta;
  next.x += next.velocityX * delta;
  next.y += next.velocityY * delta;

  const left = workArea.x;
  const right = Math.max(left, workArea.x + workArea.width - next.width);
  if (next.x < left) {
    next.x = left;
    next.velocityX = Math.abs(next.velocityX) * 0.62;
  } else if (next.x > right) {
    next.x = right;
    next.velocityX = -Math.abs(next.velocityX) * 0.62;
  }

  const ceiling = workArea.y;
  if (next.y < ceiling) {
    next.y = ceiling;
    next.velocityY = Math.abs(next.velocityY) * 0.45;
  }

  const floor = Math.max(ceiling, workArea.y + workArea.height - next.height);
  if (next.y >= floor) {
    next.y = floor;
    if (!next.landed) {
      next.landed = true;
      justLanded = true;
    }
    if (Math.abs(next.velocityY) > 48) {
      next.velocityY = -Math.abs(next.velocityY) * next.restitution;
      next.velocityX *= 0.80;
      next.restingDuration = 0;
    } else {
      next.velocityY = 0;
      next.velocityX *= Math.pow(0.88, delta * 60);
      if (Math.abs(next.velocityX) < 13) {
        next.velocityX = 0;
        next.restingDuration += delta;
      } else {
        next.restingDuration = 0;
      }
    }
  } else {
    next.restingDuration = 0;
  }

  return {
    state: next,
    justLanded,
    sleeping: next.restingDuration >= 0.24,
  };
}
