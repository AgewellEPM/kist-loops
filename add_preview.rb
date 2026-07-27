#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')

# Find Services group
services = project.main_group.recursive_children.find { |g| 
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.path == 'Services' && g.parent&.path == 'Sources'
}

if services
  file_ref = services.new_file('AppPreviewService.swift')
  target = project.targets.find { |t| t.name == 'FloatingChatApp' }
  target.add_file_references([file_ref]) if target
  puts "Added AppPreviewService.swift"
end

project.save
