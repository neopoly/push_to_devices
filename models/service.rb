# encoding: utf-8
require 'securerandom'
require 'carrierwave/mongoid'

class Service
  include Mongoid::Document
  include Mongoid::Timestamps # adds created_at and updated_at fields

  mount_uploader :pemfile, PemfileUploader

  # field <name>, :type => <type>, :default => <value>
  field :name, :type => String # name of the service registerd to this push server
  field :description, :type => String
  field :interval, :type => Integer, default: 5 #interval at which to run notifications
  field :currently_sending, :type => Boolean, default: false
  field :apn_host, :type => String
  field :apn_port, :type => Integer
  field :apn_pem_password, :type => String
  field :gcm_host, :type => String #interval at which to run notifications
  field :gcm_api_key, :type => String #interval at which to run notifications
  field :server_client_id, :type => String, default: ->{Service.securerandom_string}
  field :server_client_secret, :type => String, default: ->{Service.securerandom_string}
  field :mobile_client_id, :type => String, default: ->{Service.securerandom_string}
  field :mobile_client_secret, :type => String, default: ->{Service.securerandom_string}

  # You can define indexes on documents using the index macro:
  index({ server_client_id: 1}, {unique: true})
  index({ mobile_client_id: 1}, {unique: true})

  validates :gcm_api_key, :presence => true

  has_many :users

  # You can create a composite key in mongoid to replace the default id using the key macro:
  # key :field <, :another_field, :one_more ....>

  def self.securerandom_string(n = 23)
    SecureRandom.urlsafe_base64(n, true)
  end

  def async_send_notifications_to_users
    if Padrino.env == :test
      send_notifications_to_users
    else
      Queue::High.enqueue(self, :send_notifications_to_users)
    end
  end

  def send_notifications_to_users
    begin
      update(currently_sending: true)
      batch_iterate_users_with_notifications(batch_size: 1000) do |users_batch|
        notifications_buffered_sender = NotificationsBufferedSender.new(
          users: users_batch,
          apn_connection: apn_connection,
          gcm_connection: gcm_connection
        )
        notifications_buffered_sender.send!
      end
    ensure
      update(currently_sending: false)
    end
  end

  def async_clear_users_notifications!
    if Padrino.env == :test
      clear_users_notifications!
    else
      Queue::High.enqueue(self, :clear_users_notifications!)
    end
  end

  def clear_users_notifications!
    batch_iterate_users_with_notifications(batch_size: 1000) do |users_batch|
      users_batch.each do |user|
        user.notifications.destroy_all
      end
    end
  end

  # Method for iteration of users with notifications. Takes a block
  # And passes back the entire batch of users one at at time
  def batch_iterate_users_with_notifications(params = {})
    per_batch = params.fetch(:batch_size, 1000)
    0.step(users.count, per_batch) do |offset|
      users_batch = users.where(:notifications_count => { "$gt" => 0 }).skip(offset).limit(per_batch)
      yield users_batch if block_given?
    end
  end

  def async_delete_user_apn_tokens_based_on_apple_feedback
    if Padrino.env == :test
      delete_user_apn_tokens_based_on_apple_feedback
    else
      Queue::Low.enqueue(self, :delete_user_apn_tokens_based_on_apple_feedback)
    end
  end

  def delete_user_apn_tokens_based_on_apple_feedback
    apple_feedback = get_apn_feedback
    users.all.each do |user|
      mark_invalid_apn_device_tokens(user, apple_feedback)
      destroy_apn_device_tokens_with_fails_above_threshold(user)
    end
  end

  def has_pemfile?
    pemfile.present?
  end

  def apn_pem_path
    #FIX don't remove "uploads" from path
    pemfile.current_path#.gsub("/public/uploads", "/uploads")
  end

  private

    def apn_connection
      @apn_connection ||= begin
        connection = APNS.clone
        connection.host = apn_host if apn_host && !apn_host.empty?
        connection.port = apn_port if apn_port
        connection.pem = apn_pem_path
        connection.pass = apn_pem_password if apn_pem_password && !apn_pem_password.empty?
        connection
      end
    end

    def gcm_connection
      @gcm_connection ||= begin
        connection = GCM.clone
        connection.host = gcm_host if gcm_host && !gcm_host.empty?
        connection.key = gcm_api_key
        connection
      end
    end

    # Returns a hash of APN device id => timestamp_at_which_it_failed
    # NOTE: this uses an external resource
    # Always memoize or save in a variable because once .feedback is called
    # the data is cleared on Apple's side
    def get_apn_feedback
      apple_feedback = get_pushmeup_apn_feedback.sort_by{|f| f[:timestamp]}
      apple_feedback.reduce({}){|feedback_hash, array_value|
            feedback_hash.merge({array_value[:token] => array_value[:timestamp]})
      }
    end

    # Wrap the method on the PushMeUp gem to be safe
    def get_pushmeup_apn_feedback
      apn_connection.feedback
    end

    def mark_invalid_apn_device_tokens(user, apple_feedback_hash)
      apple_feedback_hash.each do |invalid_token, failed_at_timestamp|
        user.apn_device_tokens.where(apn_device_token: invalid_token).where(:created_at.lt => failed_at_timestamp).each do |apn_device_token|
          apn_device_token.increment_feedback_fail_count
        end
      end
    end

    def destroy_apn_device_tokens_with_fails_above_threshold(user)
      user.apn_device_tokens.where(:feedback_fail_count.gte => ApnDeviceToken::FEEDBACK_FAIL_COUNT_THRESHOLD).destroy_all
    end

end
