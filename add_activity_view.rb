#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'FloatingChatApp.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find the Components group
components_group = project.main_group.recursive_children.find { |g| 
  g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.display_name == 'Components' && g.parent.display_name == 'Views'
}

if components_group.nil?
  puts "Components group not found, searching for Views group..."
  views_group = project.main_group.recursive_children.find { |g| 
    g.is_a?(Xcodeproj::Project::Object::PBXGroup) && g.display_name == 'Views'
  }
  if views_group
    components_group = views_group.new_group('Components')
  else
    puts "Views group not found either"
    exit 1
  end
end

# Check if file already exists
existing = components_group.files.find { |f| f.path&.include?('AgentActivityView.swift') }
if existing
  puts "AgentActivityView.swift already in project"
else
  # Add the file
  file_path = 'FloatingChatApp/Sources/Views/Components/AgentActivityView.swift'
  file_ref = components_group.new_reference(file_path)
  
  # Add to target
  target = project.targets.find { |t| t.name == 'FloatingChatApp' }
  if target
    target.add_file_references([file_ref])
    puts "Added AgentActivityView.swift to project"
  end
end

project.save
puts "Project saved"
