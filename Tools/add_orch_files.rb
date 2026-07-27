require 'xcodeproj'
project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')
target = project.targets.find { |t| t.name == 'FloatingChatApp' }
group = project.main_group.find_subpath('FloatingChatApp/Sources/Services/AgentLoop', true)
existing = project.files.map { |f| f.real_path.to_s }
files = [
  'FloatingChatApp/Sources/Services/AgentLoop/JSONDirectoryStore.swift',
  'FloatingChatApp/Sources/Services/AgentLoop/OrchestrationCheckpoint.swift',
  'FloatingChatApp/Sources/Services/AgentLoop/AgentLoopEngine+Resume.swift',
]
files.each do |fp|
  next unless File.exist?(fp)
  if existing.include?(File.expand_path(fp)) then puts "SKIP #{fp}"; next end
  ref = group.new_reference(fp); ref.last_known_file_type = 'sourcecode.swift'; ref.source_tree = 'SOURCE_ROOT'
  target.source_build_phase.add_file_reference(ref); puts "ADDED #{fp}"
end
project.save
