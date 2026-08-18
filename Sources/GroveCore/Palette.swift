/// Grove's colours, as the hex strings the whole app is drawn from.
///
/// Here rather than in the view layer so the contrast between them can be asserted. The
/// window's palette is as much a comfort feature as the terminal's background, and it
/// earned the same treatment the moment a tier that carried real text turned out to sit
/// under WCAG's 4.5:1 on the panels it was drawn on.
///
/// Gruvbox dark, measured off the reference rather than guessed at.
public enum Palette {
  // MARK: Grounds

  /// Behind the content.
  public static let background = "#282828"
  /// The sidebar, and any raised control: a button, a menu, a field.
  public static let surface = "#3A3736"
  /// A selected row.
  public static let selection = "#4B4441"
  /// The line between two rows. Separates without ruling.
  public static let divider = "#4A4745"

  // MARK: Text, brightest first

  public static let title = "#FBF1C7"
  public static let detail = "#C5B597"
  /// A value only there for reference: a path, a count, a shortcut's description.
  ///
  /// Lifted from #9A8E7A, which read 3.67:1 on the surface — under AA, while carrying the
  /// only explanation of what each shortcut does.
  public static let faint = "#B2A28C"

  // MARK: Meaning

  public static let warning = "#FABD2F"
  public static let danger = "#FB4934"
  public static let confirm = "#B8BB26"
  /// Something in progress.
  public static let info = "#83A598"
  /// A call to action: the update pill, the primary button in a sheet.
  public static let highlight = "#689D6A"

  /// The text tiers, brightest first.
  public static let textTiers = [title, detail, faint]

  /// Every colour text is drawn on, including the two panels that are a translucent
  /// surface over the background — which is what text actually sits on, and is dimmer
  /// than either of them.
  ///
  /// ``selection`` is not here. See ``tiersOnSelection``.
  public static var grounds: [String] {
    [
      background, surface,
      Contrast.blend(surface, over: background, alpha: 0.5) ?? background,
      Contrast.blend(surface, over: background, alpha: 0.55) ?? background,
    ]
  }

  /// The tiers a selected row may use.
  ///
  /// ``faint`` is not one of them: on ``selection`` it measures 3.8:1, under the 4.5:1 that
  /// body text needs. Lifting it far enough to pass would have taken it to within half a
  /// point of ``detail``, collapsing three tiers into two everywhere else — so instead a
  /// selected row promotes its dimmest text to ``detail``. That is the right way round
  /// anyway: the row you have chosen is the one you are reading.
  public static let tiersOnSelection = [title, detail]
}
