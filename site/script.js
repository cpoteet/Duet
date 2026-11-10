const navigation = document.querySelector('.site-nav');
const menuToggle = document.querySelector('.menu-toggle');
const menuLinks = document.querySelector('#nav-links');

function setMenuOpen(open) {
  navigation.classList.toggle('is-open', open);
  menuToggle.setAttribute('aria-expanded', String(open));
  menuToggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
}

menuToggle.hidden = false;
navigation.setAttribute('data-menu-ready', '');

menuToggle.addEventListener('click', () => {
  setMenuOpen(menuToggle.getAttribute('aria-expanded') !== 'true');
});

menuLinks.addEventListener('click', (event) => {
  // A link, or the dimmed page below the panel (which belongs to the panel element).
  if (event.target.closest('a') || event.target === menuLinks) setMenuOpen(false);
});

document.addEventListener('click', (event) => {
  if (!navigation.contains(event.target)) setMenuOpen(false);
});

navigation.addEventListener('focusout', (event) => {
  if (!navigation.contains(event.relatedTarget)) setMenuOpen(false);
});

navigation.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && menuToggle.getAttribute('aria-expanded') === 'true') {
    setMenuOpen(false);
    menuToggle.focus();
  }
});

window.matchMedia('(max-width: 760px)').addEventListener('change', () => {
  setMenuOpen(false);
});

const demo = document.querySelector('.demo-video');
const demoToggle = document.querySelector('.demo-toggle');

if (demo && demoToggle) {
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let pausedByViewer = reduceMotion.matches;

  demo.controls = false;
  demoToggle.hidden = false;

  const syncToggle = () => {
    const playing = !demo.paused;
    demoToggle.textContent = playing ? 'Pause' : 'Play';
    demoToggle.setAttribute('aria-label', playing ? 'Pause the Quick Prompt demo' : 'Play the Quick Prompt demo');
  };

  const play = () => {
    demo.play().catch(() => syncToggle());
  };

  // Step labels follow the video while it plays. Paused (including offscreen and the
  // reduced-motion start), they go back to a plain list.
  const stepList = document.querySelector('.demo-steps');
  const steps = stepList ? [...stepList.querySelectorAll('li')].map((li) => ({ li, start: Number(li.dataset.start) })) : [];
  let stepFrame = 0;

  const syncSteps = () => {
    const time = demo.currentTime;
    const end = demo.duration || 0;
    let current = 0;
    steps.forEach((step, index) => { if (time >= step.start) current = index; });
    steps.forEach((step, index) => {
      const isCurrent = index === current;
      step.li.classList.toggle('is-current', isCurrent);
      if (isCurrent) step.li.setAttribute('aria-current', 'step');
      else step.li.removeAttribute('aria-current');
      if (reduceMotion.matches) return;
      const stepEnd = steps[index + 1]?.start ?? end;
      let progress = index < current ? 1 : 0;
      if (isCurrent && stepEnd > step.start) progress = Math.min(1, (time - step.start) / (stepEnd - step.start));
      step.li.style.setProperty('--step-progress', progress);
    });
  };

  const tick = () => {
    syncSteps();
    stepFrame = requestAnimationFrame(tick);
  };

  const startSteps = () => {
    if (!stepList) return;
    stepList.setAttribute('data-playing', '');
    cancelAnimationFrame(stepFrame);
    tick();
  };

  const stopSteps = () => {
    if (!stepList) return;
    cancelAnimationFrame(stepFrame);
    stepList.removeAttribute('data-playing');
    for (const { li } of steps) {
      li.classList.remove('is-current');
      li.removeAttribute('aria-current');
      li.style.removeProperty('--step-progress');
    }
  };

  demo.addEventListener('play', syncToggle);
  demo.addEventListener('pause', syncToggle);
  demo.addEventListener('playing', startSteps);
  demo.addEventListener('pause', stopSteps);
  demo.addEventListener('timeupdate', () => { if (!demo.paused) syncSteps(); });

  demoToggle.addEventListener('click', () => {
    if (demo.paused) {
      pausedByViewer = false;
      play();
    } else {
      pausedByViewer = true;
      demo.pause();
    }
  });

  if ('IntersectionObserver' in window) {
    new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting && !pausedByViewer) play();
        else if (!entry.isIntersecting) demo.pause();
      }
    }, { threshold: 0.4 }).observe(demo);
  } else if (!pausedByViewer) {
    play();
  }

  syncToggle();
}
