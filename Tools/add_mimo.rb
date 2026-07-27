require 'xcodeproj'
project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')
app = project.targets.find { |t| t.name == 'FloatingChatApp' }
fp = 'FloatingChatApp/Sources/Services/Providers/MiMoProvider.swift'
existing = project.files.map { |f| f.real_path.to_s }
unless existing.include?(File.expand_path(fp))
  g = project.main_group.find_subpath('FloatingChatApp/Sources/Services/Providers', true)
  r = g.new_reference(fp); r.last_known_file_type='sourcecode.swift'; r.source_tree='SOURCE_ROOT'
  app.source_build_phase.add_file_reference(r); puts "ADDED #{fp}"
end
project.save
