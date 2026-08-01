import AppKit
import Foundation
import WebKit

/// Generates the small page-world shim that turns the standard browser
/// `window.print()` API into a request for Duet's native print panel.
enum PrintingScript {
    static let handlerName = "duetPrint"

    static func source(allowedHosts: [String]) -> String {
        """
        (() => {
          if (window.__duetPrintingBridgeInstalled) return;
          const bridge = window.webkit?.messageHandlers?.\(handlerName);
          if (!bridge) return;
          const allowedHosts = \(jsonArray(allowedHosts));
          const host = (location.hostname || "").toLowerCase();
          const isTopLevel = window === window.top;
          if (isTopLevel && !allowedHosts.some(domain => host === domain || host.endsWith("." + domain))) return;
          window.__duetPrintingBridgeInstalled = true;
          let requestInFlight = false;
          let fallbackTimer = null;
          const requestNativePrint = () => {
            if (fallbackTimer !== null) {
              clearTimeout(fallbackTimer);
              fallbackTimer = null;
            }
            if (requestInFlight) return;
            requestInFlight = true;
            bridge.postMessage(null).catch(() => {});
            setTimeout(() => { requestInFlight = false; }, 1000);
          };
          const scheduleNativeFallback = () => {
            if (fallbackTimer !== null) clearTimeout(fallbackTimer);
            fallbackTimer = setTimeout(() => {
              fallbackTimer = null;
              requestNativePrint();
            }, 750);
          };
          const preparePrintableRegion = element => {
            document.querySelectorAll("[data-duet-print-root],[data-duet-print-path]").forEach(node => {
              node.removeAttribute("data-duet-print-root");
              node.removeAttribute("data-duet-print-path");
            });

            let root = element.parentElement;
            while (root && root !== document.body) {
              const text = (root.textContent || "").toLowerCase();
              if (text.includes("ingredients") && text.includes("steps")) break;
              root = root.parentElement;
            }
            if (!root || root === document.body) {
              root = element.closest("article,section") || element.parentElement;
            }
            if (!root) return;

            root.setAttribute("data-duet-print-root", "true");
            for (let ancestor = root.parentElement; ancestor && ancestor !== document.body; ancestor = ancestor.parentElement) {
              ancestor.setAttribute("data-duet-print-path", "true");
            }

            if (!document.getElementById("duet-print-region-style")) {
              const style = document.createElement("style");
              style.id = "duet-print-region-style";
              style.textContent = `
                @media print {
                  body *:not([data-duet-print-path]):not([data-duet-print-root]):not([data-duet-print-root] *) {
                    display: none !important;
                  }
                  [data-duet-print-path]:not([data-duet-print-root]) {
                    display: contents !important;
                  }
                  [data-duet-print-root] {
                    display: block !important;
                    position: static !important;
                    width: auto !important;
                    max-width: none !important;
                    overflow: visible !important;
                  }
                }
              `;
              (document.head || document.documentElement).appendChild(style);
            }
          };
          window.print = requestNativePrint;

          // Some provider controls prepare their printable DOM through a
          // framework action that does not ultimately invoke window.print in
          // WKWebView. Let that action run, then provide the native fallback.
          document.addEventListener("click", event => {
            const element = event.target instanceof Element
              ? event.target.closest("button,[role='button']")
              : null;
            const label = (element?.getAttribute("aria-label") || element?.textContent || "")
              .trim()
              .toLowerCase();
            if (label === "print" || label.startsWith("print ")) {
              preparePrintableRegion(element);
              scheduleNativeFallback();
            }
          }, true);
        })();
        """
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
protocol WebPagePrintPresenting: AnyObject {
    func presentPrintPanel(for webView: WKWebView)
}

/// Receives provider print requests without retaining the browser controller
/// through WKUserContentController's message-handler ownership.
@MainActor
final class PrintingBridge: NSObject {
    private let service: ChatService
    private weak var presenter: WebPagePrintPresenting?

    init(service: ChatService, presenter: WebPagePrintPresenting) {
        self.service = service
        self.presenter = presenter
        super.init()
    }

    func install(in configuration: WKWebViewConfiguration) {
        let userContentController = configuration.userContentController
        userContentController.addUserScript(WKUserScript(
            source: PrintingScript.source(allowedHosts: service.webNotificationHosts),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: PrintingScript.handlerName
        )
    }
}

extension PrintingBridge: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        // Interactive provider content, including Claude recipe cards, can run
        // in a child frame. Trust the provider-owned top-level page rather than
        // the child frame's separate or opaque security origin.
        guard let webView = message.webView,
              service.allowsPromptInjection(at: webView.url) else { return (nil, nil) }

        presenter?.presentPrintPanel(for: webView)
        return (nil, nil)
    }
}
