/* Vinculum — motion. Design only.
   Everything here is enhancement: if this file never loads, every page
   stays fully readable. Pair with class="no-js" on <html>, removed below. */

(function () {
  document.documentElement.classList.remove("no-js");

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var fine = window.matchMedia("(hover: hover) and (pointer: fine)").matches;

  /* Custom cursor. Opt in with <body class="has-cursor">.
     Pointer devices only — never hide the cursor on touch. */
  if (fine && !reduced && document.body.classList.contains("has-cursor")) {
    var cursor = document.createElement("div");
    cursor.className = "cursor";
    document.body.appendChild(cursor);

    var x = 0, y = 0, drawn = false;
    document.addEventListener("mousemove", function (e) {
      x = e.clientX; y = e.clientY;
      if (!drawn) {
        drawn = true;
        requestAnimationFrame(function () {
          cursor.style.transform = "translate(" + x + "px," + y + "px) translate(-50%,-50%)";
          drawn = false;
        });
      }
    });

    var hot = "a, button, .cell, .phone-btn, [data-cursor]";
    document.querySelectorAll(hot).forEach(function (el) {
      el.addEventListener("mouseenter", function () { cursor.classList.add("hovering"); });
      el.addEventListener("mouseleave", function () { cursor.classList.remove("hovering"); });
    });

    /* Invert over dark sections so the dot stays visible. */
    var darks = document.querySelectorAll(".hero, .section--dark, .manifesto");
    if (darks.length && "IntersectionObserver" in window) {
      document.addEventListener("mousemove", function (e) {
        var over = false;
        darks.forEach(function (d) {
          var r = d.getBoundingClientRect();
          if (e.clientY >= r.top && e.clientY <= r.bottom) over = true;
        });
        cursor.classList.toggle("on-dark", over);
      });
    }
  }

  /* Scroll reveal. Without IntersectionObserver, show everything. */
  var reveals = document.querySelectorAll(".reveal");
  if (!reveals.length) return;

  if (reduced || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("visible"); });
    return;
  }

  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        io.unobserve(entry.target);
      }
    });
  }, { threshold: 0.1, rootMargin: "0px 0px -50px 0px" });

  reveals.forEach(function (el) { io.observe(el); });
})();
