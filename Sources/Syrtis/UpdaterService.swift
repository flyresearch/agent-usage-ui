import AppKit
import Observation
import ServiceManagement
import Sparkle

/// Sparkle auto-updates. Only armed when running from an assembled .app
/// bundle — the bare SwiftPM executable (dev runs, --selftest, CI) has no
/// Info.plist feed/key and Sparkle would refuse to start.
///
/// Besides the interactive check, a silent probe runs at launch and every
/// six hours; when it finds a newer version the popover footer grows a
/// one-click update button bound to `availableVersion`.
@MainActor
@Observable
final class UpdaterService: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterService()

    nonisolated static func independentFeedAllowed(identifier:String?,feed:String?,publicKey:String?) -> Bool {
        guard identifier==AgentUsageProduct.identifier,let feed,let url=URL(string:feed),url.scheme=="https",
              url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,(url.port==nil || url.port==443),
              ["github.com","raw.githubusercontent.com"].contains(url.host ?? ""),
              Array(url.pathComponents.dropFirst().prefix(2))==["flyresearch","agent-usage-ui"],
              let publicKey,Data(base64Encoded:publicKey)?.count==32 else {return false}
        return true
    }
    nonisolated static var isAvailable: Bool {
        guard Bundle.main.bundleURL.pathExtension=="app" else {return false}
        if !AgentUsageProduct.enabled {return true}
        return independentFeedAllowed(identifier:Bundle.main.bundleIdentifier,
            feed:Bundle.main.object(forInfoDictionaryKey:"SUFeedURL") as? String,
            publicKey:Bundle.main.object(forInfoDictionaryKey:"SUPublicEDKey") as? String)
    }

    /// Display version of an available update (nil = up to date / unknown).
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    private override init() {
        super.init()
        guard Self.isAvailable else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        probeTask = Task { [weak self] in
            // Let the updater session finish starting before the first probe
            // (a check fired straight from init gets swallowed), retry once
            // shortly after, then settle into a slow cadence.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                self?.controller?.updater.checkForUpdateInformation()
                try? await Task.sleep(for: .seconds(60))
                if self?.availableVersion != nil { break }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                self?.controller?.updater.checkForUpdateInformation()
            }
        }
    }

    /// The interactive Sparkle flow (update dialog with install button).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// Prerelease appcast items are tagged <sparkle:channel>beta</sparkle:channel>;
    /// only installs that opt in (Settings → "Receive beta updates") see them.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "tokenbar.updates.beta") ? ["beta"] : []
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }
}

/// Launch-at-login via SMAppService — also bundle-only (the bare executable
/// has no main-app service identity to register).
@MainActor
enum AutostartService {
    nonisolated static func supports(bundleURL:URL,identifier:String?) -> Bool {
        bundleURL.pathExtension == "app" && !(identifier ?? "").isEmpty
    }
    nonisolated static var isAvailable: Bool {supports(bundleURL:Bundle.main.bundleURL,identifier:Bundle.main.bundleIdentifier)}
    enum State:Sendable {case enabled,disabled,requiresApproval,unavailable}
    nonisolated static func readState() async -> State {
        guard isAvailable else {return .unavailable}
        return await Task.detached(priority:.utility) {
            switch SMAppService.mainApp.status {
            case .enabled:return State.enabled
            case .requiresApproval:return State.requiresApproval
            case .notRegistered:return State.disabled
            default:return State.unavailable
            }
        }.value
    }
    static func openSettings() {SMAppService.openSystemSettingsLoginItems()}
    static func diagnostic() -> [String:Any] {
        let bundle=Bundle.main
        let registered=bundle.bundleIdentifier.flatMap{NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0)}
        return ["service_status_code":SMAppService.mainApp.status.rawValue,
                "registered_application_found":registered != nil,
                "registered_application_matches":registered?.standardizedFileURL == bundle.bundleURL.standardizedFileURL]
    }

    nonisolated static func readEnabled() async -> Bool {
        await Task.detached(priority: .utility) {
            SMAppService.mainApp.status == .enabled
        }.value
    }

    enum Failure:String,Sendable {
        case invalidSignature,authorization,serviceMissing,serviceUnavailable,deniedByUser,alreadyRegistered,invalidService,system
        var message:String {
            switch self {
            case .invalidSignature:return "系统拒绝了应用签名，请重新安装有效签名的应用。"
            case .authorization:return "系统未授权修改登录项，请在系统设置中核对。"
            case .serviceMissing:return "系统未找到登录服务，请检查应用登记与安装状态。"
            case .serviceUnavailable:return "系统登录项服务当前不可用，请稍后重试。"
            case .deniedByUser:return "登录启动已被系统设置中的用户选择禁用。"
            case .alreadyRegistered:return "登录项已存在；开关显示系统当前状态。"
            case .invalidService:return "系统判定应用登录服务无效，请检查安装包。"
            case .system:return "系统未能更新登录项，请稍后重试或查看系统登录项设置。"
            }
        }
    }
    struct Mutation:Sendable {
        let accepted:Bool
        let failure:Failure?
        let code:Int?
    }
    static func classify(domain:String,code:Int) -> Failure {
        guard ["SMAppServiceErrorDomain",kSMErrorDomainFramework as String].contains(domain) else {return .system}
        switch code {
        case Int(kSMErrorInvalidSignature):return .invalidSignature
        case Int(kSMErrorAuthorizationFailure):return .authorization
        case Int(kSMErrorJobNotFound),Int(kSMErrorJobPlistNotFound):return .serviceMissing
        case Int(kSMErrorServiceUnavailable):return .serviceUnavailable
        case Int(kSMErrorLaunchDeniedByUser):return .deniedByUser
        case Int(kSMErrorAlreadyRegistered):return .alreadyRegistered
        case Int(kSMErrorToolNotValid),Int(kSMErrorInvalidPlist):return .invalidService
        default:return .system
        }
    }
    static func change(_ enabled:Bool) -> Mutation {
        guard isAvailable else {return Mutation(accepted:false,failure:.invalidService,code:nil)}
        do {
            if enabled {try SMAppService.mainApp.register()}
            else {try SMAppService.mainApp.unregister()}
            return Mutation(accepted:true,failure:nil,code:nil)
        } catch {
            let value=error as NSError
            return Mutation(accepted:false,failure:classify(domain:value.domain,code:value.code),code:value.code)
        }
    }
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {change(enabled).accepted}

    /// Explicit opt-in operational test. Never run automatically or alter a
    /// service that was already enabled or awaiting user approval.
    static func registrationRoundTrip() -> [String:Any] {
        let initial=SMAppService.mainApp.status
        guard isAvailable,initial == .notRegistered || initial == .notFound else {
            return ["test_ran":false,"reason":"preexisting_or_unavailable_service"]
        }
        let registration=change(true)
        let observed=SMAppService.mainApp.status
        var cleanup:Mutation?
        if registration.accepted || observed == .enabled || observed == .requiresApproval {cleanup=change(false)}
        let final=SMAppService.mainApp.status
        var result:[String:Any]=["test_ran":true,"initial_status":initial.rawValue,
            "registration_accepted":registration.accepted,"registered_status":observed.rawValue,
            "final_status":final.rawValue,"left_enabled":final == .enabled || final == .requiresApproval,
            "restoration_verified":final == .notRegistered]
        if let failure=registration.failure {result["registration_error"]=failure.rawValue}
        if let code=registration.code {result["registration_code"]=code}
        if let cleanup {result["cleanup_accepted"]=cleanup.accepted;if let failure=cleanup.failure {result["cleanup_error"]=failure.rawValue}}
        return result
    }
}
