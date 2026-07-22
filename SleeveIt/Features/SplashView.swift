import SwiftUI

/// Animated splash shown while the app finishes loading.
///
/// iOS's system launch screen can't animate — it's a static pre-render — so this
/// is a SwiftUI view layered over the app on launch and faded out once loading
/// settles. The animation echoes the app's core action: a scan line sweeping
/// over the icon, as if measuring a card.
struct SplashView: View {
    @State private var sweep = false
    @State private var pulse = false
    @State private var appear = false

    private let green = Color(red: 28 / 255, green: 100 / 255, blue: 50 / 255)
    private let deepGreen = Color(red: 16 / 255, green: 74 / 255, blue: 35 / 255)

    private let symbolSize: CGFloat = 132

    var body: some View {
        ZStack {
            // Green background with a soft glow behind the symbol.
            LinearGradient(colors: [green, deepGreen],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.16), .clear],
                           center: .center, startRadius: 8, endRadius: 320)

            VStack(spacing: 0) {
                Spacer()

                scannedSymbol
                    .scaleEffect(appear ? 1 : 0.9)
                    .opacity(appear ? 1 : 0)

                Text("SleeveIt")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 28)

                Text("Sleeve it, don't leave it.")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 6)

                scanningCaption
                    .padding(.top, 26)

                Spacer()

                Text("Developed by Oz Soffy")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 32)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appear = true }
            // Glide the scan line slowly down then back up over the icon
            // (autoreverses), rather than snapping back to the top each loop —
            // that snap is what read as a flicker.
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { sweep = true }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    // MARK: - Scanned symbol

    private var scannedSymbol: some View {
        ZStack {
            // The app icon, as the "card" being scanned.
            Image("SplashSymbol")
                .resizable()
                .scaledToFit()
                .frame(width: symbolSize, height: symbolSize)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                .overlay {
                    // A soft mint beam sweeping over the icon. Mint (not white)
                    // so it stays visible over the icon's white card as well as
                    // its green tile; a wider glow reads as a scanner beam.
                    // Travels 15px past the icon's top and bottom edges — no clip
                    // — so the sweep visibly covers a little more than the icon.
                    let beam = Color(red: 0.6, green: 1.0, blue: 0.78)
                    let travel = symbolSize / 2 + 15
                    LinearGradient(
                        colors: [.clear, beam.opacity(0.9), .clear],
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                        .blur(radius: 1.5)
                        .shadow(color: beam.opacity(0.9), radius: 8)
                        .offset(y: sweep ? travel : -travel)
                }

            // Pulsing corner brackets, echoing the measure viewfinder.
            ForEach(SplashCorner.allCases, id: \.self) { corner in
                SplashBracket(corner: corner)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: symbolSize + 34, height: symbolSize + 34)
                    .opacity(pulse ? 1 : 0.45)
            }
        }
    }

    private var scanningCaption: some View {
        HStack(spacing: 7) {
            Image(systemName: "viewfinder")
                .font(.system(size: 14, weight: .semibold))
            Text("Scanning your cards")
                .font(.system(size: 14, weight: .medium))
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 4, height: 4)
                        .opacity(pulse ? 1 : 0.25)
                        .animation(.easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.18), value: pulse)
                }
            }
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}

// MARK: - Corner brackets

private enum SplashCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

private struct SplashBracket: Shape {
    let corner: SplashCorner

    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 22
        var path = Path()
        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        case .topTrailing:
            path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        case .bottomTrailing:
            path.move(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        }
        return path
    }
}

// MARK: - App root

/// Wraps the app in the splash: the splash shows on launch and fades out once a
/// brief minimum time has passed (so the scanning animation is actually seen)
/// and the data layer has had a chance to settle underneath.
struct AppRoot: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            RootView()

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // The catalog seed on RootView runs underneath; this just keeps the
            // splash up long enough to read the branding and see the animation.
            // ~3.6s ≈ one full down-and-up sweep (1.8s each way), so the scanning
            // motion is seen before the splash fades.
            try? await Task.sleep(for: .seconds(3.6))
            withAnimation(.easeOut(duration: 0.55)) { showSplash = false }
        }
    }
}
