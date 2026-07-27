require 'xcodeproj'
project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')
app = project.targets.find { |t| t.name == 'FloatingChatApp' }
test = project.targets.find { |t| t.name == 'FloatingChatAppTests' }
existing = project.files.map { |f| f.real_path.to_s }

def add(project, target, group_path, fp, existing)
  return puts("SKIP #{fp}") if existing.include?(File.expand_path(fp))
  group = project.main_group.find_subpath(group_path, true)
  ref = group.new_reference(fp); ref.last_known_file_type = 'sourcecode.swift'; ref.source_tree = 'SOURCE_ROOT'
  target.source_build_phase.add_file_reference(ref); puts "ADDED #{fp}"
end

add(project, app, 'FloatingChatApp/Sources/Views', 'FloatingChatApp/Sources/Views/ResumePickerView.swift', existing)
add(project, test, 'FloatingChatAppTests', 'FloatingChatAppTests/ResumePickerViewModelTests.swift', existing)
project.save
