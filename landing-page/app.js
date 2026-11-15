(() => {
  "use strict";

  const config = window.DUBBY_CONFIG || {};
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  document.documentElement.classList.add("js");

  // ---------- Phone screens: one template per screen, cloned into every phone that names it ----------
  document.querySelectorAll("[data-screen-src]").forEach((slot) => {
    const template = document.getElementById("screen-" + slot.dataset.screenSrc);
    if (template) slot.appendChild(template.content.cloneNode(true));
  });

  // Deterministic waveform bars, so every visit draws the same shape.
  document.querySelectorAll("[data-wave]").forEach((wave) => {
    const count = Number(wave.dataset.wave);
    const seed = Number(wave.dataset.seed);
    for (let i = 0; i < count; i += 1) {
      const envelope = Math.sin((i / (count - 1)) * Math.PI) ** 0.6;
      const jitter = Math.abs(Math.sin(i * (1.7 + seed * 0.13) + seed) * Math.cos(i * 0.6 + seed * 0.4));
      const bar = document.createElement("i");
      bar.style.setProperty("--h", Math.round(14 + 86 * envelope * (0.35 + 0.65 * jitter)) + "%");
      wave.appendChild(bar);
    }
  });

  // The take waveform fills in left to right, as if being recorded, then loops.
  const takeWaves = document.querySelectorAll(".wave-you");
  if (!reduceMotion) {
    let lit = 0;
    setInterval(() => {
      lit = (lit + 1) % 46;
      takeWaves.forEach((wave) => {
        Array.from(wave.children).forEach((bar, i) => bar.classList.toggle("lit", i < lit));
      });
    }, 110);
  } else {
    takeWaves.forEach((wave) => Array.from(wave.children).forEach((bar) => bar.classList.add("lit")));
  }

  // ---------- Coach tip types out at 40 characters per second, matching the app ----------
  function typeTip(el) {
    const text = el.dataset.fullText || el.textContent;
    el.dataset.fullText = text;
    if (reduceMotion) { el.textContent = text; return; }
    clearInterval(el._typer);
    let shown = 0;
    // The unrevealed rest is laid out but transparent, so the panel never changes height.
    const render = () => {
      el.innerHTML = "";
      el.append(text.slice(0, shown));
      const rest = document.createElement("span");
      rest.className = "unrevealed";
      rest.textContent = text.slice(shown);
      el.append(rest);
    };
    render();
    el._typer = setInterval(() => {
      shown += 1;
      render();
      if (shown >= text.length) clearInterval(el._typer);
    }, 25);
  }

  // ---------- Hero: the language word cycles through the scenes' languages, each in its poster colour ----------
  const rotator = document.querySelector("[data-rotator]");
  if (rotator && !reduceMotion) {
    const words = [["Korean", "--ko"], ["Spanish", "--es"], ["English", "--en"]];
    let index = 0;
    setInterval(() => {
      const current = rotator.querySelector(".rotator-word");
      index = (index + 1) % words.length;
      current.classList.add("is-out");
      setTimeout(() => {
        current.textContent = words[index][0];
        current.style.setProperty("--c", "var(" + words[index][1] + ")");
        current.classList.remove("is-out");
        current.classList.add("is-in");
        requestAnimationFrame(() => requestAnimationFrame(() => current.classList.remove("is-in")));
      }, 320);
    }, 2400);
  }

  // ---------- Poster wall: duplicate each row once so the marquee loops without a seam ----------
  document.querySelectorAll("[data-wall-row]").forEach((row) => {
    Array.from(row.children).forEach((card) => {
      const copy = card.cloneNode(true);
      copy.setAttribute("aria-hidden", "true");
      row.appendChild(copy);
    });
  });

  // ---------- Nav background once the page scrolls ----------
  const nav = document.querySelector("[data-nav]");
  const onScrollNav = () => nav.classList.toggle("is-scrolled", window.scrollY > 12);
  window.addEventListener("scroll", onScrollNav, { passive: true });
  onScrollNav();

  // ---------- Statement: words light up as the paragraph scrolls through the viewport ----------
  const statement = document.querySelector("[data-light-text]");
  if (statement) {
    const words = statement.textContent.trim().split(/\s+/);
    statement.setAttribute("aria-label", statement.textContent.trim());
    statement.innerHTML = "";
    words.forEach((word, i) => {
      const span = document.createElement("span");
      span.className = "w";
      span.setAttribute("aria-hidden", "true");
      span.textContent = word;
      statement.append(span, i < words.length - 1 ? " " : "");
    });
    const spans = statement.querySelectorAll(".w");
    const light = () => {
      const rect = statement.getBoundingClientRect();
      const vh = window.innerHeight;
      const progress = Math.min(Math.max((vh * 0.85 - rect.top) / (rect.height + vh * 0.35), 0), 1);
      const count = Math.round(progress * spans.length);
      spans.forEach((span, i) => span.classList.toggle("lit", i < count));
    };
    if (!reduceMotion) {
      window.addEventListener("scroll", light, { passive: true });
      light();
    }
  }

  // ---------- Journey: the sticky phone shows the step nearest the middle of the viewport ----------
  const steps = document.querySelectorAll("[data-step]");
  const stepGlow = document.querySelector("[data-step-glow]");
  // Each step's glow takes the colour of what's on screen: the poster deck, the role, the studio, the hologram, the wrap.
  const stepColors = { discover: "#c7923a", role: "#5c8a5a", studio: "#3f7a52", coach: "#6ff2ff", post: "#e58fb4" };
  const stepScreens = document.querySelectorAll("[data-step-screen]");
  let activeStep = "";
  const setStep = (id) => {
    if (id === activeStep) return;
    activeStep = id;
    if (stepGlow) stepGlow.style.setProperty("--glow-c", stepColors[id]);
    steps.forEach((step) => step.classList.toggle("is-active", step.dataset.step === id));
    stepScreens.forEach((screen) => {
      const on = screen.dataset.stepScreen === id;
      screen.classList.toggle("is-active", on);
      if (on && id === "coach") screen.querySelectorAll("[data-type-text]").forEach(typeTip);
    });
  };
  const stepObserver = new IntersectionObserver((entries) => {
    entries.forEach((entry) => { if (entry.isIntersecting) setStep(entry.target.dataset.step); });
  }, { rootMargin: "-45% 0px -45% 0px" });
  steps.forEach((step) => stepObserver.observe(step));

  // Coach tips outside the journey type out when they come into view.
  const tipObserver = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) { typeTip(entry.target); tipObserver.unobserve(entry.target); }
    });
  }, { threshold: 0.6 });
  document.querySelectorAll("[data-type-text]").forEach((tip) => {
    if (!tip.closest("[data-step-screen]")) tipObserver.observe(tip);
  });

  // ---------- Reveal sections once ----------
  const revealTargets = document.querySelectorAll(".section-title, .friend-col, .join h2, .join-form, .faq-list");
  revealTargets.forEach((el) => el.classList.add("reveal"));
  const revealObserver = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) { entry.target.classList.add("is-in"); revealObserver.unobserve(entry.target); }
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  revealTargets.forEach((el) => revealObserver.observe(el));

  // ---------- Plan choice: the submit button and note say what happens next ----------
  const joinForm = document.querySelector(".join-form");
  if (joinForm) {
    const submit = joinForm.querySelector('button[type="submit"]');
    const note = joinForm.querySelector("[data-plan-note]");
    const syncPlan = () => {
      const founding = joinForm.querySelector('input[name="plan"]:checked')?.value === "founding";
      submit.textContent = founding ? submit.dataset.submitFounding : submit.dataset.submitFree;
      note.textContent = founding
        ? "Next, pay securely with Whop. Cancel anytime."
        : "Free to join. No card needed.";
    };
    joinForm.querySelectorAll('input[name="plan"]').forEach((radio) => radio.addEventListener("change", syncPlan));
    syncPlan();
  }

  // ---------- Whop checkout, mounted inline after a founding signup ----------
  let whopScript;
  function loadWhop() {
    whopScript ??= new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "https://cdn.whop.com/elements/amber/elements.js";
      script.setAttribute("data-whop-elements", "");
      script.onload = () => resolve(window.WhopElements);
      script.onerror = () => reject(new Error("Whop checkout didn't load."));
      document.head.appendChild(script);
    });
    return whopScript;
  }

  function mountWhopCheckout(box, email) {
    const host = document.createElement("div");
    host.className = "whop-checkout";
    host.id = "whop-checkout";
    box.append(host);
    const options = {
      plan: config.whopPlanId,
      // The Convex webhook matches the payment to this waitlist row by the email in metadata.
      metadata: { email },
      onComplete: (completion) => {
        if (completion.result !== "payment") return;
        // Fulfillment happens in the Convex webhook; this only updates what the buyer sees.
        box.replaceChildren(joinedMessage("You're a founding member.", "Payment received. Your price is locked in, and you'll be first in when Dubby opens."));
      },
    };
    // Whop only accepts an https return URL (used after redirect-based payment methods).
    if (window.location.protocol === "https:") options.returnUrl = window.location.origin + "/?paid=1#join";
    loadWhop()
      .then((WhopElements) => {
        const checkout = WhopElements().checkout.create(options);
        checkout.create("checkout").mount("#whop-checkout");
      })
      .catch(() => {
        host.textContent = "Checkout couldn't load. Your spot is saved; we'll email you a payment link.";
        host.classList.add("whop-error");
      });
  }

  function joinedMessage(titleText, bodyText) {
    const box = document.createElement("div");
    box.className = "joined";
    box.setAttribute("tabindex", "-1");
    const title = document.createElement("p");
    title.className = "joined-title";
    title.textContent = titleText;
    const body = document.createElement("p");
    body.textContent = bodyText;
    box.append(title, body);
    return box;
  }

  // ---------- Waitlist forms ----------
  const params = new URLSearchParams(window.location.search);
  const source = params.get("utm_source") || params.get("ref") || "";

  function showJoined(form, email, plan) {
    let box;
    if (plan === "founding" && config.whopPlanId) {
      box = joinedMessage("Your spot is saved. One step left.", "Lock in $4.99/month for life. Checkout is handled by Whop.");
      box.classList.add("joined-checkout");
      mountWhopCheckout(box, email);
    } else if (plan === "founding") {
      box = joinedMessage("Your founding spot is saved.", "We'll email " + email + " with a link to lock in your price.");
    } else {
      box = joinedMessage("You're on the list.", "We'll email " + email + " when your scene is ready.");
      const link = document.createElement("a");
      link.className = "btn btn-secondary btn-small";
      link.href = "#join";
      link.textContent = "See the founding plan";
      box.append(link);
    }
    form.classList.add("is-done");
    form.replaceChildren(box);
    box.focus({ preventScroll: true });
  }

  if (params.get("paid") === "1") {
    const form = document.querySelector(".join-form");
    if (form) {
      form.classList.add("is-done");
      form.replaceChildren(joinedMessage("Thanks! We're confirming your payment.", "Your founding spot is saved. You'll get an email once Whop confirms it."));
    }
  }

  document.querySelectorAll("[data-waitlist-form]").forEach((form) => {
    const status = form.querySelector(".form-status");
    const button = form.querySelector('button[type="submit"]');
    const setError = (message) => {
      status.textContent = message;
      status.classList.add("is-error");
    };

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      status.textContent = "";
      status.classList.remove("is-error");

      const data = new FormData(form);
      const email = String(data.get("email") || "").trim();
      const emailInput = form.querySelector('input[type="email"]');
      if (!emailInput.checkValidity() || email === "") {
        setError("Enter your email address, like you@email.com.");
        emailInput.focus();
        return;
      }
      if (!config.waitlistEndpoint) {
        setError("Signups aren't open yet. Please try again soon.");
        return;
      }

      const plan = String(data.get("plan") || "free");
      const label = button.textContent;
      button.disabled = true;
      button.textContent = "Saving…";
      try {
        const response = await fetch(config.waitlistEndpoint, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            email,
            plan,
            language: String(data.get("language") || ""),
            source,
            website: String(data.get("website") || ""),
          }),
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(result.error || "Something went wrong.");
        showJoined(form, email, plan);
      } catch (error) {
        const offline = error instanceof TypeError;
        setError(offline ? "Couldn't reach the server. Check your connection and try again." : error.message + " Please try again.");
        button.disabled = false;
        button.textContent = label;
      }
    });
  });
})();
