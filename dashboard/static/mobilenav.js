"use strict";
/* mobilenav.js — turns the four-pane desktop grid into a drawer app on phones.
   Additive only: it toggles body classes (m-chats / m-peel / m-chat) that the
   stylesheet's media queries turn into off-canvas drawers. No existing element,
   id, class, or handler is touched — the desktop layout is untouched above the
   breakpoint, and every rail keeps working exactly as before. */
(() => {
  const bar = document.getElementById("mobilebar");
  const backdrop = document.getElementById("mbackdrop");
  if (!bar || !backdrop) return;

  const PANES = ["chats", "peel", "chat"];   // "stage" = all drawers closed
  const buttons = [...bar.querySelectorAll(".mbtn")];

  function setPane(pane) {
    for (const p of PANES) document.body.classList.toggle("m-" + p, p === pane);
    const anyOpen = PANES.includes(pane);
    backdrop.hidden = !anyOpen;
    for (const b of buttons)
      b.classList.toggle("active", b.dataset.pane === (anyOpen ? pane : "stage"));
    // A newly-revealed pane may need to remeasure (canvas/graph, calendar grid).
    if (typeof window.dispatchEvent === "function")
      window.dispatchEvent(new Event("resize"));
  }

  function closeDrawers() { setPane("stage"); }

  for (const b of buttons)
    b.addEventListener("click", () => {
      const pane = b.dataset.pane;
      // tapping the already-open pane (or Stage) closes back to the stage
      const isOpen = PANES.includes(pane) && document.body.classList.contains("m-" + pane);
      setPane(pane === "stage" || isOpen ? "stage" : pane);
    });

  backdrop.addEventListener("click", closeDrawers);
  window.addEventListener("keydown", e => {
    if (e.key === "Escape" && PANES.some(p => document.body.classList.contains("m-" + p)))
      closeDrawers();
  });

  // Leaving mobile width must never strand a body in a drawer state.
  let wasMobile = null;
  const DESKTOP = 1100;   // must match the drawer-mode breakpoint in style.css
  function onResize() {
    const mobile = window.innerWidth <= DESKTOP;
    if (wasMobile === true && !mobile) closeDrawers();  // back to desktop → reset
    wasMobile = mobile;
  }
  window.addEventListener("resize", onResize);
  onResize();
})();
