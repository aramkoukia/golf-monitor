import SwiftUI

// MARK: - Metric guide

/// Plain-English explanations of every shot metric, in the same importance
/// order used on the Session and History screens: outcome and strike
/// quality first, fine detail last. Shared by both screens.
struct MetricGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let kind: String
        let text: String
    }

    private let entries: [Entry] = [
        Entry(name: "Carry", kind: "ESTIMATED",
              text: "How far the ball flies before it lands, not counting roll — the number most players judge a shot by. Estimated by a flight model, so the club you pick matters: the model assumes that club's typical spin."),
        Entry(name: "Ball Speed", kind: "MEASURED",
              text: "How fast the ball leaves the clubface — the biggest single factor in distance. Every extra 1 mph is worth roughly 2 yards of carry. Typical driver speed: 130–150 mph for amateurs, 165+ on tour."),
        Entry(name: "Club Speed", kind: "ESTIMATED",
              text: "How fast the clubhead is moving at impact — your raw power input. Read from the club's motion just before impact, so it's rougher than ball speed, and it shows — when the swing wasn't tracked cleanly. Typical driver: 85–95 mph amateur, 110+ tour."),
        Entry(name: "Smash Factor", kind: "DERIVED",
              text: "Ball speed ÷ club speed: how squarely you struck it. 1.50 is the practical max with a driver, about 1.35–1.40 with irons. Normal club speed but low smash means a mishit — heel, toe, thin or fat. Shows — when club speed is missing."),
        Entry(name: "Launch Angle", kind: "MEASURED",
              text: "The angle the ball takes off at, read from its first frames of flight. Pairs with spin to shape the shot: roughly 10–14° is the driver sweet spot, and irons launch higher."),
        Entry(name: "Offline", kind: "ROUGH GUIDE",
              text: "Estimated finish left or right of the target line at carry distance (+ = right). A side-on camera can't truly see left/right — this is inferred from the ball's path on screen, so it often reads ~0. The least reliable number in the app."),
        Entry(name: "Apex", kind: "ESTIMATED",
              text: "The highest point of the flight. Very high usually means ballooning or too much spin; very low means a runner that may not hold a green."),
        Entry(name: "Hang Time", kind: "ESTIMATED",
              text: "How long the ball stays in the air. Mostly a byproduct of launch angle and apex — a trajectory check, not a goal in itself."),
        Entry(name: "Tempo", kind: "ESTIMATED",
              text: "Backswing time ÷ downswing time, written as X : 1. Tour players cluster near 3 : 1, and a repeatable tempo makes a repeatable swing. Needs the whole swing tracked cleanly — it shows — when the swing can't be segmented."),
        Entry(name: "Spin", kind: "NOT MEASURABLE",
              text: "Backspin, in rpm. A phone camera would have to watch the dimples rotate thousands of times a second — it can't, so this is always n/a. The carry model uses your club's typical spin instead."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Text("Ball speed and launch angle are measured from the video. Carry, apex and hang time come from a flight model that assumes typical backspin for the club you picked — good to about ±10%, not radar-grade.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.name)
                                .font(.headline)
                            Spacer()
                            Text(entry.kind)
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("What the numbers mean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
