/// One row of the commit graph, laid out the way VS Code's Source Control graph lays it out.
public struct GraphRow<Color> {
    /// A line on its way down to the commit it is for.
    public struct Line {
        public let target: String
        public let color: Color
    }

    /// Lines coming in from the row above, left to right.
    public let input: [Line]
    /// Lines going on to the row below, left to right, with no gaps.
    public let output: [Line]
    /// Where the commit's dot sits, as an index into `input`.
    public let dot: Int
    /// For each input line, the output line it goes on as, or nil where it ends in this row's commit.
    public let next: [Int?]
    /// The output line each parent's line starts as, in the commit's parent order.
    public let parents: [Int]
    /// The commit's color, the color of the line it sits on.
    public let color: Color
}

public enum CommitGraph {
    /// Lays out `commits`, children before parents, a row each. `color` gives a commit a color of its own,
    /// and `fresh` hands out the next color for a line that needs one.
    public static func rows<Color>(_ commits: [CommitSnapshot], color: (CommitSnapshot) -> Color?, fresh: () -> Color) -> [GraphRow<Color>] {
        []
    }
}
