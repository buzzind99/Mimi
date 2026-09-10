import Foundation

/// Ordered-candidate outcome: the first hit leads the display result — its
/// `displayOrigin` names the candidate role that produced it (a join lead
/// carries `.join` so the UI can label the compound match); later
/// candidates whose entries add something new are retained as the "also:"
/// hits, longest match first (ties keep candidate order).
struct LookupOutcome: Equatable, Sendable {
    let display: LookupResult
    let displayOrigin: ExpansionOrigin
    let also: [LookupResult]
}
