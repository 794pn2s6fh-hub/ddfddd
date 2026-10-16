//
//  KeypadManager.swift
//  Erosion
//
//  Created by lunginspector on 8/27/26.
//

import Combine
import Foundation
import UIKit
import ZIPFoundation

// i hate you, apple incorporated.
// with love, lunginspector. august 28th, 2026.
enum KeypadID: String, CaseIterable {
    case one, two, three, four, five, six, seven, eight, nine, star, zero, pound
    
    var fileNames: [String] {
        switch self {
        case .one: return getFileNames(forKey: "-1-")
        case .two: return getFileNames(forKey: "-2-A B C")
        case .three: return getFileNames(forKey: "-3-D E F")
        case .four: return getFileNames(forKey: "-4-G H I")
        case .five: return getFileNames(forKey: "-5-J K L")
        case .six: return getFileNames(forKey: "-6-M N O")
        case .seven: return getFileNames(forKey: "-7-P Q R S")
        case .eight: return getFileNames(forKey: "-8-T U V")
        case .nine: return getFileNames(forKey: "-9-W X Y Z")
        case .star: return getFileNames(forKey: "-*-")
        case .zero: return getFileNames(forKey: "-0-+")
        case .pound: return getFileNames(forKey: "-#-")
        }
    }
    
    private func getFileNames(forKey key: String) -> [String] {
        let files = ["--mask.png", "--white.png", "-hi-mask.png", "-hi-white.png", "--white-bold.png", "--mask-bold.png"]
        return files.map { kp.getFileRegCode() + key + $0 }
    }
    
    var dialerNumber: String {
        switch self {
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .star: return "*"
        case .zero: return "0"
        case .pound: return "#"
        }
    }

    var dialerLetters: String {
        switch self {
        case .one: return ""
        case .two: return "ABC"
        case .three: return "DEF"
        case .four: return "GHI"
        case .five: return "JKL"
        case .six: return "MNO"
        case .seven: return "PQRS"
        case .eight: return "TUV"
        case .nine: return "WXYZ"
        case .star, .zero, .pound: return ""
        }
    }

    func getAccentedFileName() -> String {
        let appearance = UIScreen.main.traitCollection.userInterfaceStyle
        switch appearance {
        case .light: return self.fileNames[0]
        case .dark: return self.fileNames[1]
        default: return self.fileNames[0]
        }
    }
}

enum KPSize: Int, CaseIterable {
    case defSize, small, medium, large, custom
    
    var float: CGFloat {
        switch self {
        case .small: return CGFloat(150)
        case .medium: return CGFloat(205)
        case .large: return CGFloat(225)
        default: return CGFloat(0)
        }
    }
    
    var label: String {
        switch self {
        case .defSize: return "Default"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .custom: return "Custom"
        }
    }
}

enum KPSizeLimits {
    static let min = CGFloat(50)
    static let max = CGFloat(2500)
}

struct KeypadItem: Identifiable, Equatable {
    let id = UUID()
    var kpID: KeypadID
    var imgData = Data()
    var ogImgData = Data()
}

let emptyKeypadArray = [
    KeypadItem(kpID: KeypadID.one), KeypadItem(kpID: KeypadID.two), KeypadItem(kpID: KeypadID.three), KeypadItem(kpID: KeypadID.four), KeypadItem(kpID: KeypadID.five), KeypadItem(kpID: KeypadID.six), KeypadItem(kpID: KeypadID.seven), KeypadItem(kpID: KeypadID.eight), KeypadItem(kpID: KeypadID.nine), KeypadItem(kpID: KeypadID.star), KeypadItem(kpID: KeypadID.zero), KeypadItem(kpID: KeypadID.pound)
]

enum KPMsg {
    static let resetWarn = "You'll lose both what you're currently editing and what you've already set inside of the Phone app."
    static let applyComp = "For changes to take effect, open the Phone app and change the appearance until your custom keys show up. You can also restart your device. Do NOT force kill the Phone app!"
}

