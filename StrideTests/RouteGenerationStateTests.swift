import Testing
@testable import Stride

// MARK: - RouteGenerationState tests
//
// Route Genius's request lifecycle, with Strings standing in for `GeneratedRoute`.

struct RouteGenerationStateTests {

    private typealias State = RouteGenerationState<String>

    @Test("Idle shows nothing")
    func idle() {
        let state = State.idle
        #expect(!state.isGenerating)
        #expect(state.routes.isEmpty)
        #expect(state.selectedRoute == nil)
        #expect(state.errorMessage == nil)
    }

    @Test("Generating clears the last options and the last error")
    func beginClears() {
        var withOptions = State.options(["a", "b"], selected: 1)
        withOptions.begin()
        #expect(withOptions.isGenerating)
        #expect(withOptions.routes.isEmpty)
        #expect(withOptions.selectedIndex == nil)

        var withError = State.failed("No route")
        withError.begin()
        #expect(withError.errorMessage == nil)
    }

    @Test("Success picks the first option so the map shows at once")
    func succeedSelectsFirst() {
        var state = State.idle
        state.begin()
        state.succeed(["a", "b", "c"])
        #expect(!state.isGenerating)
        #expect(state.routes == ["a", "b", "c"])
        #expect(state.selectedIndex == 0)
        #expect(state.selectedRoute == "a")
    }

    @Test("An empty result shows nothing and no error, as before")
    func emptyResult() {
        var state = State.idle
        state.begin()
        state.succeed([])
        #expect(state.routes.isEmpty)
        #expect(state.selectedRoute == nil)
        #expect(state.errorMessage == nil)
    }

    @Test("Failure shows the message and no options")
    func failure() {
        var state = State.idle
        state.begin()
        state.fail("Directions are unavailable")
        #expect(state.errorMessage == "Directions are unavailable")
        #expect(state.routes.isEmpty)
        #expect(!state.isGenerating)
    }

    @Test("Selecting moves the map; an index out of range is ignored")
    func select() {
        var state = State.options(["a", "b"], selected: 0)
        state.select(1)
        #expect(state.selectedRoute == "b")
        state.select(5)
        #expect(state.selectedIndex == 1)
        state.select(nil)
        #expect(state.selectedRoute == nil)
    }

    @Test("Selecting with no options showing does nothing")
    func selectWithoutOptions() {
        var state = State.generating
        state.select(0)
        #expect(state.isGenerating)
    }
}
