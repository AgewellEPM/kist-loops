require 'xcodeproj'
project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')
test = project.targets.find { |t| t.name == 'FloatingChatAppTests' }
g = project.main_group.find_subpath('FloatingChatAppTests', true)
fp = 'FloatingChatAppTests/ProviderModelOverrideTests.swift'
existing = project.files.map { |f| f.real_path.to_s }
unless existing.include?(File.expand_path(fp))
  r = g.new_reference(fp); r.last_known_file_type='sourcecode.swift'; r.source_tree='SOURCE_ROOT'
  test.source_build_phase.add_file_reference(r); puts "ADDED #{fp}"
end
project.save
