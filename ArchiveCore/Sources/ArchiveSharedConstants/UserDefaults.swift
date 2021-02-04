//
//  UserDefaults.swift
//  PDFArchiver
//
//  Created by Julian Kahnert on 10.08.19.
//  Copyright © 2019 Julian Kahnert. All rights reserved.
//

import Foundation

extension UserDefaults: Log {

    public enum Names: String, CaseIterable {
        case tutorialShown = "tutorial-v1"
        case lastSelectedTabName
        case pdfQuality
        case firstDocumentScanAlertPresented
        case lastAppUsagePermitted
        case archiveURL
        case untaggedURL
        case archivePathType
    }

    public enum PDFQuality: Float, CaseIterable {
        case lossless = 1.0
        case good = 0.75
        case normal = 0.5
        case small = 0.25

        public static let defaultQualityIndex = 1  // e.g. "good"
    }

    public static var isInDemoMode: Bool {
        UserDefaults.standard.bool(forKey: "demoMode")
    }

    public static var tutorialShown: Bool {
        get {
            appGroup.bool(forKey: Names.tutorialShown.rawValue)
        }
        set {
            appGroup.set(newValue, forKey: Names.tutorialShown.rawValue)
        }
    }

    public static var firstDocumentScanAlertPresented: Bool {
        get {
            appGroup.bool(forKey: Names.firstDocumentScanAlertPresented.rawValue)
        }
        set {
            appGroup.set(newValue, forKey: Names.firstDocumentScanAlertPresented.rawValue)
        }
    }

    public static var lastAppUsagePermitted: Bool {
        get {
            appGroup.bool(forKey: Names.lastAppUsagePermitted.rawValue)
        }
        set {
            appGroup.set(newValue, forKey: Names.lastAppUsagePermitted.rawValue)
        }
    }

    public static var lastSelectedTab: Tab {
        get {
            guard let name = appGroup.string(forKey: Names.lastSelectedTabName.rawValue),
                let tab = Tab(rawValue: name) else { return .scan }
            return tab
        }
        set {
            appGroup.set(newValue.rawValue, forKey: Names.lastSelectedTabName.rawValue)
        }
    }

    public static var pdfQuality: PDFQuality {
        get {
            var value = appGroup.float(forKey: Names.pdfQuality.rawValue)

            // set default to 0.75
            if value == 0.0 {
                value = PDFQuality.allCases[PDFQuality.defaultQualityIndex].rawValue
            }

            guard let level = PDFQuality(rawValue: value) else { fatalError("Could not parse level from value \(value).") }
            return level
        }
        set {
            log.info("PDF Quality Changed.", metadata: ["quality": "\(newValue.rawValue)"])
            appGroup.set(newValue.rawValue, forKey: Names.pdfQuality.rawValue)
        }
    }

    public static var archiveURL: URL? {
        get {
            appGroup.object(forKey: Names.archiveURL.rawValue) as? URL
        }
        set {
            appGroup.set(newValue, forKey: Names.archiveURL.rawValue)
        }
    }

    public static var untaggedURL: URL? {
        get {
            appGroup.object(forKey: Names.untaggedURL.rawValue) as? URL
        }
        set {
            appGroup.set(newValue, forKey: Names.untaggedURL.rawValue)
        }
    }

    public func setObject<T: Encodable>(_ object: T?, forKey key: Names) throws {
        guard let object = object else {
            set(nil, forKey: key.rawValue)
            return
        }
        let data = try JSONEncoder().encode(object)
        set(data, forKey: key.rawValue)
    }

    public func getObject<T: Decodable>(forKey key: Names) throws -> T? {
        guard let data = object(forKey: key.rawValue) as? Data else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Migration

    public static var appGroup: UserDefaults {
        // swiftlint:disable:next force_unwrapping
        UserDefaults(suiteName: Constants.sharedContainerIdentifier)!
    }

    public static func runMigration() {
        let old = UserDefaults.standard
        let new = UserDefaults.appGroup

        for name in Names.allCases {
            if let value = old.object(forKey: name.rawValue) {
                // if an old value could be found, set it in the new UserDefaults
                new.set(value, forKey: name.rawValue)

                // remove the old value after the migration has been completed, so that this will only run one time
                old.set(nil, forKey: name.rawValue)
            }
        }
    }
}
