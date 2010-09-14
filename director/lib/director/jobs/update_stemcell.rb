module Bosh::Director

  module Jobs

    class UpdateStemcell
      include ValidationHelper

      @queue = :normal

      def self.perform(task_id, stemcell_dir)
        UpdateStemcell.new(task_id, stemcell_dir).perform
      end

      def initialize(task_id, stemcell_dir)
        @task = Models::Task[task_id]
        raise TaskInvalid if @task.nil?

        @stemcell_dir = stemcell_dir
        @cloud = Config.cloud
      end

      def perform
        @task.state = :processing
        @task.timestamp = Time.now.to_i
        @task.save!

        begin
          stemcell_manifest_file = File.join(@stemcell_dir, "stemcell.MF")
          stemcell_manifest = YAML.load_file(stemcell_manifest_file)

          @name = safe_property(stemcell_manifest, "name", :class => String)
          @version = safe_property(stemcell_manifest, "version", :class => Integer)
          @cloud_properties = safe_property(stemcell_manifest, "cloud_properties", :class => Hash, :optional => true)
          @stemcell_image = File.join(@stemcell_dir, "image")

          raise "Invalid image" unless File.file?(@stemcell_image)

          cid = @cloud.create_stemcell(@stemcell_image, @cloud_properties)
          stemcell = Models::Stemcell.new
          stemcell.name = @name
          stemcell.version = @version
          stemcell.cid = cid
          stemcell.save!

          @task.state = :done
          @task.timestamp = Time.now.to_i
          @task.save!
        rescue Exception => e
          @task.state = :error
          @task.result = e.to_s
          @task.timestamp = Time.now.to_i
          @task.save!
        ensure
          FileUtils.rm_rf(@stemcell_dir)
        end
      end

    end
  end
end
