//
//  DeviceInfoHelpers.swift
//  Erosion
//
//  Created by lunginspector on 8/14/26.
//

import Foundation

import UIKit

// rave is the internal codename for ios 27
func raveSupported() -> Bool {
    let buildNum = buildNumber()
    if buildNum == "24A5355q" || buildNum == "24A5370h" || buildNum == "24A5380h" || buildNum == "24A5390f" || buildNum == "24A5380l" {
        return true
    }
    return false
}

let vrs = ProcessInfo.processInfo.operatingSystemVersion
func isSupported() -> Bool {
    if (vrs.majorVersion == 26 && vrs.minorVersion < 7) || raveSupported() {
        return true
    }
    return false
}


/// iOS 27 builds where the existing BedQuery wallpaper path is supported.
/// Other iOS 27 builds use the Airlift compatibility backend for wallpapers.
func isAirliftCompatibilityMode() -> Bool {
    return vrs.majorVersion == 27 && !raveSupported()
}

func wallpaperUsesBedQuery() -> Bool {
    return !isAirliftCompatibilityMode()
}

/// iOS 27 DB5+ gate used for Airlift-only UI features.
/// DB5 is the last of the known supported 27.x builds; newer builds are
/// represented by Airlift compatibility mode. Keeping this helper separate
/// makes the UI gate explicit instead of coupling it to a wallpaper tweak.
func isIOS27DB5OrLater() -> Bool {
    guard vrs.majorVersion == 27 else { return false }
    // 24A5380l is the fifth known iOS 27 developer-build marker used by
    // Erosion. Any build outside the known pre-DB5 set is treated as DB5+.
    let build = buildNumber()
    let preDB5 = ["24A5355q", "24A5370h", "24A5380h", "24A5390f"]
    return build == "24A5380l" || !preDB5.contains(build)
}

func airliftUIAccessRequired() -> Bool {
    return isIOS27DB5OrLater() && isAirliftCompatibilityMode()
}


func doubleSysVrs() -> Double {
    let pieces = [String(vrs.majorVersion), String(vrs.minorVersion)]
    let combined = pieces.joined(separator: ".")
    return Double(combined) ?? 0.0
}



// device info getters
func machineName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    return machineMirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
    }
}

func buildNumber() -> String {
    var versString = [CChar](repeating: 0, count: 16)
    var versStringLen = size_t(versString.count - 1)
    let res = sysctlbyname("kern.osversion", &versString, &versStringLen, nil, 0)
    if res == 0, let buildNum = String(validatingUTF8: versString) {
        return buildNum
    }
    return "Unknown"
}

func isPad() -> Bool {
    return UIDevice.current.userInterfaceIdiom == .pad
}
