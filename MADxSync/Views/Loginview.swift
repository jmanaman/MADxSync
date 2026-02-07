//
//  LoginView.swift
//  MADxSync
//
//  District login screen.
//  Dark theme matching MADx brand identity.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject private var authService = AuthService.shared
    
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var showPassword: Bool = false
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                // Logo text
                Text("M·A·Dx")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.bottom, 4)
                
                Text("MODERN APPLIED DYNAMIX")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(3)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.bottom, 12)
                
                Text("SYNC")
                    .font(.system(size: 18, weight: .light))
                    .tracking(8)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 8)
                
                Rectangle()
                    .fill(Color.red.opacity(0.6))
                    .frame(width: 40, height: 2)
                    .padding(.bottom, 40)
                
                // Login card
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DISTRICT LOGIN")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(2)
                            .foregroundColor(.gray)
                        
                        HStack(spacing: 12) {
                            Image(systemName: "building.2")
                                .foregroundColor(.red.opacity(0.8))
                                .frame(width: 20)
                            TextField("", text: $email, prompt: Text("email@madxops.com").foregroundColor(.gray.opacity(0.5)))
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .foregroundColor(.white)
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PASSWORD")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(2)
                            .foregroundColor(.gray)
                        
                        HStack(spacing: 12) {
                            Image(systemName: "lock")
                                .foregroundColor(.red.opacity(0.8))
                                .frame(width: 20)
                            
                            if showPassword {
                                TextField("", text: $password, prompt: Text("password").foregroundColor(.gray.opacity(0.5)))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .foregroundColor(.white)
                            } else {
                                SecureField("", text: $password, prompt: Text("password").foregroundColor(.gray.opacity(0.5)))
                                    .foregroundColor(.white)
                            }
                            
                            Button(action: { showPassword.toggle() }) {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundColor(.gray.opacity(0.6))
                            }
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    
                    if let error = authService.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Button(action: signIn) {
                        HStack(spacing: 10) {
                            if authService.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text("SIGN IN")
                                    .font(.system(size: 15, weight: .semibold))
                                    .tracking(2)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            canSignIn
                                ? LinearGradient(colors: [Color.red.opacity(0.8), Color.red.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(!canSignIn || authService.isLoading)
                }
                .padding(28)
                .background(Color.white.opacity(0.04))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                
                Spacer()
                
                HStack(spacing: 6) {
                    Text("MADx")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                    Circle()
                        .fill(Color.red.opacity(0.4))
                        .frame(width: 4, height: 4)
                    Text("Field Operations")
                        .font(.system(size: 11, weight: .light))
                        .foregroundColor(.white.opacity(0.2))
                }
                .padding(.bottom, 24)
            }
        }
    }
    
    private var canSignIn: Bool {
        !email.isEmpty && !password.isEmpty
    }
    
    private func signIn() {
        Task {
            await authService.signIn(email: email, password: password)
        }
    }
}

#Preview {
    LoginView()
}
