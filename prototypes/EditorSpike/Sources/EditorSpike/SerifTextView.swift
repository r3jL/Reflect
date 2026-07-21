// The de-risk core: NSTextView wrapped for SwiftUI (DEC-02).
// Proves: text binding, serif typography with generous leading, accent caret,
// undo, and an onEdit signal the host uses for margin-fade + autosave.
import AppKit
import SwiftUI

struct SerifTextView: NSViewRepresentable {
    @Binding var text: String
    var onEdit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.accentNS
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.45
        paragraph.paragraphSpacing = 14
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.serif(22),
            .foregroundColor: Theme.inkNS,
            .paragraphStyle: paragraph,
        ]
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributes(
            attributes, range: NSRange(location: 0, length: (text as NSString).length))
        textView.defaultParagraphStyle = paragraph

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SerifTextView
        init(_ parent: SerifTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
        }
    }
}
