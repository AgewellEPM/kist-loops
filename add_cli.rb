require 'xcodeproj'

project_path = 'FloatingChatApp.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'FloatingChatApp' }

main_group = project.main_group
sources = main_group.find_subpath('FloatingChatApp/Sources', true)

# Create CLI group if it doesn't exist
cli_group = sources.find_subpath('CLI', false)
if cli_group.nil?
  cli_group = sources.new_group('CLI', 'FloatingChatApp/Sources/CLI')
end

# Add the file
file_path = 'FloatingChatApp/Sources/CLI/AgentCLI.swift'
file_ref = cli_group.new_reference(file_path)
file_ref.last_known_file_type = 'sourcecode.swift'
file_ref.source_tree = 'SOURCE_ROOT'

target.source_build_phase.add_file_reference(file_ref)

project.save
puts "Added AgentCLI.swift to project"
