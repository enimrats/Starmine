#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'
require 'pathname'

ROOT = Pathname.new(__dir__).join('..').expand_path
PROJECT_PATH = ROOT.join('StarmineApple.xcodeproj')
PACKAGE_PATH = ROOT.join('Vendor/MPVKit-0.41.0')
SOURCE_ROOT = ROOT.join('App/Sources')
RESOURCE_ROOT = ROOT.join('App/Resources')

if PROJECT_PATH.exist?
  puts "Project already exists at #{PROJECT_PATH}"
  exit 0
end

project = Xcodeproj::Project.new(PROJECT_PATH.to_s)
project.root_object.compatibility_version = 'Xcode 16.0'
project.root_object.attributes['LastSwiftUpdateCheck'] = '1640'
project.root_object.attributes['LastUpgradeCheck'] = '1640'

main_group = project.main_group
sources_group = main_group.new_group('App/Sources', SOURCE_ROOT.to_s)
resources_group = main_group.new_group('App/Resources', RESOURCE_ROOT.to_s)
frameworks_group = main_group['Frameworks'] || main_group.new_group('Frameworks')

package_ref = frameworks_group.new_file(PACKAGE_PATH.relative_path_from(ROOT).to_s)
package_ref.last_known_file_type = 'wrapper'
package_ref.name = 'MPVKit'

local_package_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
local_package_ref.path = PACKAGE_PATH.relative_path_from(ROOT).to_s
local_package_ref.relative_path = PACKAGE_PATH.relative_path_from(ROOT).to_s
project.root_object.package_references << local_package_ref

ios_target = project.new_target(:application, 'Starmine iOS', :ios, '16.0')
mac_target = project.new_target(:application, 'Starmine macOS', :osx, '13.0')

targets = {
  ios: ios_target,
  mac: mac_target,
}

common_settings = {
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'SWIFT_VERSION' => '5.10',
  'CLANG_ENABLE_MODULES' => 'YES',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
  'IPHONEOS_DEPLOYMENT_TARGET' => '16.0',
  'MACOSX_DEPLOYMENT_TARGET' => '13.0',
  'MARKETING_VERSION' => '0.1.0',
  'CURRENT_PROJECT_VERSION' => '1',
  'CODE_SIGN_STYLE' => 'Automatic',
  'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.entertainment',
  'INFOPLIST_KEY_CFBundleDisplayName' => 'Starmine',
  'INFOPLIST_KEY_NSHumanReadableCopyright' => '',
}

ios_bundle_identifier = 'io.github.Starmine.apple.ios'
mac_bundle_identifier = 'io.github.Starmine.apple.macos'

[ios_target, mac_target].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!(common_settings)
    config.build_settings['SDKROOT'] = target == ios_target ? 'iphoneos' : 'macosx'
    config.build_settings['SUPPORTED_PLATFORMS'] = target == ios_target ? 'iphonesimulator iphoneos' : 'macosx'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = target == ios_target ? ios_bundle_identifier : mac_bundle_identifier
    config.build_settings['TARGETED_DEVICE_FAMILY'] = target == ios_target ? '1,2' : nil
  end
end

def add_package_dependency(project, target, package_reference, product_name)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = product_name
  dependency.package = package_reference
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

add_package_dependency(project, ios_target, local_package_ref, 'MPVKit')
add_package_dependency(project, mac_target, local_package_ref, 'MPVKit')

source_paths = Dir.glob(SOURCE_ROOT.join('**/*.swift')).sort
source_paths.each do |path|
  relative = Pathname.new(path).relative_path_from(SOURCE_ROOT).to_s
  parent_group = relative.split('/')[0..-2].inject(sources_group) do |group, component|
    group[component] || group.new_group(component)
  end

  file_ref = parent_group.new_file(path)

  case File.basename(path)
  when 'StarmineiOSApp.swift'
    ios_target.add_file_references([file_ref])
  when 'StarmineMacApp.swift'
    mac_target.add_file_references([file_ref])
  else
    ios_target.add_file_references([file_ref])
    mac_target.add_file_references([file_ref])
  end
end

resource_paths = Dir.glob(RESOURCE_ROOT.join('**/*')).sort.select { |path| File.file?(path) || File.extname(path) == '.xcassets' }
asset_catalog_ref = resources_group.new_file(RESOURCE_ROOT.join('Assets.xcassets').to_s)
ios_target.resources_build_phase.add_file_reference(asset_catalog_ref)
mac_target.resources_build_phase.add_file_reference(asset_catalog_ref)

project.save
puts "Created #{PROJECT_PATH}"
