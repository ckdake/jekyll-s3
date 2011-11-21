module Jekyll
  module S3
    class Uploader

      SITE_DIR = "_site"
      CONFIGURATION_FILE = '_jekyll_s3.yml'
      CONFIGURATION_FILE_TEMPLATE = <<-EOF
s3_id: YOUR_AWS_S3_ACCESS_KEY_ID
s3_secret: YOUR_AWS_S3_SECRET_ACCESS_KEY
s3_bucket: your.blog.bucket.com
      EOF
        

      def self.run!
        new.run!
      end

      def run!
        check_jekyll_project!
        check_s3_configuration!
        upload_to_s3!
      end

      protected
      
      def run_with_retry
        begin
          yield
        rescue AWS::S3::RequestTimeout => e
          $stderr.puts "Exception Occurred:  #{e.message} (#{e.class})  Retrying in 5 seconds..."
          sleep 5
          retry
        end
      end
      
      def bucket
        return @bucket if @bucket
        
        AWS::S3::Base.establish_connection!(
            :access_key_id     => @s3_id,
            :secret_access_key => @s3_secret,
            :use_ssl => true
        )
        unless AWS::S3::Service.buckets.map(&:name).include?(@s3_bucket_name)
          puts("Creating bucket #{@s3_bucket_name}")
          AWS::S3::Bucket.create(@s3_bucket_name)
        end

        @bucket ||= AWS::S3::Bucket.find(@s3_bucket_name)
      end
      
      def upload(local_file)
        run_with_retry do
          AWS::S3::S3Object.store(local_file, open("#{SITE_DIR}/#{local_file}"), @s3_bucket_name, :access => 'public-read')
        end
      end
      
      def delete(local_file)
        run_with_retry do
          AWS::S3::S3Object.delete(local_file, @s3_bucket_name)
        end
      end
      
      def local_files
        # Hash. Key is filename, value is md5 sum (which should match etags)
        return @local_files if @local_files
        
        @local_files ||= {}
        Dir[SITE_DIR + '/**/*'].
          delete_if { |f| File.directory?(f) }.
          map { |f| f.gsub(SITE_DIR + '/', '') }.
          each do  |local_file|
            @local_files[local_file] = Digest::MD5.file(local_file).to_s()
          end
        @local_files
      end
      
      def remote_files
        # Hash. Key is filename, value is etag
        return @remote_files if @remote_files
        
        @remote_files ||= {}
        bucket.objects.each do |remote_file|
          @remote_files[remote_file.key] = remote_file.about['etag'].gsub('"', '')
        end
        @remote_files
      end
      
      def new_local_files
        # Array of file names
        local_files.keys - remote_files.keys
      end
      
      def deleted_local_files
        # Array of file names
        remote_files.keys - local_files.keys
      end
      
      def changed_local_files
        # Array of file names
        (local_files.keys & remote_files.keys).delete_if { |filename| local_files[filename] == remote_files[filename] }
      end
      
      def prompt_to_delete(file)
        @delete_all ||= false
        @keep_all ||= false
        delete = false
        keep = false
        until delete || @delete_all || keep || @keep_all
          puts "#{local_file} is on S3 but not in your _site directory anymore. Do you want to [d]elete, [D]elete all, [k]eep, [K]eep all?"
          case STDIN.gets.chomp
          when 'd' then delete = true
          when 'D' then @delete_all = true
          when 'k' then keep = true
          when 'K' then @keep_all = true
          end
        end
        
        (@delete_all || delete) && !(@keep_all || keep)
      end

      # Please spec me!
      def upload_to_s3!
        puts "Deploying _site/* to #{@s3_bucket_name}"

        new_local_files.each do |local_file|
          if upload(local_file)
            puts("Upload New #{local_file}: Success!")
          else
            puts("Upload New #{local_file}: FAILURE!")
          end
        end
        
        changed_local_files.each do |local_file|
          if upload(local_file)
            puts("Upload Changed #{local_file}: Success!")
          else
            puts("Upload Changed #{local_file}: FAILURE!")
          end
        end
        
        deleted_local_files.each do |local_file|
          if prompt_to_delete(local_file)
            if delete(local_file)
              puts("Delete #{local_file}: Success!")
            else
              puts("Delete #{local_file}: FAILURE!")
            end
          end
        end

        puts "Done! Go visit: http://#{@s3_bucket_name}.s3.amazonaws.com/index.html"
        true
      end

      def check_jekyll_project!
        raise NotAJekyllProjectError unless File.directory?(SITE_DIR)
      end

      # Raise NoConfigurationFileError if the configuration file does not exists
      # Raise MalformedConfigurationFileError if the configuration file does not contain the keys we expect
      # Loads the configuration if everything looks cool
      def check_s3_configuration!
        unless File.exists?(CONFIGURATION_FILE)
          create_template_configuration_file
          raise NoConfigurationFileError
        end
        raise MalformedConfigurationFileError unless load_configuration
      end

      # Load configuration from _jekyll_s3.yml
      # Return true if all values are set and not emtpy
      def load_configuration
        config = YAML.load_file(CONFIGURATION_FILE) rescue nil
        return false unless config

        @s3_id = config['s3_id']
        @s3_secret = config['s3_secret']
        @s3_bucket_name = config['s3_bucket']

        [@s3_id, @s3_secret, @s3_bucket_name].select { |k| k.nil? || k == '' }.empty?
      end

      def create_template_configuration_file
        File.open(CONFIGURATION_FILE, 'w') { |f| f.write(CONFIGURATION_FILE_TEMPLATE) }

      end
    end
  end
end
