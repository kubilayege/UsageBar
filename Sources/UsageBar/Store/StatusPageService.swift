import Foundation

enum StatusPageService {
    static func fetch(_ service: StatusService) async -> ServiceStatus? {
        guard let (data, resp) = try? await HTTP.request(service.url), resp.statusCode == 200,
              let json = try? HTTP.jsonObject(data), let status = json.dict("status") else { return nil }
        return ServiceStatus(service: service,
                             indicator: status.string("indicator") ?? "unknown",
                             description: status.string("description") ?? "Unknown")
    }

    static func fetchAll(_ services: [StatusService]) async -> [ServiceStatus] {
        await withTaskGroup(of: ServiceStatus?.self) { group in
            for s in services { group.addTask { await fetch(s) } }
            var out: [ServiceStatus] = []
            for await s in group { if let s { out.append(s) } }
            return out.sorted { $0.service.rawValue < $1.service.rawValue }
        }
    }
}
