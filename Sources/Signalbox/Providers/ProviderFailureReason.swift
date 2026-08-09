import Foundation

enum ProviderFailureReason {
    static func readFailure(_ error: Error, source: String) -> String {
        let cocoa = error as NSError
        // `FileHandle(forReadingFrom:)` reports a permission-denied open as
        // NSFileWriteNoPermissionError (513), not the read variant (257), with
        // POSIX EACCES only as an underlying error. Recognizing just 257 meant
        // an unreadable report was skipped as if it did not exist instead of
        // being escalated to unavailable evidence.
        let deniedCocoaCodes: Set<Int> = [NSFileReadNoPermissionError, NSFileWriteNoPermissionError]
        let deniedByCocoa = cocoa.domain == NSCocoaErrorDomain && deniedCocoaCodes.contains(cocoa.code)
        let deniedByPOSIX = isPermissionDeniedPOSIX(cocoa)
        let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError
        let deniedByUnderlying = underlying.map(isPermissionDeniedPOSIX) ?? false

        if deniedByCocoa || deniedByPOSIX || deniedByUnderlying {
            return "macOS denied permission to read \(source)."
        }
        return "\(source) could not be read (error \(cocoa.code))."
    }

    /// EPERM (1) and EACCES (13).
    private static func isPermissionDeniedPOSIX(_ error: NSError) -> Bool {
        error.domain == NSPOSIXErrorDomain && (error.code == 1 || error.code == 13)
    }
}
