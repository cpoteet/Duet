import Foundation

struct ProviderAdapter {
    /// The provider's own app hosts, which page scripts check before running.
    let pageHosts: [String]
    let composerSelectors: [String]
    let sendButtonSelectors: [String]
    /// Elements present only while the provider is generating a response.
    let generationIndicatorSelectors: [String]
    let generationControlScopeSelector: String
    let generationControlSelectors: [String]
    /// A provider-owned file input used to bridge WebKit file drops through
    /// the same upload path as the provider's working file picker.
    let fileDropInputSelector: String?
    /// Text that marks the printable card around a provider Print button that
    /// doesn't call `window.print()`, such as Claude's recipe cards. `nil`
    /// leaves Print buttons alone and bridges only `window.print()`.
    let printableRegionMarkers: [String]?
    /// The provider sits behind an interstitial bot check (Cloudflare) that
    /// can finish loading without showing usable app UI in an embedded view.
    let detectsVerificationChallenge: Bool
    /// The provider's first embedded load can finish with an empty document,
    /// so one automatic reload is allowed.
    let retriesBlankInitialLoad: Bool

    static func adapter(for service: ChatService) -> ProviderAdapter {
        switch service {
        case .chatGPT:
            ProviderAdapter(
                pageHosts: service.providerPageHosts,
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
                generationIndicatorSelectors: [
                    "button[data-testid='stop-button']"
                ],
                generationControlScopeSelector: "[class*='ComposerLayoutRoot-'], form",
                generationControlSelectors: ["button[aria-label^='Stop' i]"],
                fileDropInputSelector: nil,
                printableRegionMarkers: nil,
                detectsVerificationChallenge: false,
                retriesBlankInitialLoad: false
            )
        case .claude:
            ProviderAdapter(
                pageHosts: service.providerPageHosts,
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
                generationIndicatorSelectors: [
                    "[data-is-streaming='true']",
                    "button[data-testid='chat-input-stop']"
                ],
                generationControlScopeSelector: ".relative.w-full.min-w-0, form",
                generationControlSelectors: ["button[aria-label^='Stop' i]"],
                fileDropInputSelector: "input[type='file'][data-testid='file-upload']",
                printableRegionMarkers: ["ingredients", "steps"],
                detectsVerificationChallenge: true,
                retriesBlankInitialLoad: true
            )
        }
    }

    /// Claude's drop handler reads `DataTransferItem.webkitGetAsEntry()`,
    /// which can return no entries for Finder drops in an embedded WKWebView.
    /// Its file picker reads the standard input `files` list and works. Route
    /// user-initiated file drops through that same provider-owned input.
    func fileDropCompatibilityScript() -> String? {
        guard let fileDropInputSelector else { return nil }
        let encodedSelector = JavaScriptLiteral.string(fileDropInputSelector)
        return """
        (() => {
          const isProviderPage = location.protocol === 'https:' && \(PageOriginScript.isAllowedHost(pageHosts));
          if (!isProviderPage || window.__duetFileDropCompatibilityInstalled) return;
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

    /// Returns `true` when the loaded page is a bot-check interstitial rather
    /// than the provider's app, or `nil` when this provider has none. A page
    /// with a usable composer is the app, whatever its title or text says.
    func verificationChallengeScript() -> String? {
        guard detectsVerificationChallenge else { return nil }
        return """
        (() => {
          \(composerHelpers)
          if (findComposer()) return false;
          const title = (document.title || '').toLowerCase();
          const text = (document.body?.innerText || '').slice(0, 1500).toLowerCase();
          const hasChallenge = Boolean(document.querySelector('#challenge-error-text, iframe[src*="challenges.cloudflare.com"]'));
          return hasChallenge || title.includes('just a moment') || text.includes('enable javascript and cookies');
        })()
        """
    }

    /// Returns `true` when the loaded document has no app content at all, or
    /// `nil` when this provider doesn't retry blank loads.
    func blankPageScript() -> String? {
        guard retriesBlankInitialLoad else { return nil }
        return """
        (() => {
          const hasAppContent = Boolean(document.body?.innerText?.trim()) || Boolean(
            document.querySelector('main, [role="main"], textarea, [contenteditable="true"], button, a')
          );
          return !hasAppContent;
        })()
        """
    }

    /// Page-side helper: an element counts only when it is rendered and not
    /// inside an `aria-hidden` subtree.
    private static let visibilityHelper = """
        const isVisible = element => element && element.getClientRects().length > 0 && !element.closest('[aria-hidden="true"]');
        """

    /// Page-side helpers that find the first visible composer and read its
    /// text, whether it is a form control or a contenteditable editor.
    private var composerHelpers: String {
        """
        \(Self.visibilityHelper)
                  const composerSelectors = \(JavaScriptLiteral.array(composerSelectors));
                  const findComposer = () => composerSelectors
                    .flatMap(selector => Array.from(document.querySelectorAll(selector)))
                    .find(isVisible);
                  const composerText = composer => composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement
                    ? composer.value
                    : composer.innerText || composer.textContent || '';
        """
    }

    func readinessScript() -> String {
        """
        (() => {
          \(composerHelpers)
          return Boolean(findComposer());
        })()
        """
    }

    func loginRequiredScript() -> String {
        """
        (() => {
          \(Self.visibilityHelper)
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

    func fillScript(prompt: String) -> String {
        let encodedPrompt = JavaScriptLiteral.string(prompt)
        return """
        (() => {
          const prompt = \(encodedPrompt);
          \(composerHelpers)
          const composer = findComposer();
          if (!composer) return { ok: false, reason: 'composer-not-found' };
          if (composerText(composer).trim().length > 0) return { ok: false, reason: 'composer-not-empty' };

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

    func submissionScript(prompt: String) -> String {
        let encodedPrompt = JavaScriptLiteral.string(prompt)
        return """
        (() => {
          const normalize = text => text.replace(/\\s+/g, ' ').trim();
          const prompt = normalize(\(encodedPrompt));
          const sendButtonSelectors = \(JavaScriptLiteral.array(sendButtonSelectors));
          \(composerHelpers)
          const composer = findComposer();
          if (!composer || normalize(composerText(composer)) !== prompt) return { ok: false, reason: 'composer-missing-prompt' };
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

    /// The composer clearing after Send is the confirmation that the
    /// provider accepted the prompt.
    func submissionConfirmationScript() -> String {
        """
        (() => {
          \(composerHelpers)
          const composer = findComposer();
          return Boolean(composer) && composerText(composer).trim().length === 0;
        })()
        """
    }
}
