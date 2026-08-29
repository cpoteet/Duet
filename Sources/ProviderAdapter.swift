import Foundation

struct ProviderAdapter {
    let composerSelectors: [String]
    let sendButtonSelectors: [String]
    let userMessageSelectors: [String]
    /// Elements present only while the provider is generating a response.
    let generationIndicatorSelectors: [String]
    /// A provider-owned file input used to bridge WebKit file drops through
    /// the same upload path as the provider's working file picker.
    let fileDropInputSelector: String?

    static func adapter(for service: ChatService) -> ProviderAdapter {
        switch service {
        case .chatGPT:
            ProviderAdapter(
                composerSelectors: [
                    "#prompt-textarea",
                    "textarea[data-id='root']",
                    "textarea",
                    "[contenteditable='true'][role='textbox']"
                ],
                sendButtonSelectors: [
                    "button[data-testid='send-button']",
                    "button[data-testid*='send']",
                    "button[aria-label='Send prompt']",
                    "button[aria-label*='Send']",
                    "button[type='submit']"
                ],
                userMessageSelectors: [
                    "[data-message-author-role='user']"
                ],
                generationIndicatorSelectors: [
                    "button[data-testid='stop-button']",
                    "button[aria-label='Stop streaming']",
                    "button[aria-label='Stop generating']"
                ],
                fileDropInputSelector: nil
            )
        case .claude:
            ProviderAdapter(
                composerSelectors: [
                    "div[contenteditable='true'][role='textbox']",
                    "[contenteditable='true'][data-placeholder]",
                    "div[contenteditable='true']",
                    "textarea"
                ],
                sendButtonSelectors: [
                    "button[aria-label='Send message']",
                    "button[aria-label*='Send']",
                    "button[data-testid*='send']",
                    "button[type='submit']"
                ],
                userMessageSelectors: [
                    "[data-testid='user-message']",
                    "[data-is-streaming='false'] .font-user-message"
                ],
                generationIndicatorSelectors: [
                    "[data-is-streaming='true']",
                    "button[aria-label='Stop response']"
                ],
                fileDropInputSelector: "input[type='file'][data-testid='file-upload']"
            )
        }
    }

    /// Claude's drop handler reads `DataTransferItem.webkitGetAsEntry()`,
    /// which can return no entries for Finder drops in an embedded WKWebView.
    /// Its file picker reads the standard input `files` list and works. Route
    /// user-initiated file drops through that same provider-owned input.
    func fileDropCompatibilityScript() -> String? {
        guard let fileDropInputSelector else { return nil }
        let encodedSelector = jsonString(fileDropInputSelector)
        return """
        (() => {
          const hostname = location.hostname.toLowerCase();
          const isTrustedClaudePage = location.protocol === 'https:' &&
            (hostname === 'claude.ai' || hostname.endsWith('.claude.ai'));
          if (!isTrustedClaudePage || window.__duetFileDropCompatibilityInstalled) return;
          window.__duetFileDropCompatibilityInstalled = true;

          const findUploadInput = () => {
            const input = document.querySelector(\(encodedSelector));
            return input instanceof HTMLInputElement && !input.disabled ? input : null;
          };
          const containsFiles = event =>
            Array.from(event.dataTransfer?.types || []).includes('Files');
          const clearProviderDropOverlay = dataTransfer => {
            if (!document.body) return;
            const dragLeave = new Event('dragleave', { bubbles: true, cancelable: true });
            Object.defineProperty(dragLeave, 'dataTransfer', { value: dataTransfer });
            Object.defineProperty(dragLeave, 'relatedTarget', { value: null });
            document.body.dispatchEvent(dragLeave);
          };

          window.addEventListener('dragover', event => {
            if (!containsFiles(event) || !findUploadInput()) return;
            event.preventDefault();
            event.dataTransfer.dropEffect = 'copy';
          }, true);

          window.addEventListener('drop', event => {
            const files = event.dataTransfer?.files;
            if (!files || files.length === 0) return;
            const input = findUploadInput();
            if (!input) return;

            try {
              input.files = files;
            } catch (_) {
              return;
            }

            event.preventDefault();
            event.stopImmediatePropagation();
            input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
            input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
            clearProviderDropOverlay(event.dataTransfer);
          }, true);
        })();
        """
    }

