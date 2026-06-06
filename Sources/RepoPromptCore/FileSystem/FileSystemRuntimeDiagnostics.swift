import Foundation

package struct FileSystemDiagnosticContext: Sendable, Equatable {
    package let correlationID: UUID

    package init(correlationID: UUID = UUID()) {
        self.correlationID = correlationID
    }
}
