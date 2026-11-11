import AppKit
import Foundation
import WebKit

/// Generates the small page-world shim that turns the standard browser
/// `window.print()` API into a request for Duet's native print panel.
enum PrintingScript {
    static let handlerName = "duetPrint"

    /// - Parameter printableRegionMarkers: the adapter's markers for Print
    ///   buttons that never call `window.print()`. With markers, clicking such
    ///   a button prints only the card around it whose text contains every
    ///   marker; with `nil`, only `window.print()` is bridged.
    static func source(allowedHosts: [String], printableRegionMarkers: [String]?) -> String {
        """
        (() => {
          if (window.__duetPrintingBridgeInstalled) return;
          const bridge = window.webkit?.messageHandlers?.\(handlerName);
          if (!bridge) return;
          // Child frames are allowed through so in-page cards can print; the
          // native handler still requires a provider page at the top level.
          if (window === window.top && !\(PageOriginScript.isAllowedHost(allowedHosts))) return;
          window.__duetPrintingBridgeInstalled = true;
          let requestInFlight = false;
          const requestNativePrint = () => {
            if (requestInFlight) return;
            requestInFlight = true;
            bridge.postMessage(null).catch(() => {});
            // Coalesce a button's own window.print() with Duet's fallback.
            setTimeout(() => { requestInFlight = false; }, 1000);
          };
          window.print = requestNativePrint;
          \(printableRegionMarkers.map(printControlFallback) ?? "")
        })();
        """
    }

    /// Some provider Print buttons prepare their printable DOM through a
    /// framework action that never reaches `window.print()` in WKWebView. Let
    /// that action run, then mark the card around the button as the only
    /// printed region and request native printing.
    private static func printControlFallback(markers: [String]) -> String {
        """
        const regionMarkers = \(JavaScriptLiteral.array(markers.map { $0.lowercased() }));
        let fallbackTimer = null;
        const markPrintableRegion = element => {
          document.querySelectorAll("[data-duet-print-root],[data-duet-print-path]").forEach(node => {
            node.removeAttribute("data-duet-print-root");
            node.removeAttribute("data-duet-print-path");
          });

          let root = element.parentElement;
          while (root && root !== document.body) {
            const text = (root.textContent || "").toLowerCase();
            if (regionMarkers.every(marker => text.includes(marker))) break;
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
        const nativePrint = window.print;
        window.print = () => {
          if (fallbackTimer !== null) {
            clearTimeout(fallbackTimer);
            fallbackTimer = null;
          }
          nativePrint();
        };
        document.addEventListener("click", event => {
          const element = event.target instanceof Element
            ? event.target.closest("button,[role='button']")
            : null;
          const label = (element?.getAttribute("aria-label") || element?.textContent || "")
            .trim()
            .toLowerCase();
          if (label !== "print" && !label.startsWith("print ")) return;
          markPrintableRegion(element);
          if (fallbackTimer !== null) clearTimeout(fallbackTimer);
          // Give the button's own action time to call window.print() first.
          fallbackTimer = setTimeout(() => {
            fallbackTimer = null;
            nativePrint();
          }, 750);
        }, true);
        """
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
            source: PrintingScript.source(
                allowedHosts: service.providerPageHosts,
                printableRegionMarkers: ProviderAdapter.adapter(for: service).printableRegionMarkers
            ),
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