let kp = KeypadManager()
final class KeypadManager: ObservableObject {
    static let shared = KeypadManager()
    
    @Published var mpKeypad = [KeypadItem]()
    
    private var mpContainerPath = {
        return UserDefaults.standard.value(forKey: "mpContainerPath") as? String ?? ""
    }
    
    init() {
        if mpKeypad.isEmpty {
            mpKeypad = emptyKeypadArray
        }
    }
    
    // fun...
    func getFileRegCode() -> String {
        // TEST: force the English asset prefix instead of the detected "other" prefix.
        // This lets us verify whether TelephonyUI-10 expects eng-* filenames.
        return "en"
    }
    
    func updateKeypadItem(forID id: KeypadID, withData data: Data, ogData: Data? = nil) {
        if let index = mpKeypad.firstIndex(where: { $0.kpID == id }) {
            mpKeypad[index].imgData = data
            if let data = ogData {
                mpKeypad[index].ogImgData = data
            }
        }
    }
    
    func applyKeypadItems() -> Bool {
        // iOS 27 Airlift mode: use the same direct TelephonyUI-10 write
        // mechanism as AirCard instead of relying on the MobilePhone
        // application container path.
        if isAirliftCompatibilityMode() {
            guard AirliftBridge.shared.hasPairing() else {
                print("(kp) Airlift pairing is unavailable")
                return false
            }

            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("ErosionTelephonyUI-10-\(UUID().uuidString)")

            do {
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

                for item in mpKeypad {
                    // Do not create zero-byte TelephonyUI assets for keys that
                    // the user has not customized. Leaving those files untouched
                    // lets the system keep its original digit/key artwork.
                    guard !item.imgData.isEmpty else { continue }
                    for fileName in item.kpID.fileNames {
                        try item.imgData.write(to: stage.appendingPathComponent(fileName))
                    }
                }

                let pairingPath = AirliftBridge.shared.pairingFilePath()
                let source = stage.path

                // The Phone dialer cache lives inside the MobilePhone app
                // container on iOS 27. Resolve that container through Airlift
                // instead of relying on a locally visible UUID/hash.
                var containerPtr: UnsafeMutablePointer<CChar>?
                var findError: UnsafeMutablePointer<CChar>?
                let findRC = pairingPath.withCString { p in
                    "com.apple.mobilephone".withCString { bundle in
                        al_find_app_container(
                            p, bundle, nil, nil,
                            &containerPtr, &findError
                        )
                    }
                }

                guard findRC == 0, let containerPtr else {
                    if let findError {
                        print("(kp) failed to find MobilePhone container: \(String(cString: findError))")
                        al_string_free(findError)
                    } else {
                        print("(kp) failed to find MobilePhone container (rc=\(findRC))")
                    }
                    try? FileManager.default.removeItem(at: stage)
                    return false
                }

                let container = String(cString: containerPtr)
                al_string_free(containerPtr)
                let target = URL(fileURLWithPath: container)
                    .appendingPathComponent("Library/Caches/TelephonyUI-10")
                    .path

                var error: UnsafeMutablePointer<CChar>?
                let rc = pairingPath.withCString { p in
                    source.withCString { s in
                        target.withCString { t in
                            al_exploit_write_dir(p, s, t, nil, nil, &error)
                        }
                    }
                }

                if let error {
                    print("(kp) Airlift TelephonyUI-10 write failed: \(String(cString: error))")
                    al_string_free(error)
                }

                try? FileManager.default.removeItem(at: stage)
                return rc == 0
            } catch {
                print("(kp) failed to stage Airlift dialer theme: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: stage)
                return false
            }
        }

        var failed = 0
        for item in mpKeypad {
            let files = item.kpID.fileNames
            for fileName in files {
                let finalURL = URL(fileURLWithPath: mpContainerPath()).appendingPathComponent("Library/Caches/TelephonyUI-10").appendingPathComponent(fileName)
                do {
                    try item.imgData.write(to: finalURL)
                } catch {
                    print("(kp) failed to write image data: \(error.localizedDescription)")
                    failed += 1
                }
            }
        }
        return failed == 0
    }
    
    func resetKeypadItems() -> Bool {
        do {
            let filesURL = URL(fileURLWithPath: mpContainerPath()).appendingPathComponent("Library/Caches/TelephonyUI-10")
            let files = try fm.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: [])
            for fileURL in files {
                try fm.removeItem(at: fileURL)
            }
            clearKeypads()
            return true
        } catch {
            print("(kp) failed to reset keypad items: \(error.localizedDescription)")
        }
        return false
    }
    
