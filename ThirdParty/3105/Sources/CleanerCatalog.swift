import Foundation

struct CleanerResolvedApplication: Equatable {
    let bundleID: String
    let name: String
    let containerPath: String
    let version: String
}

struct CleanerCatalogRecord: Equatable {
    let application: CleanerResolvedApplication
    let containerPath: String
    let usage: LimitedCleanerUsage

    var bundleID: String { application.bundleID }
}

enum CleanerCatalog {
    static func scanNewApplications(
        _ applications: [CleanerResolvedApplication],
        scannedBundleIDs: inout Set<String>,
        shouldIncludeBundleID: (String) -> Bool,
        activateContainer: (CleanerResolvedApplication) -> String?,
        isValidContainerPath: (String) -> Bool,
        usageForContainer: (String) -> LimitedCleanerUsage?
    ) -> [CleanerCatalogRecord] {
        var records: [CleanerCatalogRecord] = []
        for application in applications {
            let bundleID = application.bundleID
            guard shouldIncludeBundleID(bundleID),
                  scannedBundleIDs.insert(bundleID).inserted,
                  let containerPath = activateContainer(application),
                  isValidContainerPath(containerPath),
                  let usage = usageForContainer(containerPath),
                  usage.totalBytes > 0 else {
                continue
            }
            records.append(
                CleanerCatalogRecord(
                    application: application,
                    containerPath: containerPath,
                    usage: usage
                )
            )
        }
        return records
    }
}
