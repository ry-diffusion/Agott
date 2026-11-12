import SwiftUI

/// Long work going on right now (a video being fetched and transcribed), as
/// a small live card in the conversation: what it is doing, how far along,
/// how long so far, and a way to stop it.
struct LiveWorkCards: View {
    var compact = false
    @State private var work = LiveWork.shared

    var body: some View {
        if !work.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(work.jobs) { job in
                    LiveWorkCard(job: job, compact: compact)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
            }
            .animation(Motion.settle, value: work.jobs.map(\.id))
        }
    }
}

struct LiveWorkCard: View {
    var job: LiveWork.Job
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.symbol)
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(Ink.spot)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.title)
                        .font(.system(size: compact ? 14 : 15, weight: .semibold))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(timerInterval: job.started...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Ink.muted)
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(job.stage)
                        .font(.callout)
                        .foregroundStyle(Ink.muted)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    if let fraction = job.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Ink.muted)
                    }
                }
                Group {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .tint(Ink.spot)
                .animation(.easeOut(duration: 0.25), value: job.fraction)
            }
            if !compact {
                Button { Agent.shared.cancel() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(HoverIconStyle(size: 26))
                    .foregroundStyle(Ink.muted)
                    .help(Text("Stop"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: compact ? .infinity : 460, alignment: .leading)
        .quietSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(Motion.settle, value: job.stage)
    }
}
