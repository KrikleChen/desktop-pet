export function buildCharacterMask(source, threshold = 20) {
  const width = Number(source?.width);
  const height = Number(source?.height);
  const alpha = source?.alpha;
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height)
      || width < 1 || height < 1 || alpha?.length !== width * height) return undefined;

  const visited = new Uint8Array(alpha.length);
  const queue = new Int32Array(alpha.length);
  let bestIndices;
  let bestBounds;
  let bestScore = Number.NEGATIVE_INFINITY;

  for (let start = 0; start < alpha.length; start += 1) {
    if (alpha[start] < threshold || visited[start]) continue;
    let head = 0;
    let tail = 1;
    queue[0] = start;
    visited[start] = 1;
    let minX = start % width;
    let maxX = minX;
    let minY = Math.floor(start / width);
    let maxY = minY;

    while (head < tail) {
      const index = queue[head];
      head += 1;
      const x = index % width;
      const y = Math.floor(index / width);
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x);
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y);

      for (let neighborY = Math.max(0, y - 1); neighborY <= Math.min(height - 1, y + 1); neighborY += 1) {
        for (let neighborX = Math.max(0, x - 1); neighborX <= Math.min(width - 1, x + 1); neighborX += 1) {
          if (neighborX === x && neighborY === y) continue;
          const neighbor = neighborY * width + neighborX;
          if (visited[neighbor] || alpha[neighbor] < threshold) continue;
          visited[neighbor] = 1;
          queue[tail] = neighbor;
          tail += 1;
        }
      }
    }

    const componentHeight = maxY - minY + 1;
    const centerX = (minX + maxX) / 2 / width;
    const centerWeight = Math.max(0.35, 1 - Math.abs(centerX - 0.5) * 1.4);
    const heightWeight = 0.5 + 1.8 * componentHeight / height;
    const score = tail * centerWeight * heightWeight;
    if (score > bestScore) {
      bestScore = score;
      bestIndices = queue.slice(0, tail);
      bestBounds = { minX, minY, maxX, maxY };
    }
  }

  if (!bestIndices?.length || !bestBounds) return undefined;
  const characterPixels = new Uint8Array(alpha.length);
  for (const index of bestIndices) characterPixels[index] = 1;
  return { width, height, alpha: Uint8Array.from(alpha), characterPixels, bounds: bestBounds, threshold };
}

export function detectGrabRegion(mask, point, frame) {
  if (!mask || frame.width <= 0 || frame.height <= 0) return undefined;
  const scale = Math.min(frame.width / mask.width, frame.height / mask.height);
  const drawnWidth = mask.width * scale;
  const drawnHeight = mask.height * scale;
  const left = frame.left + (frame.width - drawnWidth) / 2;
  const top = frame.top + (frame.height - drawnHeight) / 2;
  if (point.x < left || point.x > left + drawnWidth || point.y < top || point.y > top + drawnHeight) {
    return undefined;
  }

  const normalizedX = clamp((point.x - left) / drawnWidth);
  const normalizedFromTop = clamp((point.y - top) / drawnHeight);
  const pixelX = Math.min(mask.width - 1, Math.floor(normalizedX * mask.width));
  const pixelY = Math.min(mask.height - 1, Math.floor(normalizedFromTop * mask.height));
  const pixelIndex = pixelY * mask.width + pixelX;
  if (mask.alpha[pixelIndex] < mask.threshold || !mask.characterPixels[pixelIndex]) return undefined;

  const characterWidth = Math.max(1, mask.bounds.maxX - mask.bounds.minX);
  const characterHeight = Math.max(1, mask.bounds.maxY - mask.bounds.minY);
  const characterX = clamp((pixelX - mask.bounds.minX) / characterWidth);
  const characterY = clamp((mask.bounds.maxY - pixelY) / characterHeight);
  return classifyGrabRegion(characterX, characterY);
}

export function classifyGrabRegion(x, y) {
  if (y >= 0.72) return "hair/head";
  if (y <= 0.30) return "leg";
  const sideInset = y >= 0.58 ? 0.34 : 0.29;
  if (x <= sideInset || x >= 1 - sideInset) return "arm";
  return "collar/torso";
}

function clamp(value) {
  return Math.min(1, Math.max(0, value));
}
