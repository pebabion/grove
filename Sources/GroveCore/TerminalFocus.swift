/// Whether the terminal should take the keyboard.
///
/// A pane with a shell in it is the thing someone is typing into, so when it comes on
/// screen it should be ready to type in. Before this, switching workspaces left the
/// keyboard wherever it was — the sidebar, usually — and the first thing anyone typed to
/// an agent went nowhere, which cost a click to notice and a click to fix.
///
/// Here rather than in the view so the reasons are written down and asserted. Every one of
/// them is a case where taking the keyboard would be wrong.
public enum TerminalFocus {
  /// - Parameters:
  ///   - hasSession: whether a shell is actually on screen. Without one there is nothing
  ///     to type into: the pane is either empty or explaining that the workspace is still
  ///     being built.
  ///   - filesShowing: whether the file browser is open. Its search field takes the
  ///     keyboard when it appears, and a terminal grabbing it back would make the file
  ///     search unusable — the two would fight over every keystroke.
  public static func shouldTakeKeyboard(hasSession: Bool, filesShowing: Bool) -> Bool {
    hasSession && !filesShowing
  }
}
