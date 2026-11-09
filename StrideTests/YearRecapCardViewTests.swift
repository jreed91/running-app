import Testing
@testable import Stride

/// The recap card's headline rolls up from zeros in the pager; these pin what it rolls from.
struct YearRecapCardViewTests {

    @Test("Digits become zeros and everything else stays")
    func zeroed() {
        #expect(YearRecapCardView.zeroed("1,204 km") == "0,000 km")
        #expect(YearRecapCardView.zeroed("+6%") == "+0%")
        #expect(YearRecapCardView.zeroed("2026") == "0000")
        #expect(YearRecapCardView.zeroed("March") == "March")
    }
}
