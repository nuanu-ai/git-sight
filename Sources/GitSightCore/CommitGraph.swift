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
        let byHash = Dictionary(commits.map { ($0.fullHash, $0) }) { first, _ in first }
        var lines: [GraphRow<Color>.Line] = []
        var rows: [GraphRow<Color>] = []
        for commit in commits {
            let input = lines
            // The dot sits on the first line that comes for it; a commit no line comes for starts right of every line.
            let dot = input.firstIndex { $0.target == commit.fullHash } ?? input.count
            let own = color(commit) ?? (dot < input.count ? input[dot].color : fresh())
            var output: [GraphRow<Color>.Line] = []
            var next: [Int?] = []
            var parents: [Int] = []
            func start(_ parent: String, _ color: Color) {
                parents.append(output.count)
                output.append(.init(target: parent, color: color))
            }
            for (index, line) in input.enumerated() {
                if line.target == commit.fullHash {
                    // Every line that comes for the commit ends here; the first parent goes on in the dot's place.
                    if index == dot, let first = commit.parents.first { start(first, own) }
                    next.append(nil)
                } else {
                    next.append(output.count)
                    output.append(line)
                }
            }
            if dot == input.count, let first = commit.parents.first { start(first, own) }
            // A merged branch's line starts right of every line, in its own color.
            for parent in commit.parents.dropFirst() {
                start(parent, byHash[parent].flatMap(color) ?? fresh())
            }
            rows.append(GraphRow(input: input, output: output, dot: dot, next: next, parents: parents, color: own))
            lines = output
        }
        return rows
    }
}
