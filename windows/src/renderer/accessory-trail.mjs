const allowedKinds = new Set([
  "attorney-badge", "case-file", "magatama", "evidence", "pen", "sticky-note",
]);
const kind = new URLSearchParams(location.search).get("kind");
const svg = document.querySelector("#trail");
const back = document.querySelector("#trail-back");
const front = document.querySelector("#trail-front");

if (!allowedKinds.has(kind)) {
  document.body.replaceChildren();
} else {
  document.body.dataset.kind = kind;
  window.desktopPet.onAccessoryTrailUpdate((payload) => {
    if (payload?.kind !== kind || !Array.isArray(payload.points)) return;
    const points = payload.points
      .slice(0, 128)
      .filter((point) => Number.isFinite(point?.x)
        && Number.isFinite(point?.y)
        && Number.isFinite(point?.progress));
    if (points.length < 2) return;
    const fade = 1 - Math.min(1, Math.max(0, (Number(payload.animationProgress) - 0.76) / 0.24));
    svg.style.opacity = String(fade);
    if (kind === "evidence") {
      back.setAttribute("d", pathData(offsetPoints(points, 2.2)));
      front.setAttribute("d", pathData(offsetPoints(points, -2.2)));
    } else {
      const path = pathData(points);
      back.setAttribute("d", path);
      front.setAttribute("d", path);
    }
  });
}

function pathData(points) {
  return points.map((point, index) => `${index === 0 ? "M" : "L"} ${point.x.toFixed(2)} ${point.y.toFixed(2)}`).join(" ");
}

function offsetPoints(points, offset) {
  return points.map((point, index) => {
    const before = points[Math.max(0, index - 1)];
    const after = points[Math.min(points.length - 1, index + 1)];
    const deltaX = after.x - before.x;
    const deltaY = after.y - before.y;
    const length = Math.max(0.001, Math.hypot(deltaX, deltaY));
    const tapered = offset * Math.sin(Math.PI * point.progress);
    return {
      ...point,
      x: point.x + deltaY / length * tapered,
      y: point.y - deltaX / length * tapered,
    };
  });
}
