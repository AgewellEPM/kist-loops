#!/usr/bin/env ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('FloatingChatApp.xcodeproj')

# Remove AgentActivityView
project.files.each do |file|
  if file.path&.include?('AgentActivityView')
    project.targets.each do |target|
      target.source_build_phase.files.to_a.each do |bf|
        bf.remove_from_project if bf.file_ref == file
      end
    end
    file.remove_from_project
    puts "Removed AgentActivityView from project"
  end
end
project.save
