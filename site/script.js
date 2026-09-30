const navigation = document.querySelector('.site-nav');
const menuToggle = document.querySelector('.menu-toggle');
const menuLinks = document.querySelector('#nav-links');

function setMenuOpen(open) {
  navigation.classList.toggle('is-open', open);
  menuToggle.setAttribute('aria-expanded', String(open));
  menuToggle.textContent = open ? 'Close' : 'Menu';
}

menuToggle.hidden = false;
navigation.setAttribute('data-menu-ready', '');

menuToggle.addEventListener('click', () => {
  setMenuOpen(menuToggle.getAttribute('aria-expanded') !== 'true');
});

menuLinks.addEventListener('click', (event) => {
  if (event.target.closest('a')) setMenuOpen(false);
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