    func readinessScript() -> String {
        """
        (() => {
          const composerSelectors = \(jsonArray(composerSelectors));
          const isVisible = element => element && element.getClientRects().length > 0 && !element.closest('[aria-hidden="true"]');
          return composerSelectors.map(selector => document.querySelector(selector)).some(isVisible);
        })()
        """
    }

    func loginRequiredScript() -> String {
        """
        (() => {
          const isVisible = element => element && element.getClientRects().length > 0 && !element.closest('[aria-hidden="true"]');
          const normalize = text => text.replace(/\\s+/g, ' ').trim().toLowerCase();
          const loginLabels = new Set([
            'log in', 'login', 'sign in', 'sign in with google', 'continue with google',
            'continue with apple', 'continue with microsoft', 'continue with email'
          ]);
          return Array.from(document.querySelectorAll('a, button, [role="button"], form')).some(element => {
            if (!isVisible(element)) return false;
            const destination = (element.getAttribute('href') || element.getAttribute('action') || '').toLowerCase();
            if (/(^|\\/)(login|signin|sign-in)([\\/?#]|$)/.test(destination)) return true;
            const label = element.getAttribute('aria-label') || element.innerText || element.textContent || '';
            return loginLabels.has(normalize(label));
          });
        })()
        """
    }

    /// Fill first, then let the native app wait for the site's reactive UI to
    /// enable and render its send button before calling `submissionScript()`.
    func fillScript(prompt: String) -> String {
        let encodedPrompt = jsonString(prompt)
        return """
        (() => {
          const prompt = \(encodedPrompt);
          const composerSelectors = \(jsonArray(composerSelectors));
          const isVisible = element => element && element.getClientRects().length > 0 && !element.closest('[aria-hidden="true"]');
          const composer = composerSelectors.map(selector => document.querySelector(selector)).find(isVisible);
          if (!composer) return { ok: false, reason: 'composer-not-found' };

          const existingText = composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement
            ? composer.value
            : composer.innerText || composer.textContent || '';
          if (existingText.trim().length > 0) return { ok: false, reason: 'composer-not-empty' };

          composer.focus();
          if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
            const prototype = composer instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
            if (descriptor && descriptor.set) {
              descriptor.set.call(composer, prompt);
            } else {
              composer.value = prompt;
            }
          } else {
            document.execCommand('selectAll', false, null);
            const inserted = document.execCommand('insertText', false, prompt);
            if (!inserted || (composer.innerText || '').trim() !== prompt.trim()) composer.textContent = prompt;
          }

          try {
            composer.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, composed: true, inputType: 'insertText', data: prompt }));
            composer.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: prompt }));
          } catch (_) {
            composer.dispatchEvent(new Event('input', { bubbles: true }));
          }
          composer.dispatchEvent(new Event('change', { bubbles: true }));
          composer.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: ' ' }));
          return { ok: true };
        })()
        """
    }

    func submissionScript() -> String {
        """
        (() => {
          const sendButtonSelectors = \(jsonArray(sendButtonSelectors));
          const isVisible = element => element && element.getClientRects().length > 0 && !element.closest('[aria-hidden="true"]');
          const buttons = sendButtonSelectors.flatMap(selector => Array.from(document.querySelectorAll(selector)));
          const sendButton = buttons.find(button =>
            isVisible(button) && !button.disabled && button.getAttribute('aria-disabled') !== 'true'
          );
          if (!sendButton) return { ok: false, reason: 'send-button-not-ready' };
          sendButton.click();
          return { ok: true };
        })()
        """
    }

    func submissionBaselineScript() -> String {
        """
        (() => {
          const userMessageSelectors = \(jsonArray(userMessageSelectors));
          return userMessageSelectors.flatMap(selector => Array.from(document.querySelectorAll(selector))).length;
        })()
        """
    }

    func submissionConfirmationScript(prompt: String, baselineMessageCount: Int) -> String {
        let encodedPrompt = jsonString(prompt)
        return """
        (() => {
          const normalize = text => text.replace(/\\s+/g, ' ').trim();
          const prompt = normalize(\(encodedPrompt));
          const userMessageSelectors = \(jsonArray(userMessageSelectors));
          const messages = userMessageSelectors.flatMap(selector => Array.from(document.querySelectorAll(selector)));
          if (messages.length <= \(baselineMessageCount)) return false;
          return messages.slice(\(baselineMessageCount)).some(message => {
            const text = normalize(message.innerText || message.textContent || '');
            return text === prompt || text.includes(prompt);
          });
        })()
        """
    }

    private func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]) else { return "\"\"" }
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
