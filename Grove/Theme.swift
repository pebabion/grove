import GroveCore
import SwiftUI

/// Grove's colours and spacing.
///
/// Every value was measured off a screenshot rather than guessed at, and they are all in one
/// place so the whole app can be re-skinned by editing this file — including back to the
/// system palette, which is `NSColor`-backed and free.
///
/// The palette is Gruvbox dark: a warm dark grey rather than a neutral one, with cream text
/// instead of white. It is the same reasoning as the terminal's background — the harshness
/// is pure white text on near-black — applied to chrome instead of a text buffer.
///
/// It is a fixed dark palette, not one that follows the system. Half the window is a
/// terminal, which is dark whatever the rest of the desktop is doing, and a light sidebar
/// beside a dark terminal was never the look. `GroveApp` therefore pins the appearance so
/// scrollers, menus and sheets are drawn dark to match.
enum Theme {
  /// The content pane.
  static let background = Color(hex: Palette.background)

  /// The sidebar, and any raised control: a button, a menu, a field.
  static let surface = Color(hex: Palette.surface)

  /// A selected row.
  static let selection = Color(hex: Palette.selection)

  /// Titles and control labels.
  static let title = Color(hex: Palette.title)

  /// The sentence under a title.
  static let detail = Color(hex: Palette.detail)

  /// Dimmer still, for a value that is only there for reference.
  static let faint = Color(hex: Palette.faint)

  /// A switch that is on: green enough to read as on without being loud.
  static let accent = Color(red: 0.298, green: 0.353, blue: 0.333)

  /// The line between two rows. Barely there on purpose: it separates without ruling.
  static let divider = Color(hex: Palette.divider)

  static let warning = Color(hex: Palette.warning)
  static let danger = Color(hex: Palette.danger)
  static let confirm = Color(hex: Palette.confirm)
  /// Something in progress, and the accent for a control worth noticing.
  static let info = Color(hex: Palette.info)
  /// A call to action: the update pill, the primary button in a sheet.
  static let highlight = Color(hex: Palette.highlight)

  // MARK: - Metrics

  static let sidebarWidth: CGFloat = 208
  static let contentPadding: CGFloat = 24
  static let rowSpacing: CGFloat = 13
  /// How much room a control on the right of a row may take before the text gives way.
  static let controlWidth: CGFloat = 210
  static let corner: CGFloat = 6
}

// MARK: - Controls

/// A switch in the window's own colours.
///
/// A tinted `Toggle` was tried first: macOS draws its own blue-grey track and a white knob,
/// which is the one control that would still look like it came from somewhere else.
struct ThemedToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 10) {
        // Carried rather than dropped: a settings row hands this an empty label and puts
        // the words on the left itself, but a toggle anywhere else labels itself, and a
        // style that threw the label away made those rows blank.
        configuration.label
        Spacer(minLength: 0)
        switchBody(configuration)
      }
    }
    .buttonStyle(.plain)
  }

  private func switchBody(_ configuration: Configuration) -> some View {
    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
      Capsule()
        .fill(configuration.isOn ? Theme.accent : Theme.surface)
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        .frame(width: 34, height: 20)
      Circle()
        .fill(configuration.isOn ? Theme.title : Theme.faint)
        .frame(width: 14, height: 14)
        .padding(.horizontal, 3)
    }
    .animation(.easeOut(duration: 0.12), value: configuration.isOn)
  }
}

/// A button that reads as part of this window: raised surface, cream label.
struct ThemedButtonStyle: ButtonStyle {
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(Theme.title)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: Theme.corner)
          .fill(prominent ? Theme.accent : Theme.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.corner)
          .strokeBorder(Theme.divider, lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// A text field on the surface colour rather than the system's white-bordered well.
struct ThemedFieldStyle: TextFieldStyle {
  // swiftlint:disable:next identifier_name
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .font(.system(size: 12, design: .monospaced))
      .foregroundStyle(Theme.title)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.corner)
          .strokeBorder(Theme.divider, lineWidth: 1)
      )
  }
}

/// A pop-up menu drawn as a pill with a chevron, like the ones in the reference.
///
/// `Picker` with `.menu` draws its own chrome and cannot be told not to, which is why this
/// builds the control out of a `Menu` instead.
struct ThemedPicker<Value: Hashable>: View {
  let selection: Binding<Value>
  let options: [(value: Value, label: String)]

  var body: some View {
    Menu {
      ForEach(options, id: \.value) { option in
        Button(option.label) { selection.wrappedValue = option.value }
      }
    } label: {
      HStack(spacing: 6) {
        Text(label).lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 8, weight: .semibold))
      }
    }
    // The pill comes from the button style. Told to be borderless instead, the menu keeps
    // its own indicator and draws no background at all, which left the label floating.
    .menuStyle(.button)
    .buttonStyle(ThemedButtonStyle())
    .menuIndicator(.hidden)
    .fixedSize()
  }

  private var label: String {
    options.first { $0.value == selection.wrappedValue }?.label ?? ""
  }
}

/// A row of choices shown side by side, for a setting with three or fewer of them.
///
/// Worth the space when the options are the point — the three backgrounds are a spectrum,
/// and a menu hides two thirds of it behind a click.
struct ThemedSegments<Value: Hashable>: View {
  let selection: Binding<Value>
  let options: [(value: Value, label: String)]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.value) { option in
        let chosen = option.value == selection.wrappedValue
        Button {
          selection.wrappedValue = option.value
        } label: {
          Text(option.label)
            .font(.system(size: 12, weight: chosen ? .semibold : .regular))
            .foregroundStyle(chosen ? Theme.title : Theme.detail)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(chosen ? Theme.selection : .clear)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.corner)
        .strokeBorder(Theme.divider, lineWidth: 1)
    )
  }
}

// MARK: - Applying it

extension View {
  /// Puts a window in Grove's colours.
  ///
  /// The three-argument `foregroundStyle` is what makes this cheap: it sets the primary,
  /// secondary and tertiary styles for every descendant, so the ordinary
  /// `.foregroundStyle(.secondary)` already written throughout the app resolves to this
  /// palette instead of the system's. Without it, re-skinning would have meant editing
  /// every label in every view.
  func groveWindow() -> some View {
    background(Theme.background)
      .foregroundStyle(Theme.title, Theme.detail, Theme.faint)
      .tint(Theme.highlight)
  }

  /// A card: the background Grove groups things on.
  func grovePanel(radius: CGFloat = 8) -> some View {
    background(RoundedRectangle(cornerRadius: radius).fill(Theme.surface.opacity(0.5)))
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.divider, lineWidth: 1))
  }
}

extension Color {
  /// Reads one of ``Palette``'s `#RRGGBB` strings.
  ///
  /// A palette entry that cannot be read is a mistake in the palette, not something to
  /// paper over with a fallback colour that would be quietly wrong on screen.
  init(hex: String) {
    guard let colour = NSColor(hex: hex) else { preconditionFailure("bad colour \(hex)") }
    self.init(nsColor: colour)
  }
}
