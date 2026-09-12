// Sets a file's custom Finder icon.
//
//   swiftc -O -o seticon tools/seticon.swift
//   ./seticon AppIcon.icns AutoShutdown-1.0.dmg
//
// This is what gives the .dmg the app's icon in Finder instead of the generic
// disk image icon. There is no command line tool in macOS for it, only this API.

import Cocoa

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: seticon <icns> <target>\n".data(using: .utf8)!)
    exit(64)
}

guard let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("cannot read icon: \(args[1])\n".data(using: .utf8)!)
    exit(66)
}

exit(NSWorkspace.shared.setIcon(image, forFile: args[2], options: []) ? 0 : 1)
