// agent-ssh landing — progressive enhancement only.
// Everything degrades to a fully readable static page without JS.
(() => {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* Reveal on scroll via IntersectionObserver (no scroll handlers). */
  const revealables = document.querySelectorAll("[data-reveal]");
  if (reduceMotion || !("IntersectionObserver" in window)) {
    revealables.forEach((el) => el.classList.add("in"));
  } else {
    const io = new IntersectionObserver(
      (entries, obs) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            obs.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -10% 0px", threshold: 0.12 }
    );
    revealables.forEach((el) => io.observe(el));
  }

  /* Type out the final terminal command once it scrolls into view. */
  const typedEl = document.querySelector(".typed");
  if (typedEl) {
    const text = typedEl.dataset.type || "";
    if (reduceMotion) {
      typedEl.textContent = text;
    } else {
      const run = () => {
        let i = 0;
        const tick = () => {
          typedEl.textContent = text.slice(0, i);
          if (i++ <= text.length) setTimeout(tick, 55 + Math.random() * 40);
        };
        tick();
      };
      if ("IntersectionObserver" in window) {
        const once = new IntersectionObserver((entries, obs) => {
          entries.forEach((e) => {
            if (e.isIntersecting) {
              run();
              obs.disconnect();
            }
          });
        });
        once.observe(typedEl);
      } else {
        run();
      }
    }
  }
})();
