// Glint download page: reads ../release.json (written by tools/publish_download.sh),
// fills in the links and starts the installer download. ?auto=0 skips the auto-start.
(async () => {
  const $ = (id) => document.getElementById(id);
  const mb = (b) => `${Math.round(b / 1048576)} MB`;
  let rel;
  try {
    const res = await fetch("../release.json", { cache: "no-store" });
    if (!res.ok) throw new Error(res.status);
    rel = await res.json();
  } catch {
    $("dl-status").textContent = "The download isn't available right now. Please try again in a few minutes.";
    return;
  }

  const setup = $("dl-setup");
  setup.href = rel.setup.url;
  setup.removeAttribute("aria-disabled");
  setup.querySelector("span").textContent = `Installer for Windows (${mb(rel.setup.bytes)})`;
  if (rel.zip) {
    const zip = $("dl-zip");
    zip.href = rel.zip.url;
    zip.textContent = `Portable zip (${mb(rel.zip.bytes)})`;
    zip.hidden = false;
  }
  $("dl-title").textContent = `Glint ${rel.version}`;
  $("dl-file").textContent = rel.setup.name;
  $("dl-file2").textContent = rel.setup.name;
  $("dl-hash").textContent = rel.setup.sha256;
  $("dl-meta").textContent = `Released ${rel.date} · Windows 10 and 11, 64-bit · Free closed beta`;

  if (new URLSearchParams(location.search).get("auto") === "0") {
    $("dl-status").textContent = "Choose a download below.";
    return;
  }
  $("dl-status").innerHTML = "Your download should start in a moment. If it doesn't, use the button below.";
  setTimeout(() => { location.href = rel.setup.url; }, 900);
})();
