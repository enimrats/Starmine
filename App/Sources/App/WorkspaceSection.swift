import Foundation

enum WorkspaceSection: Hashable {
    case home
    case files
    case library(UUID)
    case player
}
