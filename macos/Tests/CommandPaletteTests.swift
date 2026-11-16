//
//  CommandPaletteTests.swift
//  GhosttyTests
//
//  Tests for command palette query filtering and match ranking.
//

import Testing
import SwiftUI
@testable import Ghostty

struct CommandPaletteFilterTests {
    private func option(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        leadingColor: Color? = nil,
        sortKey: ObjectIdentifier? = nil
    ) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            description: description,
            leadingColor: leadingColor,
            sortKey: sortKey
        ) {}
    }

    /// Title matches outrank subtitle matches, which outrank description
    /// matches. Options that don't match at all are dropped.
    @Test func textMatchTiers() {
        let byDescription = option(title: "Alpha", description: "make it fast")
        let bySubtitle = option(title: "Beta", subtitle: "fast scrolling")
        let byTitle = option(title: "Fast Redraw")
        let noMatch = option(title: "Quit")

        let results = [noMatch, byDescription, bySubtitle, byTitle]
            .filteredAndSorted(query: "fast")

        #expect(results == [byTitle, bySubtitle, byDescription])
    }

    /// Options with equal scores keep their original relative order.
    @Test func tiesPreserveOriginalOrder() {
        let first = option(title: "New Window")
        let second = option(title: "New Tab")

        #expect([first, second].filteredAndSorted(query: "new") == [first, second])
        #expect([second, first].filteredAndSorted(query: "new") == [second, first])
    }

    /// With search tiers, a match in an earlier tier (tab or window name)
    /// beats a match in a later one (path), whatever the input order.
    @Test func searchTiersRankNamesBeforePaths() {
        let inPath1 = CommandOption(title: "~/a/b/c", searchTiers: [["", ""], ["~/a/b/c", "~/a/b/c"]]) {}
        let inPath2 = CommandOption(title: "zsh", searchTiers: [["zsh", ""], ["zsh", "~/a/b/c"]]) {}
        let named = CommandOption(title: "b", searchTiers: [["b", ""], ["b", "~/a/b/c"]]) {}
        let inWindow = CommandOption(title: "zsh", searchTiers: [["zsh", "bee"], ["zsh", "~/x"]]) {}

        let results = [inPath1, inPath2, inWindow, named].filteredAndSorted(query: "b")
        #expect(results == [named, inWindow, inPath1, inPath2])
    }

    /// Within a tier: exact beats prefix beats any other match.
    @Test func searchTiersPreferExactThenPrefix() {
        let contains = CommandOption(title: "lab", searchTiers: [["lab"]]) {}
        let prefix = CommandOption(title: "build", searchTiers: [["build"]]) {}
        let exact = CommandOption(title: "B", searchTiers: [["B"]]) {}

        let results = [contains, prefix, exact].filteredAndSorted(query: "b")
        #expect(results == [exact, prefix, contains])
    }

    /// Equal titles use their sort keys independent of input order.
    @Test func equalTitlesUseSortKey() {
        let firstKey = NSObject()
        let secondKey = NSObject()
        let first = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(firstKey)
        )
        let second = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(secondKey)
        )

        let forward = sortedTerminalPaletteOptions([first, second])
        let reverse = sortedTerminalPaletteOptions([second, first])
        #expect(forward == reverse)
    }
}
