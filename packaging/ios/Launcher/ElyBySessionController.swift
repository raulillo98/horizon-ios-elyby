import Foundation
import SwiftUI

/// Estado observable de la cuenta Ely.by.
/// La contraseña no se conserva: ElyByAccount almacena el token en Keychain.
@MainActor
final class ElyBySessionController: ObservableObject {
    @Published private(set) var account: ElyByAccount.Account?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var username = ""
    @Published var password = ""

    init() {
        account = try? ElyByAccount.savedAccount()
    }

    func signIn() {
        guard !busy else { return }

        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else {
            error = "Introduce tu usuario y contraseña de Ely.by."
            return
        }

        busy = true
        let secret = password
        password = ""

        Task {
            defer { busy = false }
            do {
                let signedIn = try await ElyByAccount.authenticate(
                    username: user,
                    password: secret
                )
                account = signedIn
                await handOver()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func restoreAndHandOver() async {
        do {
            guard let saved = try ElyByAccount.savedAccount() else { return }
            account = saved
            await handOver()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func handOver() async {
        guard let account else { return }

        let session: [String: String] = [
            "name": account.selectedProfile.name,
            "uuid": account.selectedProfile.id,
            "access_token": account.accessToken,
            "user_type": "elyby"
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: session)
            guard let json = String(data: data, encoding: .utf8) else {
                error = "No se pudo codificar la sesión Ely.by."
                return
            }

            let answer = await Bridge.send("launcher-session \(json)")
            if let message = answer["error"] as? String {
                error = message
            } else if let ok = answer["ok"] as? Bool, !ok {
                error = "Horizon no pudo activar la sesión Ely.by."
            } else {
                error = nil
            }
        } catch {
            self.error = "No se pudo preparar la sesión Ely.by: \(error.localizedDescription)"
        }
    }

    func signOut() {
        Task {
            let answer = await Bridge.send("launcher-session off")
            if let message = answer["error"] as? String {
                error = message
                return
            }

            do {
                try ElyByAccount.signOut()
                account = nil
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Tarjeta de acceso Ely.by para incluir en la hoja de cuentas de HomeView.
struct ElyByAccountCard: View {
    @ObservedObject var controller: ElyBySessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark")
                VStack(alignment: .leading, spacing: 2) {
                    Text("ELY.BY").font(.caption.weight(.bold))
                    Text(controller.account?.selectedProfile.name ?? "No has iniciado sesión")
                        .font(.headline)
                }
                Spacer()
                if controller.account != nil {
                    Button("Cerrar sesión") {
                        controller.signOut()
                    }
                }
            }

            if controller.account == nil {
                TextField("Usuario o correo de Ely.by", text: $controller.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)

                SecureField("Contraseña", text: $controller.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    controller.signIn()
                } label: {
                    if controller.busy {
                        ProgressView()
                    } else {
                        Text("Iniciar sesión con Ely.by")
                    }
                }
                .disabled(controller.busy)
            }

            if let message = controller.error {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Funciona en servidores configurados para Ely.by/Authlib Injector.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
