import SwiftUI
import UIKit

@main
struct ThreeOneOSSixApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @StateObject private var migrationTaskCenter = MigrationTaskCenter()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @State private var configImportError: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var auth = KeyAuthManager.shared

    init() {
        // Seed the UI language before the first view body runs. `@AppStorage`
        // reads UserDefaults on every access, so a write here is visible to
        // the first render. A stored value always wins — see seedIfNeeded.
        LanguageResolver.seedIfNeeded()
        setupLogCapture()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let cpu = DeviceCPU.cpuFamily.map { String(format: "0x%X", $0) } ?? "unknown"
        log("app: 3106 \(appVersion) (\(appBuild)) launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName) cpu=\(cpu)")
        SandboxAccess.prepare()
        TempSpaceRegistry.purgeExpired()
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func importConfigPackage(at url: URL) {
        do {
            _ = try MigrationConfigBackupService.importPackage(at: url)
            migrationTaskCenter.refreshStoredSets()
            configImportError = nil
            log("migration: config package imported — \(url.lastPathComponent)")
        } catch {
            log("migration: config package import failed — \(error)")
            configImportError = language.errorText(error)
        }
    }

    /// GestaltX #133: a share extension may drop packages into the App Group
    /// inbox without delivering an onOpenURL callback. Read whichever App
    /// Group the side-loaded build was actually signed with.
    private func importSharedConfigPackages() {
        guard let group = SandboxAccess.appGroup,
              let inbox = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: group)?
                .appendingPathComponent("SharedConfigInbox", isDirectory: true) else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension.lowercased()
            == MigrationConfigBackupService.packageExtension {
            importConfigPackage(at: url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    /// Foreground-switch variant: 30-minute throttle lives in the checker
    /// (persisted), so repeated quick app switches cost nothing.
    private func checkForUpdateThrottled() {
        Task {
            guard let offer = await AppUpdateChecker.throttledForegroundCheck() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup { 
            ZStack {
                            if !auth.estaLogado {
                TelaLoginView()
                    .zIndex(999)
            }

                ContentView()
                .tint(.purple)
.accentColor(.purple)
                    .environmentObject(appState)
                    .environmentObject(patchDraftCoordinator)
                    .environmentObject(fileOperationCoordinator)
                    .environmentObject(patchStore)
                    .environmentObject(repositoryStore)
                    .environmentObject(migrationTaskCenter)
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .opacity(showOnboarding ? 0 : 1)
                    .allowsHitTesting(!showOnboarding)

                if showOnboarding {
                    OnboardingView {
                        OnboardingStore.markCompleted()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            showOnboarding = false
                        }
                        appState.detectSupport()
                        checkForUpdate()
                    }
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
                    .zIndex(1)
                }
            }
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .alert(
                language.text("config.import_error.title"),
                isPresented: .init(
                    get: { configImportError != nil },
                    set: { if !$0 { configImportError = nil } }
                )
            ) {
                Button(language.text("common.ok"), role: .cancel) {
                    configImportError = nil
                }
            } message: {
                Text(configImportError ?? "")
            }
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version) + "\n" + language.text("update.current", AppInfo.appVersion)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        // Straight to the IPA when the manifest pins one;
                        // the release page is the fallback.
                        UIApplication.shared.open(offer.downloadURL ?? offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("common.cancel"))) {}
                )
            }
            .onAppear {
                if !showOnboarding {
                    appState.detectSupport()
                    checkForUpdate()
                }
                migrationTaskCenter.refreshPendingResumes()
                importSharedConfigPackages()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !showOnboarding else { return }
                appState.detectSupport()
                // 3.2.4: also probe for updates on foreground switches —
                // the cold-start check alone misses releases published
                // while the app idles in the background. Throttled to one
                // probe per 30 minutes; failures stay silent here.
                checkForUpdateThrottled()
            }
            .onOpenURL { url in
                // Config backup packages (.3106cfg) route to the migration
                // importer; everything else stays on the patch-package path.
                if url.isFileURL,
                   url.pathExtension.lowercased() == MigrationConfigBackupService.packageExtension {
                    importConfigPackage(at: url)
                    return
                }
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?

    /// Same storage key as the `@AppStorage` in `ThreeOneOSSixApp`. AppState
    /// is a plain class, so it cannot read the struct's property directly —
    /// it resolves the language from the shared defaults instead.
    private var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "")
            ?? .english
    }
    @Published var kernelExploitRunning = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild,
            isA10: DeviceCPU.isA10
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild,
            isA10: DeviceCPU.isA10
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        if !supported {
            // The explanation lives in RejectionReason so onboarding can show
            // the identical copy without a second hand-maintained copy drifting
            // the moment a version boundary moves.
            if let reason = RejectionReason.make(
                major: v.major,
                minor: v.minor,
                patch: v.patch,
                build: AppInfo.osBuild,
                osVersion: "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))",
                isA10: DeviceCPU.isA10
            ) {
                unsupportedMessage = language.text(reason.key, reason.arguments)
            }
        }
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild,
            isA10: DeviceCPU.isA10
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        autoRunKernelExploitIfNeeded()
    }

    /// 3.2.6 ran the chain at launch; 3.2.7 moved it behind a banner whose
    /// NavigationLink could not navigate, so many users never ran it at all
    /// (the 3.2.8-34 beta log contains no `app: running …` line). Auto-run is
    /// back for the kernel backend only: once per launch, never after a
    /// settled failure (a tap on the banner still retries).
    private var autoRunAttempted = false

    private func autoRunKernelExploitIfNeeded() {
        guard SandboxAccess.backend == .kernel,
              !autoRunAttempted,
              !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    /// True when the app should offer the Unlock screen: a kernel backend that
    /// has not succeeded yet. Deliberately excludes a settled failure — retrying
    /// automatically after a failure would recreate the silent loop this change
    /// removed. The user re-opens Unlock explicitly to try again.
    var needsUnlock: Bool {
        ExploitSupportPolicy.requiresExplicitUnlock(
            isKernelBackend: SandboxAccess.backend == .kernel,
            hasAccess: exploitStatus.isSuccess
        )
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: SandboxAccess.backend.displayName)
                    log("app: existing \(SandboxAccess.backend.displayName) access is still active")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        // A tap is an explicit retry. The old `!exploitStatus.isFailed` guard
        // silently swallowed every tap after a failure while the orange banner
        // kept asking the user to tap — the 3.2.7 no-op on iOS 17.5.1.
        guard ExploitRetryPolicy.canStart(
            isRunning: kernelExploitRunning,
            isSuccess: exploitStatus.isSuccess
        ) else { return }
        if exploitStatus.isFailed {
            log("app: retrying kernel chain after a previous failure")
        }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        let backend = SandboxAccess.backend
        log("app: running \(backend.displayName) access setup on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let method = KernelExploit.runReportingVerdict()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if let method = method {
                    self.exploitStatus = .success(method: method)
                    log("app: \(method) access active")
                } else {
                    self.exploitStatus = .failed(method: backend.displayName, code: -1)
                    if backend == .worseQuery && !SandboxAccess.hasAppGroup {
                        log("app: worse_query needs an App Group; re-sign with a tool that provides one")
                    } else {
                        log("app: \(backend.displayName) setup failed — tap retry to run the chain again")
                    }
                }
            }
        }
    }
}

