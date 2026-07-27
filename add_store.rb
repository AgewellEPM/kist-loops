require 'xcodeproj'

project_path = 'FloatingChatApp.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'FloatingChatApp' }

main_group = project.main_group
sources = main_group.find_subpath('FloatingChatApp/Sources', true)
services = sources.find_subpath('Services', true)

file_path = 'FloatingChatApp/Sources/Services/ConversationStore.swift'
file_ref = services.new_reference(file_path)
file_ref.last_known_file_type = 'sourcecode.swift'
file_ref.source_tree = 'SOURCE_ROOT'

target.source_build_phase.add_file_reference(file_ref)

project.save
puts "Added ConversationStore.swift to project"
