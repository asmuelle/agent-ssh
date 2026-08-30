import Foundation

/// The one way to turn an arbitrary value into a single POSIX shell word.
///
/// Wrapping in single quotes is the only escaping form that needs no
/// per-metacharacter knowledge: inside `'…'` the shell interprets
/// nothing, so `;`, `$(…)`, backticks, `|`, `*` and newlines are all
/// inert data. The single quote itself cannot appear, so it is closed,
/// escaped, and reopened — the classic `'\''`.
///
/// Escaping walks unicode scalars rather than characters, and that is the
/// whole point of this type existing. `String.replacingOccurrences` works
/// on grapheme clusters by canonical equivalence, so an apostrophe
/// followed by a combining mark is one cluster that does not equal `'` —
/// the quote is passed through unescaped, the quoted string ends early,
/// and the remainder of a remote-supplied value is executed as shell
/// code. Every hand-rolled copy of this function in the app had that
/// hole; they now all call here.
///
/// This makes a value one *word*. It does not make it a safe *argument*:
/// a value beginning with `-` is still read as an option by the command
/// receiving it, which quoting cannot prevent. Slot validation and a
/// literal `--` in the command are what handle that.
public enum ShellQuoting {
    public static func singleQuoted(_ value: String) -> String {
        var quoted = "'"
        quoted.unicodeScalars.reserveCapacity(value.unicodeScalars.count + 2)
        for scalar in value.unicodeScalars {
            if scalar == "'" {
                // Close, emit an escaped quote, reopen.
                quoted += "'\\''"
            } else {
                quoted.unicodeScalars.append(scalar)
            }
        }
        quoted += "'"
        return quoted
    }
}
