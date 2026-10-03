document.querySelector('button').addEventListener('click', () => {
  const composer = document.querySelector('[contenteditable]:not(#prompt-textarea)');
  composer.textContent = '';
});
