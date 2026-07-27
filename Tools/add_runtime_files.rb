require 'xcodeproj'

project_path = 'FloatingChatApp.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'FloatingChatApp' }
abort('target not found') unless target

main_group = project.main_group
agentloop = main_group.find_subpath('FloatingChatApp/Sources/Services/AgentLoop', true)

files = [
  'FloatingChatApp/Sources/Services/AgentLoop/AgentCheckpoint.swift',
  'FloatingChatApp/Sources/Services/AgentLoop/CheckpointStore.swift',
  'FloatingChatApp/Sources/Services/AgentLoop/UnifiedAgentRuntime+Resume.swift',
  'FloatingChatApp/Sources/Services/AgentLoop/ReplanEngine.swift',
]

existing_paths = project.files.map(&:real_path).map(&:to_s)

files.each do |fp|
  abs = File.expand_path(fp)
  if existing_paths.include?(abs)
    puts "SKIP (already in project): #{fp}"
    next
  end
  ref = agentloop.new_reference(fp)
  ref.last_known_file_type = 'sourcecode.swift'
  ref.source_tree = 'SOURCE_ROOT'
  target.source_build_phase.add_file_reference(ref)
  puts "ADDED: #{fp}"
end

project.save
puts "Saved project."
