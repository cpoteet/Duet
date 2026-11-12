// ChatGPT replaces its composer element when it takes a prompt.
document.addEventListener('keydown', event => {
  const composer = document.querySelector('#prompt-textarea');
  if (event.target !== composer || event.key !== 'Enter' || event.shiftKey || !event.isTrusted) return;
  event.preventDefault();
  const message = document.createElement('div');
  message.textContent = composer.innerText;
  document.body.appendChild(message);
  const replacement = document.createElement('div');
  replacement.id = 'prompt-textarea';
  replacement.contentEditable = 'true';
  composer.replaceWith(replacement);
});