// ==========================================
// 1. GERENCIADOR DE CONEXÃO COM O KEYAUTH (API 1.3)
// ==========================================
class KeyAuthManager: ObservableObject {
    static let shared = KeyAuthManager()
    
    // PREENCHA AQUI OS 3 DADOS DO SEU PAINEL KEYAUTH:
    private let appName = "Demarte9bp's Application"
    private let ownerId = "gCSAX1QBSV"
    private let appVersion = "1.0"
    
    @Published var estaLogado = false
    @Published var carregando = false
    @Published var mensagemErro = ""
    
    private var sessionId: String?
    private let baseUrl = "https://keyauth.win/api/1.3/"
    private let chaveSalvaKey = "KeyAuth_Licenca_Salva"
    
    // Roda automaticamente assim que o aplicativo abre
    init() {
        if let chaveGuardada = UserDefaults.standard.string(forKey: chaveSalvaKey), !chaveGuardada.isEmpty {
            verificarLicenca(chave: chaveGuardada)
        }
    }
    
    func verificarLicenca(chave: String) {
        let chaveLimpa = chave.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chaveLimpa.isEmpty else {
            self.mensagemErro = "Digite uma chave válida."
            return
        }
        
        self.carregando = true
        self.mensagemErro = ""
        
        if let session = sessionId {
            enviarLogin(chave: chaveLimpa, session: session)
        } else {
            inicializar { ok, msg in
                if ok, let session = self.sessionId {
                    self.enviarLogin(chave: chaveLimpa, session: session)
                } else {
                    self.carregando = false
                    self.mensagemErro = msg
                }
            }
        }
    }
    
