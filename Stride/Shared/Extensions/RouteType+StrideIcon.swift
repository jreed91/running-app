import Foundation

// `RouteType` lives in the StrideCore package, which cannot see the app's icon set.
extension RouteType {
    var strideIcon: StrideIconName {
        switch self {
        case .loop:       return .run
        case .outAndBack: return .ruler
        }
    }
}
