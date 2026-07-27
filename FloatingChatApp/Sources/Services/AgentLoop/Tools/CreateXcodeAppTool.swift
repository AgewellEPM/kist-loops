import Foundation

/// Tool to scaffold a new Xcode app project (macOS or iOS) using SwiftUI
/// Uses the 'xcodeproj' Ruby gem to create a real .xcodeproj
final class CreateXcodeAppTool: AgentTool {
    let name = "create_xcode_app"
    let description = "Create a new Xcode app project. Parameters: name (required), platform ('macos' or 'ios', default: 'macos'), bundle_id (optional), path (optional; default = projectPath). Generates a SwiftUI app with ContentView."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "name", type: "string", description: "App name", required: true),
        ToolParameter(name: "platform", type: "string", description: "'macos' or 'ios' (default: macos)", required: false),
        ToolParameter(name: "bundle_id", type: "string", description: "Bundle identifier (default: com.example.<name>)", required: false),
        ToolParameter(name: "path", type: "string", description: "Directory to create the project in (default: projectPath)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: name")
        }

        let platform = ((arguments["platform"] as? String) ?? "macos").lowercased()
        guard platform == "macos" || platform == "ios" else {
            return ToolResult(success: false, output: "", error: "Invalid platform. Use 'macos' or 'ios'.")
        }

        let basePath = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destRoot = basePath?.isEmpty == false ? basePath! : projectPath
        let destDir = URL(fileURLWithPath: destRoot).appendingPathComponent(name).path

        // Create directory
        do { try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true) } catch {}

        // Write SwiftUI sources
        let sourcesDir = destDir + "/\(name)"
        try? FileManager.default.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)

        let appSwift = swiftUIAppSource(appName: name, platform: platform)
        let contentSwift = contentViewSource()

        let appSwiftPath = sourcesDir + "/\(name).swift"
        let contentSwiftPath = sourcesDir + "/ContentView.swift"
        try appSwift.write(toFile: appSwiftPath, atomically: true, encoding: .utf8)
        try contentSwift.write(toFile: contentSwiftPath, atomically: true, encoding: .utf8)

        // Write Info.plist
        let plistPath = destDir + "/Info.plist"
        try infoPlistXML().write(toFile: plistPath, atomically: true, encoding: .utf8)

        // Ruby script to create Xcode project
        let rubyPath = destDir + "/create_project.rb"
        let bundleId = (arguments["bundle_id"] as? String) ?? defaultBundleId(for: name)
        let ruby = rubyScript(appName: name, platform: platform, bundleId: bundleId)
        try ruby.write(toFile: rubyPath, atomically: true, encoding: .utf8)

        // Run the ruby script
        let result = runRubyScript(at: rubyPath, workingDir: destDir)
        guard result.success else { return result }

        // Optionally return instructions
        let projPath = destDir + "/\(name).xcodeproj"
        let output = "Created Xcode app at: \(destDir)\nProject: \(projPath)\nTo open: open \"\(projPath)\"\nTo build: xcodebuild -project \"\(projPath)\" -scheme \(name) -configuration Debug build"
        return ToolResult(success: true, output: output, metadata: [
            "project_path": projPath,
            "app_path": destDir
        ])
    }

    // MARK: - Helpers

    private func defaultBundleId(for name: String) -> String {
        let simple = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        return "com.example.\(simple)"
    }

    private func swiftUIAppSource(appName: String, platform: String) -> String {
        if platform == "ios" {
            return """
            import SwiftUI

            @main
            struct \(appName): App {
                var body: some Scene {
                    WindowGroup {
                        ContentView()
                    }
                }
            }
            """
        } else {
            return """
            import SwiftUI

            @main
            struct \(appName): App {
                var body: some Scene {
                    WindowGroup("\(appName)") {
                        ContentView()
                    }
                    .windowStyle(.automatic)
                }
            }
            """
        }
    }

    private func contentViewSource() -> String {
        return """
        import SwiftUI

        struct ContentView: View {
            @State private var now = Date()
            private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

            var body: some View {
                VStack(spacing: 12) {
                    Text(now, style: .time)
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                    Text(now, style: .date)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .onReceive(timer) { now = $0 }
            }
        }
        """
    }

    private func infoPlistXML() -> String {
        return """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"> 
        <plist version=\"1.0\">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>$(EXECUTABLE_NAME)</string>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>$(PRODUCT_NAME)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func rubyScript(appName: String, platform: String, bundleId: String) -> String {
        // Ruby that creates a basic SwiftUI app target with Info.plist
        return """
        #!/usr/bin/env ruby
        begin
          require 'xcodeproj'
        rescue LoadError
          puts 'Installing xcodeproj gem...'
          system('gem install xcodeproj')
          require 'xcodeproj'
        end

        name = '#{appName}'
        platform = '#{platform}'
        bundle_id = '#{bundleId}'

        project_path = File.join(Dir.pwd, "#{appName}.xcodeproj")
        project = Xcodeproj::Project.new(project_path)

        plat_sym = platform == 'ios' ? :ios : :osx
        dep_target = platform == 'ios' ? '15.0' : '13.0'

        target = project.new_target(:application, name, plat_sym, dep_target)
        target.product_name = name

        # Build settings
        project.build_configurations.each do |config|
          config.build_settings["SWIFT_VERSION"] = "5.0"
        end
        target.build_configurations.each do |config|
          config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
          config.build_settings["INFOPLIST_FILE"] = "Info.plist"
          config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
        end

        # Groups and files
        main_group = project.main_group
        app_group = main_group.new_group(name)
        files = [
          { path: File.join(name, "#{name}.swift"), name: "#{name}.swift" },
          { path: File.join(name, "ContentView.swift"), name: "ContentView.swift" },
          { path: "Info.plist", name: "Info.plist" }
        ]

        files.each do |f|
          file_ref = app_group.new_reference(f[:path])
          target.add_file_references([file_ref])
        end

        project.save
        puts "Created project at: #{project_path}"
        """
    }

    private func runRubyScript(at path: String, workingDir: String) -> ToolResult {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ruby", path]

        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return ToolResult(success: false, output: "", error: "Failed to start ruby: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let outStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let success = process.terminationStatus == 0
        let output = success ? outStr : (outStr + "\n" + errStr)
        return ToolResult(success: success, output: output, error: success ? nil : "Ruby exited with code \(process.terminationStatus)")
    }
}

