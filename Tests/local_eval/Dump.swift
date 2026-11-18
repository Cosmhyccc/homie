import Foundation
@main struct Dump { @MainActor static func main() throws {
  let raw = MusicController.tools + DesktopController.tools + TaskController.tools + MacControls.tools + [ScreenInk.tool, ScreenInk.pathTool, ScreenInk.clearTool, LocalTools.sizeTool]
  let tools = CommandLine.arguments.count > 2 ? LocalTools.localize(raw) : raw
  let data = try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
  try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
  print(tools.count, data.count)
}}
