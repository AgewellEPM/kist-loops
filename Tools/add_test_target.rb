require 'xcodeproj'

project_path = 'FloatingChatApp.xcodeproj'
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |t| t.name == 'FloatingChatApp' }
abort('app target missing') unless app

# Reuse an existing test target if present (idempotent).
test = project.targets.find { |t| t.name == 'FloatingChatAppTests' }
if test.nil?
  test = project.new_target(:unit_test_bundle, 'FloatingChatAppTests', :osx, '14.0')
  puts 'Created FloatingChatAppTests target'
else
  puts 'Reusing existing FloatingChatAppTests target'
end

test.build_configurations.each do |config|
  s = config.build_settings
  s['SWIFT_VERSION'] = '5.0'
  s['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.floatingchat.appTests'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/FloatingChatApp.app/Contents/MacOS/FloatingChatApp'
  s['BUNDLE_LOADER'] = '$(TEST_HOST)'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
end

# Depend on the app so it builds + is testable first.
test.add_dependency(app)

# Group + source file.
main_group = project.main_group
test_group = main_group.find_subpath('FloatingChatAppTests', true)
test_group.set_source_tree('SOURCE_ROOT')

test_file = 'FloatingChatAppTests/AgentRuntimeStateTests.swift'
already = project.files.map { |f| f.real_path.to_s }.include?(File.expand_path(test_file))
unless already
  ref = test_group.new_reference(test_file)
  ref.last_known_file_type = 'sourcecode.swift'
  ref.source_tree = 'SOURCE_ROOT'
  test.source_build_phase.add_file_reference(ref)
  puts "Added #{test_file}"
end

project.save

# Shared scheme that builds the app and runs the test bundle.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(test)
scheme.set_launch_target(app)
scheme.save_as(project_path, 'FloatingChatApp', true)
puts 'Saved shared scheme FloatingChatApp (with test action)'