    func clearKeypads() {
        for keypad in mpKeypad {
            if let index = mpKeypad.firstIndex(where: { $0.id == keypad.id }) {
                mpKeypad[index].ogImgData = Data()
                mpKeypad[index].imgData = Data()
            }
        }
    }
    
    func resizeAndRet(withData data: Data, newSize: CGFloat = CGFloat(0), customSize: CGSize? = nil, shallCircle: Bool = false, isDefault: Bool = false) -> Data {
        if let image = UIImage(data: data) {
            var width = isDefault ? image.size.width : customSize?.width ?? newSize
            var height = isDefault ? image.size.height: customSize?.height ?? newSize
            width = min(max(width, KPSizeLimits.min), KPSizeLimits.max)
            height = min(max(height, KPSizeLimits.min), KPSizeLimits.max)
            let resized = image.resized(to: CGSize(width: width, height: height), shouldCircle: shallCircle)
            if let newData = resized.pngData() {
                return newData
            }
        }
        return data
    }
    
    func getCurrentKeypads(size: KPSize = KPSize.defSize, custW: Int = 0, custH: Int = 0, saveOgData: Bool = false) {
        do {
            let filesURL = URL(fileURLWithPath: mpContainerPath()).appendingPathComponent("Library/Caches/TelephonyUI-10")
            for kpId in KeypadID.allCases {
                let fileName = kpId.getAccentedFileName()
                let url = filesURL.appendingPathComponent(fileName)
                let data = try Data(contentsOf: url)
                let imgData = {
                    switch size {
                    case .defSize: return resizeAndRet(withData: data, isDefault: true)
                    case .custom: return resizeAndRet(withData: data, customSize: CGSize(width: custW, height: custH))
                    default: return resizeAndRet(withData: data, newSize: size.float)
                    }
                }()
                if saveOgData {
                    updateKeypadItem(forID: kpId, withData: imgData, ogData: imgData)
                } else {
                    updateKeypadItem(forID: kpId, withData: imgData)
                }
            }
        } catch {
            // keypads could've been reset so nothing to log here, logs are just gonna spit out nonsense
        }
    }
    
    func changeSizeOfKeypads(size: KPSize = KPSize.defSize, custW: Int = 0, custH: Int = 0) {
        for kpItem in mpKeypad {
            let data = kpItem.ogImgData
            let imgData = {
                switch size {
                case .defSize: return resizeAndRet(withData: data, isDefault: true)
                case .custom: return resizeAndRet(withData: data, customSize: CGSize(width: custW, height: custH))
                default: return resizeAndRet(withData: data, newSize: size.float)
                }
            }()
            updateKeypadItem(forID: kpItem.kpID, withData: imgData)
        }
    }
    
    func maskKeysIntoCircle(size: KPSize = KPSize.defSize, custW: Int = 0, custH: Int = 0) {
        for kpItem in mpKeypad {
            let data = kpItem.ogImgData
            let imgData = {
                switch size {
                case .defSize: return resizeAndRet(withData: data, shallCircle: true, isDefault: true)
                case .custom: return resizeAndRet(withData: data, customSize: CGSize(width: custW, height: custH), shallCircle: true)
                default: return resizeAndRet(withData: data, newSize: size.float, shallCircle: true)
                }
            }()
            updateKeypadItem(forID: kpItem.kpID, withData: imgData)
        }
    }
    
