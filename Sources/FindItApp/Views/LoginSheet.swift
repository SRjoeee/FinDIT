import SwiftUI
import AuthenticationServices

/// Login / Sign-up sheet
///
/// Provides Email + Password sign-in/up as primary method.
/// Apple Sign-In will be added when the app has proper code signing.
struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    let authManager: AuthManager

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showForgotPassword = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text(showForgotPassword ? "重置密码" : (isSignUp ? "创建账户" : "登录"))
                    .font(.title2.bold())

                Text(showForgotPassword
                     ? "输入邮箱地址，我们将发送重置链接"
                     : "登录后即享 14 天云端 AI 免费试用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            // Email + Password
            VStack(spacing: 12) {
                TextField("邮箱", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)

                if !showForgotPassword {
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(isSignUp ? .newPassword : .password)
                }
            }

            // Error
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Success
            if let success = successMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(success)
                }
                .font(.caption)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
            }

            if showForgotPassword {
                // Forgot password mode
                Button {
                    Task { await sendPasswordReset() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("发送重置邮件")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(email.isEmpty || isLoading)

                Button {
                    showForgotPassword = false
                    errorMessage = nil
                    successMessage = nil
                } label: {
                    Text("返回登录")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            } else {
                // Normal login/signup mode
                Button {
                    Task { await submit() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(isSignUp ? "注册" : "登录")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                // Toggle sign-in / sign-up + forgot password
                HStack {
                    Button {
                        isSignUp.toggle()
                        errorMessage = nil
                        successMessage = nil
                    } label: {
                        Text(isSignUp ? "已有账户？登录" : "没有账户？注册")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)

                    if !isSignUp {
                        Spacer()
                        Button {
                            showForgotPassword = true
                            errorMessage = nil
                            successMessage = nil
                        } label: {
                            Text("忘记密码？")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Info
            Text("登录即表示同意服务条款。云端功能使用 OpenRouter API。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 320)
    }

    private func submit() async {
        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            if isSignUp {
                let result = try await authManager.signUpWithEmail(email: email, password: password)
                switch result {
                case .authenticated:
                    dismiss()
                case .confirmationPending:
                    successMessage = "注册成功！请查收确认邮件，确认后即可登录。"
                    isSignUp = false  // Switch to login mode for after confirmation
                }
            } else {
                try await authManager.signInWithEmail(email: email, password: password)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func sendPasswordReset() async {
        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            try await authManager.resetPassword(email: email)
            successMessage = "重置邮件已发送，请查收邮箱。"
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
