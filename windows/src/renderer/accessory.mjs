const query = new URLSearchParams(location.search);
const kind = query.get("kind");
const sessionId = Number(query.get("sessionId"));
const assetNames = {
  "attorney-badge": "scatter-attorney-badge-cg.png",
  "case-file": "scatter-case-file-cg.png",
  magatama: "scatter-magatama-cg.png",
  evidence: "scatter-evidence-cg.png",
  pen: "scatter-pen-cg.png",
  "sticky-note": "scatter-notes-cg.png",
};
const labels = {
  "attorney-badge": "归档律师徽章",
  "case-file": "归档案件文件",
  magatama: "归档勾玉",
  evidence: "归档证物",
  pen: "归档钢笔",
  "sticky-note": "归档便签",
};

if (!assetNames[kind] || !Number.isSafeInteger(sessionId)) {
  document.body.replaceChildren();
} else {
  const button = document.querySelector("#accessory");
  const image = document.querySelector("#accessory-image");
  button.setAttribute("aria-label", labels[kind]);
  button.dataset.kind = kind;
  image.alt = labels[kind];
  image.src = await window.desktopPet.assetUrl(assetNames[kind]);
  let reclaiming = false;
  button.addEventListener("click", () => {
    if (reclaiming) return;
    reclaiming = true;
    window.desktopPet.reclaimAccessory(sessionId, kind);
  });
  window.desktopPet.onAccessoryReclaimStart((event) => {
    if (event?.kind !== kind || !Number.isFinite(event.durationMs)) return;
    button.style.setProperty("--reclaim-duration", `${event.durationMs}ms`);
    button.classList.add("reclaim");
  });
  window.desktopPet.onAccessoryFade(() => button.classList.add("fade"));
  document.addEventListener("contextmenu", (event) => event.preventDefault());
}
