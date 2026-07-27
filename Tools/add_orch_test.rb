require 'xcodeproj'
project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')
test = project.targets.find { |t| t.name == 'FloatingChatAppTests' }
abort('no test target') unless test
group = project.main_group.find_subpath('FloatingChatAppTests', true)
fp = 'FloatingChatAppTests/AgentOrchestrationResumeTests.swift'
existing = project.files.map { |f| f.real_path.to_s }
if existing.include?(File.expand_path(fp))
  puts "SKIP #{fp}"
else
  ref = group.new_reference(fp); ref.last_known_file_type = 'sourcecode.swift'; ref.source_tree = 'SOURCE_ROOT'
  test.source_build_phase.add_file_reference(ref); puts "ADDED #{fp}"
end
project.save
