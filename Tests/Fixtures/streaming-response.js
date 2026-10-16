window.startStreaming = (label, usesStatus = false, testID = null) => {
  document.getElementById("message").setAttribute("data-is-streaming", String(usesStatus));
  const controls = document.getElementById("controls");
  controls.replaceChildren();
  if (label !== null || testID !== null) {
    const button = document.createElement("button");
    if (label !== null) button.setAttribute("aria-label", label);
    if (testID !== null) button.setAttribute("data-testid", testID);
    controls.appendChild(button);
  }
};

window.finishStreaming = () => {
  document.getElementById("message").setAttribute("data-is-streaming", "false");
  document.getElementById("controls").replaceChildren();
};

window.setUnrelatedStop = enabled => {
  const controls = document.getElementById("unrelated-controls");
  controls.replaceChildren();
  if (enabled) {
    const button = document.createElement("button");
    button.setAttribute("aria-label", "Stop sharing");
    controls.appendChild(button);
  }
};
