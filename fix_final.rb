#!/usr/bin/env ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')

# Remove all AgentActivityView references first
project.files.each do |file|
  if file.path&.include?('AgentActivityView')
    puts "Removing: #{file.path}"
    project.targets.each do |target|
      target.source_build_phase.files.to_a.each do |bf|
        bf.remove_from_project if bf.file_ref == file
      end
    end
    file.remove_from_project
  end
end

# Find the Components group 
components = nil
project.main_group.recursive_children.each do |item|
  if item.is_a?(Xcodeproj::Project::Object::PBXGroup) && item.path == 'Components' && item.parent&.path == 'Views'
    components = item
    break
  end
end

if components.nil?
  # Find by name
  project.main_group.recursive_children.each do |item|
    if item.is_a?(Xcodeproj::Project::Object::PBXGroup) && item.display_name == 'Components'
      components = item
      puts "Found Components group: #{item.real_path}"
      break
    end
  end
end

if components
  puts "Components group real path: #{components.real_path}"
  
  # The file should be at the real path of the Components group + filename
  file_ref = components.new_file('AgentActivityView.swift')
  
  target = project.targets.find { |t| t.name == 'FloatingChatApp' }
  target.add_file_references([file_ref]) if target
  puts "Added AgentActivityView.swift"
else
  puts "Components group not found!"
  exit 1
end

project.save
puts "Project saved"
