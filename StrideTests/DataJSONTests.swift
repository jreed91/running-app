import Foundation
import Testing
@testable import Stride

// MARK: - Data+JSON encode/decode tests

struct DataJSONTests {

    @Test("encoded round-trips a value")
    func encodeRoundTrip() throws {
        let values = [1, 2, 3]
        let data = try #require(Data.encoded(values))
        #expect(data.decode([Int].self) == values)
    }

    @Test("encoded(keeping:) preserves stored data when encoding fails")
    func encodeKeepingPreservesOnFailure() throws {
        // A NaN Double is rejected by JSONEncoder's default strategy, so encoding
        // fails. The setter helper must return the previously stored blob rather
        // than nil, so a single bad value can't silently wipe good data.
        let good = try #require(Data.encoded([1.0, 2.0, 3.0]))
        let result = Data.encoded([Double.nan], keeping: good)
        #expect(result == good)
        #expect(result?.decode([Double].self) == [1.0, 2.0, 3.0])
    }

    @Test("encoded(keeping:) writes the new value when encoding succeeds")
    func encodeKeepingWritesOnSuccess() throws {
        let old = try #require(Data.encoded([1.0]))
        let result = Data.encoded([9.0, 8.0], keeping: old)
        #expect(result?.decode([Double].self) == [9.0, 8.0])
    }

    @Test("encoded(keeping:) returns nil when encoding fails and there is no prior data")
    func encodeKeepingNilWhenNoPrior() {
        let result = Data.encoded([Double.nan], keeping: nil)
        #expect(result == nil)
    }
}
