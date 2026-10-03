// Glint website: screenshot lightbox and reveal-on-scroll. No tracking, no cookies.
(() => {
  const lb = document.getElementById("lightbox");
  const lbImg = lb.querySelector("img");
  const close = () => { lb.hidden = true; lbImg.removeAttribute("src"); };
  document.querySelectorAll(".shot").forEach((btn) => {
    btn.addEventListener("click", () => {
      lbImg.src = btn.dataset.full;
      lbImg.alt = btn.querySelector("img").alt;
      lb.hidden = false;
      lb.querySelector(".lb-close").focus();
    });
  });
  lb.addEventListener("click", close);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !lb.hidden) close(); });

  const items = document.querySelectorAll(".feature, .shot, .steps li, .legend, .beta, .faq details");
  if (!("IntersectionObserver" in window)) return;
  const io = new IntersectionObserver((entries) => {
    entries.forEach((en) => {
      if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); }
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  items.forEach((el, i) => {
    el.classList.add("reveal");
    el.style.transitionDelay = `${(i % 6) * 60}ms`;
    io.observe(el);
  });
})();
