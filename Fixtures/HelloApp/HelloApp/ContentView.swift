import SwiftUI

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Hello from sochi")
                .font(.largeTitle.bold())
            Button("Tapped \(taps) times") { taps += 1 }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear { print("ContentView appeared") }
    }
}
