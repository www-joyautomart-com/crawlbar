import Foundation

extension CrawlStatusMapper {
    func weicrawlStatus(_ object: [String: Any], result: CrawlCommandResult, staleAfterSeconds: Int?) -> CrawlAppStatus {
        if let control = self.firstObject(["control"], in: object), self.isCrawlKitStatus(control) {
            return self.genericStatus(control, result: result, staleAfterSeconds: staleAfterSeconds)
        }
        return self.genericStatus(object, result: result, staleAfterSeconds: staleAfterSeconds)
    }
}
