import SwiftUI

/// The settings window's colours and spacing.
///
/// Every value was measured off a screenshot of Zed's settings rather than guessed at, and
/// they are all in one place so the whole window can be re-skinned by editing this file —
/// including back to the system palette, which is `NSColor`-backed and free.
///
/// The palette is Gruvbox dark: a warm dark grey rather than a neutral one, with cream text
/// instead of white. It is the same reasoning as the terminal's background — the harshness
/// in a settings window is pure white text on near-black — applied to chrome instead of a
/// text buffer.
enum SettingsTheme {
  /// The content pane. #282828.
  static let background = Color(red: 0.157, green: 0.157, blue: 0.157)

  /// The sidebar, and any raised control: a button, a menu, a field. #3A3736.
  static let surface = Color(red: 0.227, green: 0.216, blue: 0.212)

  /// The selected row in the sidebar. #4B4441.
  static let selection = Color(red: 0.294, green: 0.267, blue: 0.255)

  /// Titles and control labels. #FBF1C7.
  static let title = Color(red: 0.984, green: 0.945, blue: 0.780)

  /// The sentence under a title. #C5B597.
  static let detail = Color(red: 0.772, green: 0.710, blue: 0.592)

  /// Dimmer still, for a value that is only there for reference.
  static let faint = Color(red: 0.604, green: 0.557, blue: 0.478)

  /// A switch that is on. #4C5A55 — green enough to read as on without being loud.
  static let accent = Color(red: 0.298, green: 0.353, blue: 0.333)

  /// The line between two rows. Barely there on purpose: it separates without ruling.
  static let divider = Color(red: 0.290, green: 0.278, blue: 0.271)

  static let warning = Color(red: 0.984, green: 0.741, blue: 0.184)
  static let danger = Color(red: 0.984, green: 0.286, blue: 0.204)
  static let confirm = Color(red: 0.722, green: 0.733, blue: 0.149)

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
struct SettingsToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      ZStack(alignment: configuration.isOn ? .trailing : .leading) {
        Capsule()
          .fill(configuration.isOn ? SettingsTheme.accent : SettingsTheme.surface)
          .overlay(Capsule().strokeBorder(SettingsTheme.divider, lineWidth: 1))
          .frame(width: 34, height: 20)
        Circle()
          .fill(configuration.isOn ? SettingsTheme.title : SettingsTheme.faint)
          .frame(width: 14, height: 14)
          .padding(.horizontal, 3)
      }
      .animation(.easeOut(duration: 0.12), value: configuration.isOn)
    }
    .buttonStyle(.plain)
  }
}

/// A button that reads as part of this window: raised surface, cream label.
struct SettingsButtonStyle: ButtonStyle {
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(SettingsTheme.title)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: SettingsTheme.corner)
          .fill(prominent ? SettingsTheme.accent : SettingsTheme.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SettingsTheme.corner)
          .strokeBorder(SettingsTheme.divider, lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// A text field on the surface colour rather than the system's white-bordered well.
struct SettingsFieldStyle: TextFieldStyle {
  // swiftlint:disable:next identifier_name
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .font(.system(size: 12, design: .monospaced))
      .foregroundStyle(SettingsTheme.title)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: SettingsTheme.corner).fill(SettingsTheme.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SettingsTheme.corner)
          .strokeBorder(SettingsTheme.divider, lineWidth: 1)
      )
  }
}

/// A pop-up menu drawn as a pill with a chevron, like the ones in the reference.
///
/// `Picker` with `.menu` draws its own chrome and cannot be told not to, which is why this
/// builds the control out of a `Menu` instead.
struct SettingsPicker<Value: Hashable>: View {
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
    .buttonStyle(SettingsButtonStyle())
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
struct SettingsSegments<Value: Hashable>: View {
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
            .foregroundStyle(chosen ? SettingsTheme.title : SettingsTheme.detail)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(chosen ? SettingsTheme.selection : .clear)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: SettingsTheme.corner).fill(SettingsTheme.surface))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsTheme.corner)
        .strokeBorder(SettingsTheme.divider, lineWidth: 1)
    )
  }
}