    // by far the most annoying piece of swift i've ever had to write. but, it works how it should, so i'm happy.
    // -lunginspector, 9/11/26
    func importTheme(fromURL fileURL: URL) -> Bool {
        do {
            // create a temp dir for extraction
            var filesURL = URL.temporaryDirectory.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "_\(UUID())_EROSIONTMP")
            try fm.createDirectory(at: filesURL, withIntermediateDirectories: true)
            try fm.unzipItem(at: fileURL, to: filesURL)
            let dirURLs = try fm.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            if dirURLs.count < 1 {
                throw "no files found inside of extracted folder!"
            } else if dirURLs.count == 1 {
                filesURL = filesURL.appendingPathComponent(dirURLs[0].lastPathComponent)
            } else {
                if let index = dirURLs.firstIndex(where: { $0.lastPathComponent == "TelephonyUI-8" || $0.lastPathComponent == "TelephonyUI-9" || $0.lastPathComponent == "TelephonyUI-10" }) {
                    filesURL = filesURL.appendingPathComponent(dirURLs[index].lastPathComponent)
                } else {
                    throw "no telephonyui folders found inside of extracted folder!"
                }
            }
            // once extracted check each file for a match with the right image
            var replaceCount = 0
            let fileURLs = try fm.contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for fileURL in fileURLs {
                let split = fileURL.lastPathComponent.split(separator: "-").map { String($0) }
                //print(split)
                let fileForAppr = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "white" : "mask"
                // for appearance - get appearance for key ("white"-dark, "mask"-light) and see if it matches the current appearance too
                let apprName = {
                    if split.indices.contains(3) {
                        let appearance = split[3].split(separator: ".")[0]
                        if appearance == fileForAppr {
                            return split[3]
                        }
                    }
                    if split.indices.contains(2) {
                        let appearance = split[2].split(separator: ".")[0]
                        if appearance == fileForAppr {
                            return split[2]
                        }
                    }
                    return ""
                }()
                //print(apprName)
                if split.indices.contains(1) {
                    // lookup for key
                    let keyNum = split[1]
                    //print("(kp) fileName: \(fileURL.lastPathComponent), keyNum: \(keyNum), appearance: \(appearance), fileForAppr: \(fileForAppr), apprName: \(apprName)")
                    // check if that's the appearance we actually want
                    if let id = KeypadID.allCases.first(where: { $0.fileNames.contains { $0.contains(keyNum) && $0.contains(apprName) }}) {
                        //print("(kp) found image! lookup: \(keyNum), fileName: \(fileURL.lastPathComponent)")
                        let data = try Data(contentsOf: fileURL)
                        updateKeypadItem(forID: id, withData: data, ogData: data)
                        replaceCount += 1
                    }
                }
            }
            if replaceCount < 1 {
                throw "the file was unzipped, but no keys were found?"
            }
            print("(kp) successfully imported theme! fileName: \(fileURL.lastPathComponent), imported keys: \(replaceCount)")
            return true
        } catch {
            print("(kp) failed to import theme: \(error.localizedDescription)")
        }
        return false
    }
}

extension UIImage {
    func resized(to size: CGSize, scale: CGFloat = 1.0, shouldCircle: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext

            if shouldCircle {
                ctx.addEllipse(in: CGRect(origin: .zero, size: size))
                ctx.clip()

                let fillScale = max(size.width / self.size.width, size.height / self.size.height)
                let drawSize = CGSize(width: self.size.width * fillScale, height: self.size.height * fillScale)
                let origin = CGPoint(
                    x: (size.width - drawSize.width) / 2,
                    y: (size.height - drawSize.height) / 2
                )
                draw(in: CGRect(origin: origin, size: drawSize))
            } else {
                draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
