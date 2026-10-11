import Foundation
import CryptoKit

enum ZCodeQuotaError: LocalizedError {
    case credentialsMissing
    case credentialsUndecryptable(String)
    case apiMessage(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "未找到 ZCode 登录凭据（~/.zcode/v2/credentials.json），请先登录 ZCode"
        case .credentialsUndecryptable(let reason):
            return "凭据解密失败：\(reason)"
        case .apiMessage(let message):
            return "额度接口返回：\(message)"
        case .badResponse:
            return "额度接口响应格式异常"
        }
    }
}

struct ZCodeLimit: Codable {
    let type: String
    let unit: Int?
    let number: Int?
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let percentage: Int?
    let nextResetTime: Double?
    let usageDetails: [UsageDetail]?

    struct UsageDetail: Codable {
        let modelCode: String?
        let usage: Int?
    }
}

struct ZCodeQuotaData: Codable {
    let limits: [ZCodeLimit]
    let level: String?
}

struct ZCodeQuotaResponse: Codable {
    let code: Int?
    let msg: String?
    let success: Bool?
    let data: ZCodeQuotaData?
}

struct ZCodeQuotaSnapshot {
    let fiveHour: LimitMeter?
    let weekly: LimitMeter?
    let usage: ZCodeUsageSummary
}

/// 直连 api.z.ai 额度接口的客户端：读取并解密本机 ZCode 登录凭据，
/// 拉取 coding plan 的窗口额度与 MCP 工具配额。
final class ZCodeQuotaClient {
    private let endpoint = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    func fetch(completion: @escaping (Result<ZCodeQuotaSnapshot, Error>) -> Void) {
        let token: String
        do {
            token = try Self.loadAccessToken()
        } catch {
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ZCode", forHTTPHeaderField: "User-Agent")

        urlSession.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let data,
                  let decoded = try? JSONDecoder().decode(ZCodeQuotaResponse.self, from: data) else {
                completion(.failure(ZCodeQuotaError.badResponse))
                return
            }

            guard decoded.success == true, decoded.code == 200, let quotaData = decoded.data else {
                completion(.failure(ZCodeQuotaError.apiMessage(decoded.msg ?? "未知错误")))
                return
            }

            completion(.success(Self.makeSnapshot(from: quotaData)))
        }.resume()
    }

    /// TOKENS_LIMIT 窗口按语义字段映射：unit=3 且 number=5 是 5 小时窗、unit=6 是周窗
    /// （实测接口字段）。语义字段缺失时回退为按重置时间排序（最先重置视为 5h 窗）——
    /// 该启发式在周窗临近重置、剩余时间短于 5h 窗时会认错窗口，语义映射可避免；
    /// TIME_LIMIT 是 MCP 工具的月度次数配额。
    static func makeSnapshot(from data: ZCodeQuotaData) -> ZCodeQuotaSnapshot {
        func meter(_ limit: ZCodeLimit, title: String, shortTitle: String) -> LimitMeter {
            LimitMeter(
                title: title,
                shortTitle: shortTitle,
                usedPercent: Double(limit.percentage ?? 0),
                resetDate: limit.nextResetTime.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }

        let tokensLimits = data.limits.filter { $0.type == "TOKENS_LIMIT" }

        var fiveHour = tokensLimits
            .first { $0.unit == 3 && ($0.number ?? 5) == 5 }
            .map { meter($0, title: "5 小时", shortTitle: "5h") }
        var weekly = tokensLimits
            .first { $0.unit == 6 }
            .map { meter($0, title: "周限额", shortTitle: "W") }

        if fiveHour == nil || weekly == nil {
            let sorted = tokensLimits.sorted { ($0.nextResetTime ?? 0) < ($1.nextResetTime ?? 0) }
            // 兜底不跨语义拿窗口：明确是周窗（unit=6）的不复制成 5h 行，反之亦然；
            // 单窗口与旧排序行为一致（视为周窗）
            if fiveHour == nil {
                fiveHour = sorted
                    .filter { $0.unit != 6 }
                    .first
                    .map { meter($0, title: "5 小时", shortTitle: "5h") }
            }
            if weekly == nil {
                let nonFiveHour = sorted.filter { !($0.unit == 3 && ($0.number ?? 5) == 5) }
                weekly = (nonFiveHour.count >= 2 ? nonFiveHour[1] : nonFiveHour.first)
                    .map { meter($0, title: "周限额", shortTitle: "W") }
            }
        }

        let mcp = data.limits.first { $0.type == "TIME_LIMIT" }
        let usage = ZCodeUsageSummary(mcpRemaining: mcp?.remaining, level: data.level)

        return ZCodeQuotaSnapshot(fiveHour: fiveHour, weekly: weekly, usage: usage)
    }

    // MARK: - 凭据

    static func loadAccessToken() throws -> String {
        // 优先读 config.json 的 provider 明文 apiKey（provider 配置面向用户、结构稳定，
        // 无解密依赖）；读不到再回退 credentials.json 的 enc:v1 解密链路
        if let apiKey = loadConfigAPIKey() {
            return apiKey
        }
        return try loadCredentialsToken()
    }

    /// config.json 中 Coding Plan 对应的 provider id
    private static let codingPlanProviderID = "builtin:bigmodel-coding-plan"

    private struct ZCodeConfigFile: Codable {
        struct Provider: Codable {
            struct Options: Codable {
                let apiKey: String?
            }
            let options: Options?
        }
        let provider: [String: Provider]?
    }

    private static func loadConfigAPIKey() -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/config.json")

        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ZCodeConfigFile.self, from: data),
              let apiKey = config.provider?[codingPlanProviderID]?.options?.apiKey,
              !apiKey.isEmpty else {
            return nil
        }
        return apiKey
    }

    private static func loadCredentialsToken() throws -> String {
        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/credentials.json")

        guard let data = try? Data(contentsOf: credentialsURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let blob = dict["oauth:bigmodel:access_token"] else {
            throw ZCodeQuotaError.credentialsMissing
        }

        return try decrypt(blob)
    }

    /// ZCode 凭据格式：enc:v1:<iv>.<tag>.<ciphertext>，三段 base64URL，
    /// AES-256-GCM，密钥 = SHA256(secret)；secret 取环境变量或本机信息 fallback。
    private static func decrypt(_ blob: String) throws -> String {
        guard blob.hasPrefix("enc:v1:") else { return blob }

        let segments = blob.split(separator: ".").map(String.init)
        guard segments.count == 3 else {
            throw ZCodeQuotaError.credentialsUndecryptable("密文分段数异常")
        }

        let iv = try base64URLDecode(String(segments[0].dropFirst("enc:v1:".count)))
        let tag = try base64URLDecode(segments[1])
        let ciphertext = try base64URLDecode(segments[2])

        let secret = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
            ?? "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(NSUserName())"
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))

        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv),
                ciphertext: ciphertext,
                tag: tag
            )
            let plain = try AES.GCM.open(sealed, using: key)
            guard let token = String(data: plain, encoding: .utf8), !token.isEmpty else {
                throw ZCodeQuotaError.credentialsUndecryptable("明文为空")
            }
            return token
        } catch let error as ZCodeQuotaError {
            throw error
        } catch {
            throw ZCodeQuotaError.credentialsUndecryptable(error.localizedDescription)
        }
    }

    private static func base64URLDecode(_ input: String) throws -> Data {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let data = Data(base64Encoded: base64) else {
            throw ZCodeQuotaError.credentialsUndecryptable("base64URL 解码失败")
        }
        return data
    }
}
