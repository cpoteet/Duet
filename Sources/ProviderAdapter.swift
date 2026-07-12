import Foundation

struct ProviderAdapter {
    let composerSelectors: [String]
    let sendButtonSelectors: [String]
    let userMessageSelectors: [String]

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
                ]
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
                ]
            )
        }
    }

    func readinessScript() -> String {
        """
        (() => {
          const composerSelectors = \(jsonArray(composerSelectors));
          const composer = composerSelectors.map(selector => document.querySelector(selector)).find(Boolean);
          return Boolean(composer && !composer.closest('[aria-hidden="true"]'));
        })()
        """
    }

    func loginRequiredScript() -> String {
        """
        (() => {
          const text = (document.body?.innerText || '').toLowerCase();
          return text.includes('log in') || text.includes('sign in') || text.includes('continue with google');
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

    func submissionConfirmationScript(prompt: String) -> String {
        let encodedPrompt = jsonString(prompt)
        return """
        (() => {
          const prompt = \(encodedPrompt).trim();
          const composerSelectors = \(jsonArray(composerSelectors));
          const userMessageSelectors = \(jsonArray(userMessageSelectors));
          const composer = composerSelectors.map(selector => document.querySelector(selector)).find(Boolean);
          const composerText = composer
            ? (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement ? composer.value : composer.innerText || composer.textContent || '')
            : '';
          if (!composer || composerText.trim().length === 0) return true;

          const messages = userMessageSelectors.flatMap(selector => Array.from(document.querySelectorAll(selector)));
          return messages.slice(-5).some(message => {
            const text = (message.innerText || message.textContent || '').trim();
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
