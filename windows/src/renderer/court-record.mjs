const summary = document.querySelector("#summary");
const list = document.querySelector("#record-list");

window.desktopPet.onCourtRecordData(render);

function render(payload) {
  const entries = Array.isArray(payload?.entries) ? payload.entries : [];
  const discovered = entries.filter((entry) => entry.progress).length;
  summary.textContent = `已发现 ${discovered} / ${entries.length}  ·  只记录真实触发`;
  list.replaceChildren(...entries.map(renderRow));
}

function renderRow({ definition, progress }) {
  const row = document.createElement("article");
  row.className = `record-row${progress ? "" : " locked"}`;
  row.setAttribute("aria-label", progress ? definition.title : "尚未发现的法庭记录");

  const icon = document.createElement("span");
  icon.className = "record-icon";
  icon.textContent = progress ? definition.icon : "?";

  const title = document.createElement("strong");
  title.className = "record-title";
  title.textContent = progress ? definition.title : "尚未发现";

  const detail = document.createElement("span");
  detail.className = "record-detail";
  detail.textContent = progress
    ? unlockedDetail(definition, progress)
    : `${definition.category} · ${definition.lockedHint}`;

  row.append(icon, title, detail);
  return row;
}

function unlockedDetail(definition, progress) {
  const countText = progress.count > 0 ? `触发 ${progress.count} 次` : "已解锁";
  const unlockedAt = new Date(progress.unlockedAt);
  const lastSeen = new Date(progress.lastSeen);
  const dateText = progress.lastSeen > progress.unlockedAt + 60_000
    ? `首次 ${formatDay(unlockedAt)} · 最近 ${formatRecent(lastSeen)}`
    : `发现于 ${formatDay(unlockedAt)}`;
  return `${definition.category} · ${definition.detail}\n${countText} · ${dateText}`;
}

function formatDay(date) {
  return new Intl.DateTimeFormat("zh-CN", { dateStyle: "short" }).format(date);
}

function formatRecent(date) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}
