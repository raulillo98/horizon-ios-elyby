import Foundation
import SwiftUI



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
            error = "Enter your Ely.by username and password."
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
                error = "Could not encode the Ely.by session."
                return
            }

            let answer = await Bridge.send("launcher-session \(json)")
            if let message = answer["error"] as? String {
                error = message
            } else if let ok = answer["ok"] as? Bool, !ok {
                error = "Horizon couldn't activate the Ely.by session."
            } else {
                error = nil
            }
        } catch {
            self.error = "The Ely.by session could not be prepared: \(error.localizedDescription)"
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


struct ElyByAccountCard: View {
    @ObservedObject var controller: ElyBySessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark")
                VStack(alignment: .leading, spacing: 2) {
                    Text("ELY.BY").font(.caption.weight(.bold))
                    Text(controller.account?.selectedProfile.name ?? "Not signed in.")
                        .font(.headline)
                }
                Spacer()
                if controller.account != nil {
                    Button("Sing out") {
                        controller.signOut()
                    }
                }
            }

            if controller.account == nil {
                TextField("Ely.by username or email"), text: $controller.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)

                SecureField("Password", text: $controller.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    controller.signIn()
                } label: {
                    if controller.busy {
                        ProgressView()
                    } else {
                        Text("Sing in with Ely.by")
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

            Text("Works on servers configured for Ely.by/Authlib Injector.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
