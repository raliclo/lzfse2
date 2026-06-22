//  AppIconGenerator.swift — Generate app icon for LZFSE UI
//
//  Usage:
//  1. Add this file to your Xcode project
//  2. Create a new SwiftUI view that uses IconPreview
//  3. Take screenshots at required sizes
//  4. Add to Assets.xcassets/AppIcon
//
//  Or use SF Symbols app to export "doc.zipper" as icon template
//

import SwiftUI

/// Preview-only view for generating app icon
struct AppIconView: View {
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.5, blue: 1.0),
                    Color(red: 0.0, green: 0.3, blue: 0.8)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Icon symbol
            VStack(spacing: 8) {
                Image(systemName: "doc.zipper.fill")
                    .font(.system(size: 200, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                
                // Optional: Add "LZFSE" text
                // Text("LZFSE")
                //     .font(.system(size: 60, weight: .bold, design: .rounded))
                //     .foregroundColor(.white)
            }
        }
        .frame(width: 1024, height: 1024) // macOS icon size
    }
}

/// Alternative minimalist design
struct AppIconViewMinimal: View {
    var body: some View {
        ZStack {
            // Solid color background
            Color(red: 0.0, green: 0.48, blue: 0.95)
            
            // Large "Z" letterform
            Text("Z")
                .font(.system(size: 600, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .opacity(0.9)
            
            // Small compression indicator
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(40)
                }
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Alternative design with compression visualization
struct AppIconViewCompression: View {
    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.2, green: 0.6, blue: 1.0),
                    Color(red: 0.1, green: 0.4, blue: 0.9)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            VStack(spacing: 20) {
                // "Before" representation - large file
                RoundedRectangle(cornerRadius: 30)
                    .fill(.white.opacity(0.9))
                    .frame(width: 400, height: 300)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 100))
                                .foregroundColor(.blue)
                            Text("Large")
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                
                // Arrow
                Image(systemName: "arrow.down")
                    .font(.system(size: 60, weight: .bold))
                    .foregroundColor(.white)
                
                // "After" representation - compressed file
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(0.9))
                    .frame(width: 300, height: 200)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.zipper.fill")
                                .font(.system(size: 70))
                                .foregroundColor(.blue)
                            Text("Small")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - Preview Provider

#Preview("Default Icon") {
    AppIconView()
}

#Preview("Minimal Icon") {
    AppIconViewMinimal()
}

#Preview("Compression Visualization") {
    AppIconViewCompression()
}

// MARK: - Export Instructions

/*
 TO EXPORT ICON:
 
 1. Add this file to your Xcode project
 
 2. Open SwiftUI Preview (⌘⌥⏎)
 
 3. Right-click on preview → "Export Preview"
    Or take screenshot of preview
 
 4. Resize to required sizes:
    - 1024×1024 (base)
    - 512×512 @1x and @2x
    - 256×256 @1x and @2x
    - 128×128 @1x and @2x
    - 32×32 @1x and @2x
    - 16×16 @1x and @2x
 
 5. In Xcode, select Assets.xcassets
 
 6. Click AppIcon
 
 7. Drag images into appropriate size slots
 
 ALTERNATIVE - Use SF Symbols:
 
 1. Open SF Symbols app (free from Apple)
 
 2. Search for "doc.zipper"
 
 3. File → Export Symbol
 
 4. Choose size and format
 
 5. Use as base for custom icon
 
 ALTERNATIVE - Use iconutil (command line):
 
 1. Create folder: Icon.iconset
 
 2. Add files:
    icon_16x16.png
    icon_16x16@2x.png
    icon_32x32.png
    icon_32x32@2x.png
    icon_128x128.png
    icon_128x128@2x.png
    icon_256x256.png
    icon_256x256@2x.png
    icon_512x512.png
    icon_512x512@2x.png
 
 3. Run: iconutil -c icns Icon.iconset
 
 4. Result: Icon.icns file
 
 5. Rename to AppIcon.icns
 
 6. Add to Xcode Assets.xcassets
 */

// MARK: - Color Palette

extension Color {
    static let lzfseBlue = Color(red: 0.0, green: 0.48, blue: 0.95)
    static let lzfseDarkBlue = Color(red: 0.0, green: 0.3, blue: 0.8)
    static let lzfseLightBlue = Color(red: 0.2, green: 0.6, blue: 1.0)
}

// MARK: - Reusable Components

struct CompressionArrow: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.white)
                .frame(width: 20, height: 100)
            
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 60))
                .foregroundColor(.white)
                .offset(y: -10)
        }
    }
}

struct FileIcon: View {
    let size: CGFloat
    let compressed: Bool
    
    var body: some View {
        Image(systemName: compressed ? "doc.zipper.fill" : "doc.fill")
            .font(.system(size: size))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
    }
}
