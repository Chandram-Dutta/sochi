import SwiftUI

struct ContentView: View {
    var body: some View {
        Text(Formatter.greeting(for: "Classic \(classic_answer())"))
            .padding()
    }
}
