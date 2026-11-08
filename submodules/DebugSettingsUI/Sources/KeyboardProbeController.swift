import Foundation
import UIKit
import Display

/// Debug Settings ▸ "Keyboard probe (plain text view)": a stock `UITextView` with nothing customised, focused and
/// dismissed under the frame hitch log's timer. Compares the system keyboard's cost for a plain field with the chat's
/// editor (`keyboardFocusTap`) in the same app: when both build the keyboard layout on our main thread, the cause is
/// app-wide; when only the chat does, it is the editor's configuration. Needs "Frame hitches" on.
final class KeyboardProbeViewController: UIViewController {
    private let textView = UITextView()
    private let status = UILabel()
    private var round = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground

        self.status.numberOfLines = 0
        self.status.font = .preferredFont(forTextStyle: .footnote)
        self.status.text = FrameHitchMonitor.isEnabled ? "Tap Focus, then Dismiss, a few times. Then send logs." : "Turn on \"Frame hitches: log with main-thread stacks\" first."

        self.textView.font = .preferredFont(forTextStyle: .body)
        self.textView.layer.borderColor = UIColor.separator.cgColor
        self.textView.layer.borderWidth = 1.0
        self.textView.layer.cornerRadius = 8.0

        let focus = UIButton(type: .system)
        focus.setTitle("Focus", for: .normal)
        focus.addTarget(self, action: #selector(self.focusPressed), for: .touchUpInside)
        let dismiss = UIButton(type: .system)
        dismiss.setTitle("Dismiss", for: .normal)
        dismiss.addTarget(self, action: #selector(self.dismissPressed), for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [focus, dismiss, close])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [self.status, buttons, self.textView])
        stack.axis = .vertical
        stack.spacing = 12.0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 16.0),
            stack.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -16.0),
            stack.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 16.0),
            self.textView.heightAnchor.constraint(equalToConstant: 80.0)
        ])
    }

    @objc private func focusPressed() {
        self.round += 1
        FrameHitchMonitor.shared.measure("keyboardProbePlainFocus", alwaysLog: true) {
            _ = self.textView.becomeFirstResponder()
        }
        let round = self.round
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.round == round else {
                return
            }
            let state = FrameHitchMonitor.keyboardState?() ?? "unknown"
            FrameHitchMonitor.log?("Frame hitches: window=keyboardProbePlainShown kb=\(state)")
            self.status.text = "Round \(round): \(state)"
        }
    }

    @objc private func dismissPressed() {
        FrameHitchMonitor.shared.measure("keyboardProbePlainDismiss", alwaysLog: true) {
            _ = self.textView.resignFirstResponder()
        }
    }

    @objc private func closePressed() {
        self.textView.resignFirstResponder()
        self.dismiss(animated: true)
    }
}
