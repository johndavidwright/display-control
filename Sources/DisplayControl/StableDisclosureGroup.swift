import SwiftUI

/// A disclosure control whose layout changes immediately while its visual
/// elements animate. Keeping geometry out of the animation prevents a
/// content-sized `MenuBarExtra` window from falling out of step with SwiftUI.
struct StableDisclosureGroup<Label: View, Content: View>: View {
  @Binding private var isExpanded: Bool
  @State private var isContentPresented: Bool
  @State private var contentOpacity: Double
  @State private var pendingCollapse: Task<Void, Never>?

  private let label: Label
  private let content: Content
  private let animationDuration = 0.14

  init(
    isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content,
    @ViewBuilder label: () -> Label
  ) {
    _isExpanded = isExpanded
    _isContentPresented = State(initialValue: isExpanded.wrappedValue)
    _contentOpacity = State(initialValue: isExpanded.wrappedValue ? 1 : 0)
    self.content = content()
    self.label = label()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        toggle()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "chevron.right")
            .font(.caption2)
            .frame(width: 8)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.easeInOut(duration: animationDuration), value: isExpanded)
          label
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

      if isContentPresented {
        content
          .opacity(contentOpacity)
          .animation(.easeInOut(duration: animationDuration), value: contentOpacity)
          // Only the explicit opacity change should fade. Removing the view
          // must never add an implicit transition while the window shrinks.
          .transition(.identity)
          .allowsHitTesting(isExpanded)
          .accessibilityHidden(!isExpanded)
      }
    }
    .onAppear {
      settlePresentation()
    }
    .onDisappear {
      pendingCollapse?.cancel()
      pendingCollapse = nil
      settlePresentation()
    }
  }

  private func toggle() {
    pendingCollapse?.cancel()
    pendingCollapse = nil

    if isExpanded {
      collapse()
    } else {
      expand()
    }
  }

  private func expand() {
    if !isContentPresented {
      withoutAnimation {
        isContentPresented = true
        contentOpacity = 0
      }
    }

    isExpanded = true
    DispatchQueue.main.async {
      guard isExpanded else { return }
      contentOpacity = 1
    }
  }

  private func collapse() {
    isExpanded = false
    contentOpacity = 0

    pendingCollapse = Task {
      try? await Task.sleep(nanoseconds: UInt64(animationDuration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard !isExpanded else { return }
        withoutAnimation {
          isContentPresented = false
        }
        pendingCollapse = nil
      }
    }
  }

  private func withoutAnimation(_ update: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction, update)
  }

  /// Closing the menu during a fade cancels its task. Keep the stored layout
  /// consistent so reopening cannot leave an invisible expanded section.
  private func settlePresentation() {
    withoutAnimation {
      isContentPresented = isExpanded
      contentOpacity = isExpanded ? 1 : 0
    }
  }
}
