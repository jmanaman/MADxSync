//
//  SnapToastView.swift
//  MADxSync
//
//  Visual feedback when a tap snaps to a point site or storm drain.
//  Shows a brief toast with the source name and a ripple effect.
//

import SwiftUI

/// Toast that appears at top of screen when snap occurs
struct SnapToastView: View {
    let sourceName: String
    let isVisible: Bool
    
    var body: some View {
        if isVisible {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.orange)
                    
                    Text("Snapped")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    
                    Text(sourceName)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.8))
                        .shadow(color: .orange.opacity(0.3), radius: 8, x: 0, y: 2)
                )
                .overlay(
                    Capsule()
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                )
                
                Spacer()
            }
            .padding(.top, 100)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: isVisible)
        }
    }
}

#Preview {
    ZStack {
        Color.gray
        SnapToastView(sourceName: "T 20 R 25 S 18 # 13", isVisible: true)
    }
}
