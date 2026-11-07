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

  demo.addEventListener('play', syncToggle);
  demo.addEventListener('pause', syncToggle);

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
