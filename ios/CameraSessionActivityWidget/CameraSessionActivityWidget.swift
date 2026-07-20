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
      VStack(alignment: .leading, spacing: 8) {
        Text(context.attributes.cameraName)
          .font(.headline)
        if context.state.isShowingDownloadProgress {
          Text("还剩 \(context.state.downloadRemainingCount) 张")
            .font(.title3)
            .fontWeight(.semibold)
          ProgressView(value: context.state.downloadProgressFraction)
            .progressViewStyle(.linear)
        } else {
          Text("\(context.state.galleryItemCount) 张可查看")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding()
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.cameraName)
            .font(.caption)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if context.state.isShowingDownloadProgress {
            Text("还剩 \(context.state.downloadRemainingCount) 张")
              .font(.caption)
          } else {
            Text("\(context.state.galleryItemCount) 张")
              .font(.caption)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          if context.state.isShowingDownloadProgress {
            VStack(alignment: .leading, spacing: 6) {
              Text("还剩 \(context.state.downloadRemainingCount) 张")
                .font(.caption2)
              ProgressView(value: context.state.downloadProgressFraction)
            }
          } else {
            Text("\(context.state.galleryItemCount) 张可查看")
              .font(.caption2)
          }
        }
      } compactLeading: {
        Image(systemName: context.state.isShowingDownloadProgress ? "arrow.down.circle.fill" : "camera")
      } compactTrailing: {
        if context.state.isShowingDownloadProgress {
          Text("\(context.state.downloadRemainingCount)")
        } else {
          Text("\(context.state.galleryItemCount)")
        }
      } minimal: {
        Image(systemName: context.state.isShowingDownloadProgress ? "arrow.down.circle.fill" : "camera")
      }
    }
  }
}
