require 'xcodeproj'
project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')
app = project.targets.find { |t| t.name == 'FloatingChatApp' }
test = project.targets.find { |t| t.name == 'FloatingChatAppTests' }
existing = project.files.map { |f| f.real_path.to_s }
def add(project, target, group_path, fp, existing)
  return puts("SKIP #{fp}") if existing.include?(File.expand_path(fp))
  g = project.main_group.find_subpath(group_path, true)
  r = g.new_reference(fp); r.last_known_file_type='sourcecode.swift'; r.source_tree='SOURCE_ROOT'
  target.source_build_phase.add_file_reference(r); puts "ADDED #{fp}"
end
add(project, app, 'FloatingChatApp/Sources/Services/Providers', 'FloatingChatApp/Sources/Services/Providers/GeminiProvider.swift', existing)
add(project, test, 'FloatingChatAppTests', 'FloatingChatAppTests/GeminiProviderTests.swift', existing)
project.save
