import Foundation

struct ProviderAdapter {
    /// The provider's own app hosts, which page scripts check before running.
    let pageHosts: [String]
    /// Duet still finds the composer by selector: there's no native way to
    /// learn which element is the provider's editor. Fill needs it to refuse a
    /// composer that already holds a draft, Send needs it to focus the
    /// composer before pressing Return, and confirmation needs it to see the
    /// composer clear. There's no Send button selector: Duet sends with a real
    /// Return keypress instead (`ProviderWebView.pressReturnKey()`).
    let composerSelectors: [String]
    /// The path component in front of a conversation ID, such as `c` in
    /// `/c/<id>`. A page that moves onto a conversation path after Return
    /// started a new conversation, which confirms the send without reading
    /// the page.
    let conversationPathComponent: String
    /// Elements present only while the provider is generating a response.
    let generationIndicatorSelectors: [String]
    /// The composer's own semantic container (`form` or `fieldset`). A Stop
    /// control counts as a generation indicator only inside this scope, so
    /// unrelated Stop buttons elsewhere on the page don't. Don't use styling
    /// classes or a fixed ancestor depth: both change with provider restyles.
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
                // No textarea: a cold load first shows a stand-in textarea
                // (#pending-home-input, outside any form) for about a second
                // before the real contenteditable editor mounts in the
                // composer's form. Waiting for the editor keeps Duet from
                // filling and pressing Return into the stand-in.
                // `#prompt-textarea` covers the editor's older markup, but
                // only as a contenteditable, never as a textarea.
                composerSelectors: [
                    "[contenteditable='true'][role='textbox']",
                    "#prompt-textarea[contenteditable='true']"
                ],
                // Conversations live at /c/<id>, including inside a GPT or
                // project (/g/<id>/c/<id>).
                conversationPathComponent: "c",
                // ChatGPT's Stop button has no test ID, only an aria-label, so
                // the scoped Stop-label check below is its only indicator.
                generationIndicatorSelectors: [],
                generationControlScopeSelector: "form",
                generationControlSelectors: ["button[aria-label^='Stop' i]"],
                fileDropInputSelector: nil,
                printableRegionMarkers: nil,
                detectsVerificationChallenge: false,
                retriesBlankInitialLoad: false
            )
        case .claude:
            ProviderAdapter(
                pageHosts: service.providerPageHosts,
                // No plain textarea: while a page loads, Claude shows a
                // stand-in textarea (#static-composer-input) that swallows
                // Return until its real contenteditable editor mounts and
                // takes over the text. Waiting for the editor keeps Duet from
                // pressing Return into the stand-in.
                composerSelectors: [
                    "div[contenteditable='true'][role='textbox']",
                    "[contenteditable='true'][data-placeholder]",
                    "div[contenteditable='true']"
                ],
                conversationPathComponent: "chat",
                generationIndicatorSelectors: [
                    "[data-is-streaming='true']",
                    "button[data-testid='chat-input-stop']"
                ],
                generationControlScopeSelector: "fieldset",
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
    ///
    /// The input lookup stays: the fix is to hand files to that exact input,
    /// and WebKit has no native way to name it. It uses Claude's test ID.
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

    /// Whether a main-frame response is Cloudflare's bot check. Cloudflare
    /// marks challenge responses with `cf-mitigated: challenge`, whatever the
    /// status code, so this needs no page lookup.
    func isVerificationChallengeResponse(_ response: URLResponse) -> Bool {
        guard detectsVerificationChallenge, let response = response as? HTTPURLResponse else { return false }
        let mitigation = response.value(forHTTPHeaderField: "cf-mitigated")?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return mitigation == "challenge"
    }

    /// Returns `true` when the loaded page is a bot-check interstitial rather
    /// than the provider's app, or `nil` when this provider has none. A page
    /// with a usable composer is the app, whatever its title or text says.
    ///
    /// The page check stays as a fallback to
    /// `isVerificationChallengeResponse(_:)` until the `cf-mitigated` header
    /// has been seen on a live challenge. Remove it after that.
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
    ///
    /// The page check stays: `didFinish` fires before the provider's
    /// client-side app renders, and nothing native reports what it rendered.
    /// It looks only for text and semantic elements, never provider markup.
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

    /// A visible composer means the provider's app is ready for a prompt.
    /// The lookup stays: no native event says a client-side editor mounted.
    func readinessScript() -> String {
        """
        (() => {
          \(composerHelpers)
          return Boolean(findComposer());
        })()
        """
    }

    /// Sign-in pages on their own hosts and paths are caught by URL
    /// (`ChatService.isAuthenticationPage`). This page check stays for the
    /// signed-out landing pages providers serve at their app URLs, which no
    /// URL or native signal tells apart. It reads links, buttons, and forms by
    /// destination and accessible label, not provider markup.
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
            // Use the native setter so framework-controlled fields see the
            // change, then report it the way typing would.
            const prototype = composer instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(composer, prompt);
            composer.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: prompt }));
            composer.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            // insertText goes through the editor's own input handling and
            // fires its input events. Only the fallback needs one sent by hand.
            document.execCommand('selectAll', false, null);
            const inserted = document.execCommand('insertText', false, prompt);
            if (!inserted || (composer.innerText || '').trim() !== prompt.trim()) {
              composer.textContent = prompt;
              composer.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: prompt }));
            }
          }
          return { ok: true };
        })()
        """
    }

    /// Readies the composer for Duet's Return keypress: it must still hold
    /// exactly the filled prompt, and it must have keyboard focus inside the
    /// page, or Return would land on whatever else is focused.
    func returnKeyTargetScript(prompt: String) -> String {
        let encodedPrompt = JavaScriptLiteral.string(prompt)
        return """
        (() => {
          const normalize = text => text.replace(/\\s+/g, ' ').trim();
          const prompt = normalize(\(encodedPrompt));
          \(composerHelpers)
          const composer = findComposer();
          if (!composer || normalize(composerText(composer)) !== prompt) return { ok: false, reason: 'composer-missing-prompt' };
          const hasFocus = () => composer === document.activeElement || composer.contains(document.activeElement);
          if (!hasFocus()) composer.focus();
          if (!hasFocus()) return { ok: false, reason: 'composer-not-focused' };
          return { ok: true };
        })()
        """
    }

    /// Whether the page moved from somewhere else onto a conversation, which
    /// is how a send in a new conversation shows up in the URL. A send in an
    /// existing conversation keeps its URL, so it confirms through the
    /// composer instead.
    func startedConversation(from previousURL: URL?, to currentURL: URL?) -> Bool {
        !isConversationPage(previousURL) && isConversationPage(currentURL)
    }

    func isConversationPage(_ url: URL?) -> Bool {
        guard let path = url?.path else { return false }
        let components = path.split(separator: "/")
        return components.indices.dropLast().contains { components[$0] == conversationPathComponent }
    }

    /// The composer clearing after Return is the confirmation that the
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

    /// Whether the composer still holds the prompt after Return. Providers
    /// clear the composer when they take a prompt, so a composer that still
    /// holds it means Return didn't send: the provider ignored it, or a
    /// provider setting makes Return add a new line instead. Whitespace is
    /// normalized, so a line Return added still counts as the prompt.
    func composerHoldsPromptScript(prompt: String) -> String {
        let encodedPrompt = JavaScriptLiteral.string(prompt)
        return """
        (() => {
          const normalize = text => text.replace(/\\s+/g, ' ').trim();
          \(composerHelpers)
          const composer = findComposer();
          return Boolean(composer) && normalize(composerText(composer)) === normalize(\(encodedPrompt));
        })()
        """
    }
}
