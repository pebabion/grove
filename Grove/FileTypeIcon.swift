import GroveCore
import SwiftUI

/// The symbol shown beside a file, in its language's colour.
struct FileTypeIcon: View {
  let path: String
  var size: CGFloat = 12

  private var icon: FileIcon { FileIcon.named(for: path) }

  var body: some View {
    Image(systemName: icon.symbol)
      .font(.system(size: size))
      // Secondary rather than a made-up colour when the language is unknown: a wrong
      // colour claims a file is something it is not.
      .foregroundStyle(icon.colour.map { Color(nsColor: TerminalPalette.color($0)) } ?? .secondary)
      .frame(width: size + 4, alignment: .center)
  }
}
