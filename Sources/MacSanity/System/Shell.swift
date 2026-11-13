/// Shell quoting shared by every place that builds a /bin/sh command line.
enum Shell {
    /// Single-quote a string for /bin/sh: nothing inside is interpreted
    /// (`$`, backticks, backslashes, spaces are all literal).
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
