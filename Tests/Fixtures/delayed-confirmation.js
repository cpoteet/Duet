const composer = document.querySelector('[contenteditable]');
window.returnPresses = 0;
// mode: what the page does with a trusted Return keypress.
//   clear     takes the prompt and clears the composer after `delay` ms
//   navigate  takes the prompt and moves to a new conversation's URL
//   replace   swaps the composer's text for other text
//   ignore    swallows Return, as a provider that isn't ready might
//   newline   lets Return add a new line, as a provider setting might
window.configureSubmission = (mode, delay) => {
  composer.addEventListener('keydown', event => {
    if (event.key !== 'Enter' || event.shiftKey || !event.isTrusted) return;
    window.returnPresses++;
    if (mode === 'newline') return;
    event.preventDefault();
    if (mode === 'clear') setTimeout(() => { composer.textContent = ''; }, delay);
    if (mode === 'navigate') setTimeout(() => { history.pushState(null, '', '/chat/fixture-conversation'); }, delay);
    if (mode === 'replace') setTimeout(() => { composer.textContent = 'Provider suggestion'; }, delay);
  });
};