    private func getHWID() -> String {
        return UIDevice.current.identifierForVendor?.uuidString ?? "iOS-Device-Unknown"
    }
    
    private func inicializar(completion: @escaping (Bool, String) -> Void) {
        let params = "type=init&ver=\(appVersion)&name=\(appName)&ownerid=\(ownerId)"
        requisicao(params: params) { json in
            if let success = json["success"] as? Bool, success, let session = json["sessionid"] as? String {
                self.sessionId = session
                completion(true, "OK")
            } else {
                completion(false, json["message"] as? String ?? "Erro ao conectar no servidor")
            }
        }
    }
    
    private func enviarLogin(chave: String, session: String) {
        let hwid = getHWID()
        let params = "type=license&key=\(chave)&hwid=\(hwid)&sessionid=\(session)&name=\(appName)&ownerid=\(ownerId)"
        
        requisicao(params: params) { json in
            self.carregando = false
            if let success = json["success"] as? Bool, success {
                // SALVA A CHAVE NA MEMÓRIA DO IPHONE QUANDO O LOGIN É APROVADO
                UserDefaults.standard.set(chave, forKey: self.chaveSalvaKey)
                self.estaLogado = true
            } else {
                // SE A CHAVE EXPIROU OU FOI BANIDA, APAGA DA MEMÓRIA E PEDE OUTRA
                UserDefaults.standard.removeObject(forKey: self.chaveSalvaKey)
                self.estaLogado = false
                let bruta = json["message"] as? String ?? "Chave inválida ou expirada"
                self.mensagemErro = self.traduzirMensagem(bruta)
            }
        }
    }
    
  /// Troca o texto cru que o servidor KeyAuth manda (em inglês)
    /// pela mensagem em português.
    private func traduzirMensagem(_ bruta: String) -> String {
        let texto = bruta.lowercased()

        if texto.contains("sem conexão") {
            return "Sem conexão com a internet jumento kkkk."
        }
        if texto.contains("hwid") {
            return "Esta key já está vinculada em outro iphone."
        }
        if texto.contains("paused") {
            return "Sua key está pausada. Chame o demarte."
        }
        if texto.contains("expired") {
            return "Sua key expirou. Chama o chefe demas."
        }
        if texto.contains("banned") {
            return "Esta key foi banida, se fudeo kkkk."
        }
        if texto.contains("invalid") {
            return "Key inválida. Chama o demarte."
        }
        if texto.contains("already been used") {
            return "Esta key já foi utilizada, compre outra com o demas."
        }
        if texto.contains("password") {
            return "Key incorreta. Confira se digitou igual, com maiúsculas e minúsculas cz."
        }
        if texto.contains("subscription") {
            return "Nenhuma assinatura ativa encontrada nessa key chama o demarte."
        }
        return "Não foi possível validar a key. Chama o chefe demas."
    }
    
    private func requisicao(params: String, completion: @escaping ([String: Any]) -> Void) {
        let urlCompleta = "\(baseUrl)?\(params)"
        guard let urlEncoded = urlCompleta.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: urlEncoded) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(["success": false, "message": "Sem conexão com a internet"])
                    return
                }
                completion(json)
            }
        }.resume()
    }
}


