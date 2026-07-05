import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CameraSessionActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    CameraSessionActivityWidget()
  }
}

struct CameraSessionActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CameraSessionActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 4) {
        Text(context.attributes.cameraName)
          .font(.headline)
        Text(context.state.phase)
          .font(.subheadline)
        Text(context.state.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding()
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.cameraName)
            .font(.caption)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.isDownloading ? "Downloading" : "Connected")
            .font(.caption)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.detail)
            .font(.caption2)
        }
      } compactLeading: {
        Image(systemName: context.state.isDownloading ? "arrow.down.circle" : "camera")
      } compactTrailing: {
        Text("\(context.state.itemCount)")
      } minimal: {
        Image(systemName: "camera")
      }
    }
  }
}
