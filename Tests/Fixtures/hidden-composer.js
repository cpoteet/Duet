const composer = document.querySelector('[contenteditable]:not(#prompt-textarea)');
composer.addEventListener('keydown', event => {
  if (event.key !== 'Enter' || event.shiftKey || !event.isTrusted) return;
  event.preventDefault();
  composer.textContent = '';
});
