const composer = document.querySelector('[contenteditable]');
const button = document.querySelector('button');
window.sendClicks = 0;
window.configureSubmission = (readinessDelay, confirmationDelay) => {
  if (readinessDelay !== null) {
    setTimeout(() => { button.disabled = false; }, readinessDelay);
  }
  button.addEventListener('click', () => {
    window.sendClicks++;
    if (confirmationDelay !== null) {
      setTimeout(() => { composer.textContent = ''; }, confirmationDelay);
    }
  });
};
