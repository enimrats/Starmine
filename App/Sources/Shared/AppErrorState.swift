import Foundation

struct AppErrorState: Identifiable, Equatable {
    let id = UUID()
    let message: String
}
