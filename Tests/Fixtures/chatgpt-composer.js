document.querySelector('button').addEventListener('click', () => {
  const composer = document.querySelector('#prompt-textarea');
  const message = document.createElement('div');
  message.textContent = composer.innerText;
  document.body.appendChild(message);
  const replacement = document.createElement('div');
  replacement.id = 'prompt-textarea';
  replacement.contentEditable = 'true';
  composer.replaceWith(replacement);
});
