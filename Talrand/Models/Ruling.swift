import Foundation
import SwiftData

@Model
class Ruling {
    var date: String
    var source: String
    var comment: String

    init(date: String, source: String, comment: String) {
        self.date = date
        self.source = source
        self.comment = comment
    }
}