// ==========================================
// 2. VISUAL DA TELA DE LOGIN
// ==========================================
struct TelaLoginView: View {
    @ObservedObject var auth = KeyAuthManager.shared
    @State private var chaveDigitada = UserDefaults.standard.string(forKey: "KeyAuth_Licenca_Salva") ?? ""
    
    // LINK DIRETO DA SUA IMAGEM DE FUNDO:
    private let linkImagemFundo = "https://i.postimg.cc/Ght09HcM/Banner-Gamer-Neon-Filza-Automatico-X7.png"
    
    var body: some View {
        ZStack {
            // IMAGEM DE FUNDO EM TELA CHEIA
            AsyncImage(url: URL(string: linkImagemFundo)) { fase in
                if let imagem = fase.image {
                    imagem
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
            
            // DEGRADÊ ESCURO SÓ NA PARTE DE BAIXO (Para destacar o login sem tampar a arte)
            LinearGradient(
                gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.65), Color.black.opacity(0.92)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            // CAIXA DE LOGIN POSICIONADA NA PARTE INFERIOR
            VStack {
                Spacer()
                
                VStack(spacing: 14) {
                    Text("DEMARTE IOS • LOGIN")
                        .font(.headline)
                        .bold()
                        .foregroundColor(.white)
                    
                    // Campo de digitar a key
                    TextField("Copie e cola sua key aqui irmão", text: $chaveDigitada)
                        .padding(14)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .accentColor(.purple)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.purple.opacity(0.8), lineWidth: 1.5)
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    // Mensagem de erro (se a key for inválida)
                    if !auth.mensagemErro.isEmpty {
                        Text(auth.mensagemErro)
                            .foregroundColor(.red)
                            .font(.footnote)
                            .bold()
                            .multilineTextAlignment(.center)
                    }
                    
                    // Botão Roxo Neon
                    Button(action: {
                        auth.verificarLicenca(chave: chaveDigitada)
                    }) {
                        if auth.carregando {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(maxWidth: .infinity)
                                .padding(14)
                        } else {
                            Text("ACESSAR O PODER")
                                .bold()
                                .frame(maxWidth: .infinity)
                                .padding(14)
                        }
                    }
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.purple, Color(red: 0.45, green: 0.0, blue: 0.9)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .shadow(color: Color.purple.opacity(0.6), radius: 8, x: 0, y: 0)
                    .disabled(auth.carregando)
                }
                .padding(20)
                .background(Color.black.opacity(0.65))
                .cornerRadius(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.purple.opacity(0.5), lineWidth: 1)
                )
                .overlay(BordaNeonLED(raio: 18))
                .padding(.horizontal, 20)
                Spacer()
            }
        }
    }
}

// ==========================================
// 3. BORDA NEON COM LED GIRANDO
// ==========================================
struct BordaNeonLED: View {
    var raio: CGFloat = 18
    var espessura: CGFloat = 3
    var segundosPorVolta: Double = 3
    var comBrilho: Bool = true

    private var gradiente: Gradient {
        Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.55),
            .init(color: Color.purple.opacity(0.5), location: 0.75),
            .init(color: Color(red: 0.75, green: 0.25, blue: 1.0), location: 0.92),
            .init(color: .white, location: 0.99),
            .init(color: .clear, location: 1.0)
        ])
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { contexto in
            let tempo = contexto.date.timeIntervalSinceReferenceDate
            let fracao = tempo.truncatingRemainder(dividingBy: segundosPorVolta) / segundosPorVolta
            let angulo = Angle.degrees(fracao * 360)

            ZStack {
                if comBrilho {
                    // brilho borrado por trás
                    RoundedRectangle(cornerRadius: raio)
                        .strokeBorder(
                            AngularGradient(gradient: gradiente, center: .center, angle: angulo),
                            lineWidth: espessura + 2
                        )
                        .blur(radius: 6)
                }

                // linha nítida do LED
                RoundedRectangle(cornerRadius: raio)
                    .strokeBorder(
                        AngularGradient(gradient: gradiente, center: .center, angle: angulo),
                        lineWidth: espessura
                    )
            }
        }
        .allowsHitTesting(false)
    }
}
