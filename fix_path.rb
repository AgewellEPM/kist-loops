#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')

# Find and remove the incorrectly added file
project.files.each do |file|
  if file.path&.include?('AgentActivityView.swift')
    puts "Found: #{file.path}"
    # Remove from build phases
    project.targets.each do |target|
      target.source_build_phase.files.each do |build_file|
        if build_file.file_ref == file
          build_file.remove_from_project
          puts "Removed from build phase"
        end
      end
    end
    file.remove_from_project
    puts "Removed file reference"
  end
end

# Now add it correctly
components_group = project.main_group.recursive_children.find { |g| 
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.display_name == 'Components' && g.parent&.display_name == 'Views'
}

if components_group
  # Add with just the filename since the group already has the correct path
  file_ref = components_group.new_reference('AgentActivityView.swift')
  file_ref.source_tree = '<group>'
  
  target = project.targets.find { |t| t.name == 'FloatingChatApp' }
  target.add_file_references([file_ref]) if target
  puts "Added correctly: AgentActivityView.swift"
end

project.save
