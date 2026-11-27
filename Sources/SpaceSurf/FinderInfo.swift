import Foundation

@MainActor
enum FinderInfo {
    private static let script = NSAppleScript(source: """
        on showItemInfo(itemPaths)
            repeat with itemPath in itemPaths
                set targetItem to (POSIX file (contents of itemPath)) as alias
                tell application "/System/Library/CoreServices/Finder.app"
                    open (information window of targetItem)
                end tell
            end repeat
            tell application "/System/Library/CoreServices/Finder.app" to activate
        end showItemInfo
        """)

    static func show(_ urls: [URL]) -> String? {
        let paths = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() {
            paths.insert(NSAppleEventDescriptor(string: url.path(percentEncoded: false)), at: index + 1)
        }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(paths, at: 1)
        // The ascr/psbr subroutine event passes filenames to the handler as data.
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272,
                                           targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: "showiteminfo"), forKeyword: 0x736E616D)
        event.setParam(arguments, forKeyword: 0x2D2D2D2D)

        guard let script else { return "Finder’s Get Info command is unavailable." }
        var error: NSDictionary?
        _ = script.executeAppleEvent(event, error: &error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743 {
            return "Space Surfer needs permission to open Info windows in Finder. You can also use Show in Finder and press ⌘I."
        }
        return error[NSAppleScript.errorMessage] as? String ?? "Finder’s Get Info command failed."
    }
}
