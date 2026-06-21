import Foundation

/// Rejection reasons on the way into the spine. Named `ParseError` because the
/// later parser tracks (deterministic + Foundation Models) throw the same cases
/// when they produce a draft that cannot be trusted. The parser is generous;
/// the saver is strict — garbage never lands silently.
enum ParseError: Error, Equatable {
    case noSets
    case emptyExerciseName
    case badWeight
    case badReps
    case badRIR
}
