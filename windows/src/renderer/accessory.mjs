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
  image.alt = labels[kind];
  image.src = await window.desktopPet.assetUrl(assetNames[kind]);
  button.addEventListener("click", () => {
    if (button.classList.contains("reclaim")) return;
    button.classList.add("reclaim");
    setTimeout(() => window.desktopPet.reclaimAccessory(sessionId, kind), 120);
  });
  document.addEventListener("contextmenu", (event) => event.preventDefault());
}
