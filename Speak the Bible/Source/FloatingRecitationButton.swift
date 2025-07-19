//  FloatingRecitationButton.swift
import SwiftUI

struct FloatingRecitationButton: View {
    let isRecitationActive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack { // For layering the border and the main button shape
                // White Border - Always circular
                Circle()
                    .strokeBorder(.white.opacity(0.7), lineWidth: 3.0)
                    .frame(width: 68, height: 68) // Border slightly larger

                // Main Button
                if isRecitationActive { // Stop button
                    Circle() // Inner part is also circular for stop state
                        .fill(Color.white.opacity(0.4)) // A neutral gray for stop state
                        .frame(width: 60, height: 60)
                        .overlay(
                            Image(systemName: "stop.fill") // Square stop icon
                                .font(.system(size: 26)) // Adjust size as needed
                                .foregroundColor(.red.opacity(0.9)) // Corrected: Darker icon on gray background
                        )
                } else { // Start button
                    Circle()
                        .fill(.red)
                        .frame(width: 60, height: 60)
                        .overlay(
                            Image(systemName: "mic.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        )
                }
            }
        }
        .disabled(isDisabled)
        .shadow(color: Color.black.opacity(0.3), radius: 5, x: 0, y: 2) // Standard shadow
        // The padding for position will be applied by the parent view.
    }
}
