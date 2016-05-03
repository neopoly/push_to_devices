#!/usr/bin/env rake
require File.expand_path("../config/boot.rb", __FILE__)
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new do |t|
end

# Porting parts of mongoid's Rake tasks from
# https://github.com/mongoid/mongoid/blob/d4ad411b600bcd38dd4760d7a7799eb883748275/lib/mongoid/railties/database.rake
# Cannot be loaded direclty because of a Rails dependency
namespace :db do
  namespace :mongoid do
    MODELS = [
      Account,
      ApnDeviceToken,
      GcmDeviceToken,
      Notification,
      Service,
      User
    ]

    desc "Create the indexes defined on your mongoid models"
    task :create_indexes do
      MODELS.each do |model|
        next if model.index_options.empty?
        unless model.embedded?
          model.create_indexes
          logger.info("MONGOID: Created indexes on #{model}:")
          model.index_options.each_pair do |index, options|
            logger.info("MONGOID: Index: #{index}, Options: #{options}")
          end
          model
        else
          logger.info("MONGOID: Index ignored on: #{model}, please define in the root model.")
          nil
        end
      end
    end

    desc "Remove the indexes defined on your mongoid models without questions!"
    task :remove_indexes do
      MODELS.each do |model|
        next if model.embedded?
        indexes = model.collection.indexes.map{ |doc| doc["name"] }
        indexes.delete_one("_id_")
        model.remove_indexes
        logger.info("MONGOID: Removing indexes on: #{model} for: #{indexes.join(', ')}.")
        model
      end
    end
  end
end

task :default  => :spec
