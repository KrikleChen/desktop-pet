import Foundation

enum PetInteractionMode: Equatable {
    case ordinary
    case mousePressed
    case dragging
    case action
    case objectionBurst
    case followUpPending
    case followUpChoosing
    case followUpBranch
    case casePanel
    case courtRecordPanel

    var isFollowUp: Bool {
        switch self {
        case .followUpPending, .followUpChoosing, .followUpBranch:
            return true
        default:
            return false
        }
    }
}

enum FollowUpBranch {
    case askAboutCase
    case presentBadge
}
